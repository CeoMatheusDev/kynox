# Kynox — Security Architecture

- Status: **planning document** describing the target security architecture and
  the evidence each property requires. It does not claim any property is already
  met.
- Date: 2026-10-31.
- Related: [`platform-architecture.md`](platform-architecture.md),
  [`graphics-platform.md`](graphics-platform.md),
  [`application-ecosystem.md`](application-ecosystem.md),
  [`PRODUCT_ROADMAP.md`](../roadmap/PRODUCT_ROADMAP.md), `AGENTS.md` §4.5.

## 1. What is claimed today (and what is not)

| Property | State |
|---|---|
| Ring 3 user processes with separate address spaces | Implemented, host-tested, **never validated in a VM** |
| W^X and NX enforcement | Implemented with negative tests, no runtime evidence |
| Capabilities with typed rights, delegation and revocation | Implemented in the kernel, coverage incomplete |
| Validated user pointers on syscalls | Implemented for existing calls |
| Device containment and bus-master revocation | Implemented for the VirtIO block path |
| SMEP/SMAP, KASLR, KPTI, stack canaries, CET | **Not implemented** |
| Secure boot chain, measured boot, TPM | **Not implemented** |
| Signed packages, verified updates, rollback | **Not implemented** |
| Sandbox broker and portals | **Not implemented** |
| IOMMU protection for devices | **Not implemented** |

The table is the honest baseline. Everything below is the target.

## 2. Threat model

### 2.1 Assets

User data and credentials; system integrity (kernel, boot chain, updates);
availability; privacy (screen, microphone, camera, location-like metadata);
intellectual property of applications; the user's trust in the platform.

### 2.2 Adversaries

| Adversary | Capability | Primary defences |
|---|---|---|
| Malicious or buggy application | Ring 3, arbitrary syscalls, crafted IPC and GPU commands | Address spaces, capabilities, validation, sandbox, broker |
| Compromised service | Ring 3 with granted capabilities | Least privilege, restart isolation, capability revocation |
| Malicious device / DMA | Bus master access to memory | IOMMU, bounded DMA windows, device quarantine |
| Malicious firmware/ACPI | Tables parsed at boot | Validation, bounds, checksums, no trust |
| Network attacker | Crafted packets | User-space stack, bounded parsers, fuzzing |
| Local attacker with physical access | Disk and bus access | Encryption at rest, secure boot, TPM sealing |
| Supply-chain attacker | Malicious package or update | Signatures, reproducible builds, transparency logs |
| Malicious insider with signing keys | Authorised signatures | Key separation, revocation, staged rollout, audit |

### 2.3 Trust boundaries

```text
UEFI firmware ──(signed loader, measured)──▶ kernel
kernel ──(syscall/ABI validation, capabilities)──▶ processes
kernel ──(IOMMU, validated rings)──▶ devices
process ──(IPC, broker, user consent)──▶ other processes / resources
network ──(untrusted input, user-space stack)──▶ applications
repository ──(signatures, reproducible builds)──▶ system image
```

Every arrow is a place where input is untrusted and must be validated. The kernel
never trusts firmware, devices, other CPUs' state or user pointers.

## 3. Boot and platform integrity

### 3.1 Chain of trust

1. **Firmware verification:** UEFI Secure Boot verifies the Kynox loader against a
   key enrolled in the firmware database.
2. **Loader:** verifies the kernel image hash and signature before transferring
   control; validates the handoff structure it builds.
3. **Kernel:** verifies the base image signature against the platform key before
   mounting the system image.
4. **System image:** each package is verified at load/execution time against the
   repository key and the local trust store.

### 3.2 Measured boot

- Each stage extends a TPM PCR with the hash of the next stage (loader, kernel,
  system image manifest).
- Measurements are available to user space through a read-only interface; remote
  attestation is **opt-in** and requires explicit user consent.
- Failure to extend a PCR is a boot error, not a warning.

### 3.3 Secure boot without lock-out

- Key enrolment is documented; custom keys are supported (developer mode with a
  visible warning and a recovery path).
- A recovery image is signed with the same chain and can be booted when the
  system image fails verification.
- Losing the platform key must not brick the device: recovery media and a
  documented reset flow are part of the acceptance criteria.

## 4. Kernel hardening

| Mechanism | Purpose | Status |
|---|---|---|
| W^X | No page writable and executable | Implemented (negative tests) |
| NX | Data pages non-executable | Implemented |
| SMEP/SMAP | Kernel cannot execute/access user pages accidentally | Planned (CPUID-gated) |
| KASLR | Randomise kernel base | Planned |
| KPTI (optional) | Separate user/kernel page tables | Planned as a measured option |
| Shadow stack / CET | Control-flow integrity | Long term (hardware-gated) |
| Stack canaries | Detect overflow | Planned |
| Guard pages | Stacks and critical regions | Partial |
| Freelist hardening | Detect use-after-free patterns | Planned |
| Pointer validation | All user pointers | Implemented for current syscalls |
| Syscall fuzzing | Find validation gaps | Planned |

Rules:

- A CPU feature is used only when CPUID says it exists and the kernel enabled the
  architectural state required.
- Security features fail closed: if a mandatory feature cannot be enabled, the
  system reports it and refuses the operation, rather than silently degrading.

## 5. Capability and object model

- Authority is a **capability**: `(kind, subject, rights)` held in a per-process
  table with a generation counter.
- Kinds today: channel, process, display, input. Target additions: device, GPU
  context, shared memory, file, directory, socket, service.
- Rights: send, receive, delegate, write, read; extended per kind (e.g. `map`,
  `execute`, `capture`).
- Delegation requires the `delegate` right; revocation is immediate and
  transitive where the model defines it.
- A handle is never reused with the same generation; stale handles fail closed.
- Process exit revokes all its capabilities and releases its objects.

**Proof obligations:** every syscall that takes a handle tests invalid, stale,
revoked and foreign handles; a test suite enumerates each kind × right and
asserts the outcome.

## 6. Device and driver security

- Devices are discovered by the kernel; access is handed out as a capability
  scoped to a device, with MMIO windows and interrupt vectors.
- **IOMMU is mandatory for user-space drivers.** Without an IOMMU, the vendor
  driver runs in the kernel behind the same narrow interface, and the limitation
  is published per device.
- DMA buffers are pinned, owned and mapped only for the duration of the transfer.
- A device that faults (IOMMU fault, hung queue, repeated reset) is quarantined
  and the driver is detached; the system keeps running.
- Bus-master enable is a capability, revoked on containment.

This model extends to the GPU: per-process GPU page tables, validated command
rings, and the graphics-specific threats enumerated in
[`graphics-platform.md`](graphics-platform.md) §11.

## 7. Data protection

| Area | Mechanism |
|---|---|
| Disk encryption | Per-device key, TPM-sealed to the measured boot state, recovery key shown once at setup |
| Credentials | Kernel keyring-like service; secrets never swapped; memory locked |
| Authentication | User login verifies against a salted, memory-hard hash; no plaintext storage |
| Session isolation | One user's processes cannot read another's memory, files or screen |
| Backups | User-initiated, encrypted, verifiable |
| Secure deletion | Documented semantics; SSD TRIM caveats stated honestly |

No encryption claim is made until the implementation and the recovery flow are
tested, including a simulated TPM failure.

## 8. Application sandbox and permissions

- Applications start with no ambient authority (see
  [`application-ecosystem.md`](application-ecosystem.md) §6).
- The broker is unprivileged, isolates consent, and issues scoped tokens.
- Permissions are visible, revocable and audited; the UI explains *why* an
  application asks for a capability.
- A denied permission is a normal result: applications must handle it and the
  system never silently escalates.
- Screen capture, microphone, camera, input capture and accessibility are
  explicit, per-application grants with an indicator while active.

### 8.1 Compatibility personalities

A process running under KLC or KWC is an ordinary sandboxed process. The
personality adds contracts, never authority:

| Property | Mechanism | Proof (once built) |
|---|---|---|
| No privilege gain from a foreign ABI | capability set fixed at exec; the personality gate can only reach handlers that map to existing capabilities | syscall fuzzing + capability-invariant tests |
| Foreign calls are bounded | per-persona number allow-list; unknown calls return an error and are counted | audit log of `ENOSYS`/denials |
| Memory isolation | per-process address spaces; no physical memory mapping for personas | page-table ownership tests |
| Filesystem containment | compatibility root namespace, synthetic `/proc`, no ambient `/` | escape-attempt test corpus |
| Graphics containment | KGL/KVK are unprivileged user-space front-ends; GPU memory is per process | cross-process GPU access tests |
| Resource limits | CPU time, memory, GPU memory, handles, processes | quota enforcement tests |
| Auditability | every denied syscall, path escape and capability check is logged with the persona id | log schema + replay |

The threat model additions are in
[`linux-compatibility.md`](linux-compatibility.md) §11 and
[`windows-compatibility.md`](windows-compatibility.md) §14. The kernel contains
**no** foreign ABI: one ABI-agnostic gate exists, and it is reviewed as a
security boundary (ADR-0010).

## 9. Updates and supply chain

- Packages are signed; the repository index is signed; deltas are verified
  against the same chain.
- Builds of system components are reproducible; provenance is published.
- Rollback protection uses a monotonic counter stored with the TPM, so an
  attacker cannot downgrade to a known-vulnerable image.
- Staged rollout with automatic halt on boot-failure telemetry (opt-in) and a
  manual override.
- Key rotation and revocation are documented and tested with a pre-production
  key.

## 10. Observability, audit and privacy

- Local audit log of security-relevant events (grants, revocations, failed
  verification, device quarantine), readable only by the owner and the
  administrator.
- Tracing is local by default; any upload is explicit, scoped and revocable.
- Crash reports contain no user content by default; attaching a memory dump
  requires explicit consent.
- Telemetry is never a condition for updates or support.

## 11. Recovery

| Failure | Recovery |
|---|---|
| Kernel panic | Reboot into the last known-good generation |
| Repeated boot failure | Automatic rollback after N attempts, with the counter stored in firmware/bootloader |
| Corrupt system image | Verify, restore from the other generation or recovery media |
| Lost device key | Recovery key; otherwise data is unrecoverable (documented) |
| Compromised package | Revoke the key, block the version, re-sign or roll back |
| Compromised driver | Quarantine the device, fall back to Tier 0 rendering |

Recovery paths are tested by fault injection, not by documentation.

## 12. How each property becomes evidence

| Property | Test to produce |
|---|---|
| W^X/NX | Negative tests that attempt to execute/write protected pages and observe a fault |
| SMEP/SMAP | Kernel attempted user access faults; CPUID-gated enablement |
| Capability revocation | Enumerate kinds × rights; attempt every operation after revoke |
| Syscall validation | Fuzzing with malformed pointers, lengths and handles |
| IOMMU isolation | Fault injection: device writes outside its window → fault, driver quarantined |
| Command validation | Malformed command corpus submitted to a virtual GPU |
| Sandbox | Applications without grants observe no files, screen, audio or devices |
| Update integrity | Tampered package rejected; downgrade blocked |
| Rollback | Boot failure loop triggers rollback; data intact |
| Boot chain | Unsigned/modified stage refused; measured values change accordingly |

A property appears in release notes only with its test, its environment and its
result.

## 13. Explicit non-guarantees

- Kynox does **not** claim to be "as secure as Linux" or "as secure as Windows".
- No claim is made about resistance to physical attacks beyond the stated
  encryption and secure-boot design.
- No claim is made about anti-cheat, DRM or compatibility-driven security.
- Side-channel resistance is limited to documented choices; no constant-time
  guarantee is made for the whole system.
- Firmware and microcode remain trusted components; their compromise is out of
  scope.

## 14. Open questions

1. KPTI: always-on, opt-in, or adaptive by workload? Needs a measured cost.
2. TPM-less systems: which guarantees degrade, and how is that surfaced?
3. Encryption default: full-disk by default at install, or opt-in?
4. Broker implementation: one process for all portals or one per portal family?
5. Kernel module policy: no modules at all, or signed modules with a measured
   boundary?
6. Audit log retention and its privacy implications.
