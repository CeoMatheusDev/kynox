# Kynox — Application Ecosystem, SDK and Distribution

- Status: **planning document**. Today the tree has a native ELF64/KEX loader, a
  22-call syscall ABI (revision 1), a minimal SDK and two sample applications. It
  has **no** package manager, installer, repository, signature verification,
  sandbox broker or update mechanism.
- Date: 2026-10-31.
- Related: [`platform-architecture.md`](platform-architecture.md),
  [`graphics-platform.md`](graphics-platform.md),
  [`security-architecture.md`](security-architecture.md),
  [`PRODUCT_ROADMAP.md`](../roadmap/PRODUCT_ROADMAP.md),
  [`KYNOX_NATIVE.md`](../../KYNOX_NATIVE.md).

## 1. Principles

1. **Native first.** Kynox applications use the Kynox ABI and SDK. Compatibility
   with Linux and Windows is a separate, isolated personality
   ([KYNOX_NATIVE.md](../../KYNOX_NATIVE.md) §2), never the foundation.
2. **No mandatory heavy runtime.** A native application must be runnable as a
   plain executable plus system libraries. No JIT, GC or daemon is required to
   start a program.
3. **Explicit permissions.** An application declares what it needs; the user (or
   policy) grants it; the kernel enforces it. A manifest is a request, not an
   authority.
4. **Verifiable distribution.** Every package is signed, content-addressed and
   reproducible enough to be rebuilt from source.
5. **Compatibility is a contract.** API/ABI versions are declared, tested and
   documented; breaking a stable contract requires a new major revision.

## 2. Three execution environments

| Environment | Format | ABI | Status |
|---|---|---|---|
| Kynox Native | KEX (ELF64 payload + manifest) | Kynox syscall ABI + SDK | Partial: loader and 22 calls exist |
| Kynox Linux Compatibility (KLC) | ELF64 | Linux process/syscall ABI subset | **0%** — design only |
| Kynox Windows Compatibility (KWC) | PE32+ | Win64/NT subset | **0%** — design only |

Rules that apply to all three:

- each environment has its own process model and syscall translation layer;
- compatible binaries run in Ring 3 with Kynox capabilities enforced;
- no compatibility code runs in Ring 0;
- a compatibility environment may use native libraries only through documented
  contracts, never by exporting kernel internals.

## 3. Native executable format (KEX, target v2)

KEX v1 exists: an ELF64 payload wrapped with a manifest and a CRC. The target
format adds what an ecosystem needs.

### 3.1 Structure

```text
KEX header
  magic, version, header_size, flags
  abi_revision_min, abi_revision_max
  payload_offset, payload_size, payload_hash
  manifest_offset, manifest_size
  signature_offset, signature_size, signature_algorithm
  entry_point, load_bias
Payload (ELF64 executable, validated and mapped by the loader)
Manifest (declarative, versioned)
Signature (over header + payload + manifest)
```

### 3.2 Manifest

| Field | Purpose |
|---|---|
| `id`, `name`, `version` | Identity (reverse-DNS id, SemVer version) |
| `publisher` | Signing identity |
| `abi_min`, `abi_max` | Required native ABI range |
| `dependencies[]` | Package ids + version ranges |
| `capabilities[]` | Requested capability kinds and rights, with a user-facing reason |
| `filesystem[]` | Requested paths or virtual roots |
| `network[]` | Domains/ports requested (or `none`) |
| `devices[]` | Device classes requested (GPU, audio, input) |
| `services[]` | Whether the package provides a service |
| `entry_points[]` | GUI/CLI/service roles |
| `resources[]` | Icons, desktop entries, MIME associations |

The manifest is **validated structurally** and its capability requests are shown
to the user at install time; the kernel does not read it.

### 3.3 Loader pipeline

1. Verify magic, sizes, overflow, alignment and hashes.
2. Verify signature against a trusted key (repository key or explicit local
   trust).
3. Parse the manifest; reject unknown mandatory fields.
4. Validate the ELF payload (segments, permissions, entry, relocations).
5. Create the address space; map code RX, data RW, stack with guard; never RWX.
6. Grant only the capabilities the installer decided, not everything requested.
7. Start the process at the declared entry point.

Failures are explicit and never fall back to "run anyway".

## 4. Native ABI and runtime

### 4.1 Syscall ABI

- Revision 1 is defined in `shared/syscall_abi.zig` and documented in
  [`syscall-abi.md`](../specs/syscall-abi.md); the kernel and SDK alias the same
  constants and a conformance test rejects divergence.
- Additions are compatible; removals require a new revision and a deprecation
  window.
- The ABI exposes no kernel pointers and no global namespaces; everything is a
  handle or a capability.

### 4.2 SDK layers

| Layer | Contents | Stability |
|---|---|---|
| **KSL** (standard library) | strings, formatting, collections, math, errors | Stable within a major release |
| **KRT** (runtime) | process start/exit, TLS, stack setup, panic handling | ABI-stable |
| **KSL-Sys** | thin typed wrappers over syscalls | Tracks ABI revisions |
| **KSL-UI** | windows/surfaces, input, clipboard, notifications | Evolves with KGA-UI |
| **KSL-GFX** | KGA native API bindings | Tracks KGA revision |
| **KSL-Audio**, **KSL-Net** | audio streams, sockets | Introduced with their services |
| **KSL-Pkg** | package/update queries | Stable |

No layer requires a background runtime process. An application links against
system libraries or ships static code; both are supported.

### 4.3 Libraries and linking

- **System libraries** are versioned, immutable, signed and shipped with the
  base image (`/system/lib`).
- **Application-private libraries** live inside the package and are versioned by
  the package itself.
- Shared libraries use a content-addressed cache keyed by hash, so two versions
  can coexist without breaking a running application.
- Dynamic linking is a loader feature, not a kernel feature; unresolved symbols
  fail at load with a diagnostic listing them.

### 4.4 Runtime requirements

- No mandatory GC or JIT.
- Language runtimes (for higher-level languages) are ordinary packages with
  explicit capabilities.
- A "hello world" native binary must run with only the system libraries; this is
  a test in the SDK.

## 5. Packaging and distribution

### 5.1 KPK as a package

KPK today is a container codec with validation and a CRC used for in-image
packages. The distribution format adds:

| Element | Requirement |
|---|---|
| Content addressing | Hash per file and per package; deduplication across packages |
| Signatures | Ed25519 over the package manifest and content hash |
| Repositories | Signed index (metadata), delta-capable, mirror-friendly |
| Dependencies | Version ranges; solver produces a plan, installs atomically |
| Rollback | Previous versions retained until the next successful boot |
| Offline | Install/update from a local file with the same verification |

### 5.2 Installation layout

```text
/system/            immutable base image (signed, read-only)
/packages/<id>/<version>/   content-addressed application trees
/var/               mutable system state
/home/<user>/       user data
```

Applications never write to `/system`; updates replace it atomically.

### 5.3 Updates

1. Download index and package, verify signatures and hashes.
2. Stage into a new system image generation (A/B or snapshot).
3. Mark the new generation bootable; reboot.
4. A boot counter (firmware or bootloader) confirms success; repeated failures
   roll back automatically.
5. Application updates use the same verification but do not require a reboot.

Rollback is a tested path: the test suite must corrupt the new generation and
observe the rollback.

## 6. Sandboxing and permissions

### 6.1 Defaults

An application starts with **no** file access outside its own package and home
sandbox, no network, no device access and no ability to see other processes.
Every capability is granted explicitly.

### 6.2 Broker (portal model)

The design follows the proven three-tier pattern of desktop portals `[S12]` in
[`market-landscape.md`](../strategy/market-landscape.md) §3.6, reimplemented
natively:

```text
application ──request──▶ broker (unprivileged) ──prompt──▶ user
      ▲                        │
      └──── capability ────────┘  (file handle, screen-capture token, mic stream)
```

Portal families to implement, in order: file chooser, open URI, notifications,
screen capture, clipboard, microphone, camera, global shortcuts, printing,
secrets.

Each portal has: a request object with cancellation, a scoped grant with
expiry, an audit record, and a test that an app without the grant receives
nothing.

### 6.3 Capability persistence

A grant may be one-shot, session-scoped or persistent; the broker records the
choice with the application identity and shows it in settings. Revocation is
immediate and tested.

## 7. Developer workflow

| Stage | Tool | Notes |
|---|---|---|
| Project | `kynox new` / build templates | SDK ships with Zig-based templates |
| Build | `kynox build` (wraps `zig build`) | Cross-compiles to x86_64-freestanding/kynox |
| Run | `kynox run` / emulator | Starts the app in a test VM or on hardware |
| Debug | Kynox Debugger + serial/trace | Symbols from packages, source paths recorded |
| Profile | KGT frame profiler, syscall tracer | Capture format shared with tests |
| Package | `kynox pack` | Produces signed KPK + manifest |
| Publish | Repository push | Signed index; no central gatekeeper required |

The SDK must build and test an application **without a running Kynox system** for
host-testable code, and with a VM for integration.

## 8. Compatibility strategy (KLC and KWC)

This is an independent initiative with its own roadmap; the following is the
architectural contract.

| Aspect | KLC (Linux) | KWC (Windows) |
|---|---|---|
| Binary format | ELF64 x86-64 | PE32+ x86-64 |
| System boundary | `syscall` instruction → generic kernel gate | `ntdll` calls → Kynox user-space libraries |
| First milestone | Static binaries, ~20 syscalls | Console applications, small NT/Win32 subset |
| Process model | Linux process/thread semantics translated | Windows process/thread + TEB/PEB model |
| Libraries | Own KLIBC (no glibc/musl) | Own ntdll/kernel32/CRT (no Wine code) |
| Graphics | KGL/KVK through a window-system bridge | KGL/KVK, Direct3D only in a later phase |
| Anti-cheat/DRM | Not guaranteed; documented per title | Not guaranteed; documented per title |
| Status | 0% — architecture documented, nothing implemented | 0% — architecture documented, nothing implemented |

Architecture: [`linux-compatibility.md`](linux-compatibility.md) and
[`windows-compatibility.md`](windows-compatibility.md). Phases and evidence
rules: [`../roadmap/COMPATIBILITY_ROADMAP.md`](../roadmap/COMPATIBILITY_ROADMAP.md).

Explicit non-claims: no Wine/WSL/Proton/glibc/musl as foundation, no foreign
kernel or kernel driver, no claim of running arbitrary software, no Ring 0
compatibility shims, and a published support matrix per release. Loading a file
is not compatibility: the matrix is generated from test runs (compatibility
roadmap §5).

## 9. Ecosystem economics

- **No mandatory store.** Packages can be distributed by any signed repository;
  the system verifies signatures, not vendors.
- **No mandatory account.** Local installation is a first-class path.
- **Reproducible builds** and published provenance for system components; the
  same tooling is available to application developers.
- **Free SDK and tooling**; documentation and samples licensed for reuse.

## 10. Open questions

1. Shared-library model: content-addressed cache only, or also a stable ABI lane?
2. KEX v2 signature algorithm and key rotation policy.
3. Delta update format and its verification cost.
4. Sandbox granularity for services (one sandbox per service or per package?).
5. Compatibility packaging: one image per personality or per application?
6. How are GPU driver packages signed when they embed vendor firmware?
