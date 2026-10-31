# Kynox

**Kynox** is an experimental x86-64 operating system built primarily with **Zig 0.17.0** and x86-64 Assembly. The project is developing its own boot flow, kernel, executable format, runtime, drivers, libraries, filesystem, graphics stack and desktop environment.

The long-term goal is a native operating system with its own technology stack, plus independently implemented compatibility environments for **Linux and Windows binaries**. Those compatibility environments are planned; they are not available yet.

### Identity

| Field | Value |
|---|---|
| Current identity | **Kynox One 0.1.0-alpha.1** |
| Technical version | `0.1.0-alpha.1` (SemVer 2.0.0, single source: [`VERSION`](VERSION)) |
| Generation / era | **Kynox One** — every `0.x` release belongs to it |
| Planned tag | `v0.1.0-alpha.1` (not created) |

The public name is generated from the technical version: `Kynox [Generation] [VERSION]`.
The major number selects the generation from a fixed chart (`0` = Kynox One,
`1` = Kynox Quark … `14` = Kynox Cosmos); a major without an official name is
rejected instead of invented. See [docs/VERSIONING.md](docs/VERSIONING.md) and
[docs/roadmap/ERAS.md](docs/roadmap/ERAS.md).

> **Development status:** early-stage OS engineering. Source code and test infrastructure exist across several subsystems; the host build and host unit tests execute and pass, while the boot/runtime paths have not been observed in the environment of the last audit. The system is not a general-purpose desktop OS and is not production-ready.

## Progress overview

Percentages represent estimated **subsystem engineering maturity**, not the percentage of the whole OS that is complete. A source file or a test being present does not mean the feature is complete or that the test passed.

| Area | Progress | Current state |
|---|---:|---|
| UEFI bootloader and handoff | **70%** | Core path implemented; broader firmware validation remains |
| Kernel CPU, exceptions and interrupts | **60%** | Core paths exist; hardening and hardware coverage remain |
| Physical memory, heap and DMA | **60%** | Core allocators and DMA path exist; scalability/reclaim remain |
| Virtual memory and address spaces | **45%** | User mappings and isolation foundations; advanced VM remains |
| ACPI, PCI and APIC | **50%** | MADT discovery drives the LAPIC base at boot; IOAPICs and overrides are recorded, not programmed; PCI/APIC access paths exist |
| SMP | **30%** | AP startup exists; normal per-CPU scheduling is incomplete |
| Scheduler and task switching | **55%** | Preemptive task switching exists; SMP scheduling remains |
| User mode and syscalls | **55–60%** | Ring 3 apps and native syscall path exist; ABI revision 1 is contract-checked; the ABI is still small and never ran in a VM here |
| IPC and capabilities | **60%** | Core mechanisms exist; broader service model remains |
| ELF64 and KEX native executables | **55–60%** | Native ELF loading and KEX container exist; dynamic linking remains |
| Native SDK and runtime | **40%** | Initial SDK and sample apps exist; public runtime is incomplete |
| RamFS, KFSX and KNV | **35–60%** | In-memory FS, mount namespace and volume codec exist; VFS/power-loss guarantees remain |
| VirtIO Block / KVDI | **65%** | Real synchronous block I/O and QEMU persistence probe exist; async I/O remains |
| Networking | **10%** | Early scaffolding only; no complete network stack |
| Graphics and compositor | **60%** | Rasterization, windows and composition exist; full desktop remains |
| Input | **40%** | Initial keyboard/pointer paths; HID and hotplug remain |
| Desktop environment | **35%** | Managed windows and boot scene; shell and desktop applications remain |
| Linux binary compatibility | **0%** | Planned; no Linux execution personality yet |
| Windows binary compatibility | **0%** | Planned; no PE32+/Win64/NT/Win32 runtime yet |
| Security hardening | **45%** | Capabilities and W^X foundations; systematic hardening remains |
| Tests and validation infrastructure | **65%** | Host suite executes and passes (672 tests); QEMU targets exist but have never been recorded, and there is no CI |
| Performance and observability | **40%** | Counters, TSC timing and a boot benchmark; benchmark sources are not in the build graph |
| Build and developer tooling | **60%** | Zig build graph, image generator, zero external dependencies and a single version source guarded by tests; CI remains |

The full evidence-based inventory, including gaps and next steps, is maintained in **[PROJECT_STATUS.md](docs/PROJECT_STATUS.md)** and the machine-readable **[PROJECT_STATUS.json](docs/PROJECT_STATUS.json)**.

### Status labels

The canonical vocabulary (also used by `docs/PROJECT_STATUS.json`) is
`not_started`, `scaffolding`, `in_progress`, `implemented`, `integrated`,
`validated`, `blocked`.

- **Scaffolding:** only identifiers, types or groundwork exist.
- **In progress:** a meaningful part exists, but the complete subsystem contract is not delivered.
- **Implemented:** code exists and is connected to a real execution path for the stated scope.
- **Integrated:** the active execution path uses it end to end.
- **Validated:** relevant tests were actually executed in a named environment. A test target in the build graph alone is not validation.
- **Blocked:** work cannot proceed without an external condition (hardware, firmware, decision).

### Important limitations

- Kynox has early SMP/AP startup code, but APs do not yet participate in the normal scheduler workload.
- The active VirtIO Block path is **KVDI** (kernel/drivers/kvdi/block.zig), which implements synchronous requests. kernel/arch/x86_64/virtio_blk.zig is a separate legacy stub and is not the active driver; its removal is decided in ADR-0003 but not yet executed. The parallel queue code in kernel/arch/x86_64/virtio.zig is a duplicate of KVDI's virtqueue (ADR-0002).
- VirtIO Block completion currently uses polling; interrupt/MSI-X-driven asynchronous I/O and multi-queue support are not established.
- KNV commit/recovery and a QEMU two-boot block persistence probe exist. This does not yet provide journaled, power-loss-safe filesystem guarantees.
- KFSX currently provides a mount namespace and RamFS routing, not a mature multi-filesystem VFS.
- KEX is the Kynox executable container around an ELF64 payload. It is **not** Linux binary compatibility.
- Linux and Windows binary compatibility are both **0%** at this snapshot. No claim of running arbitrary Linux or Windows applications is made.
- zig build check runs unit, boot and storage checks. The interactive QEMU check is separate: zig build qemu-interactive-test.
- ACPI/MADT is consumed at boot: the LAPIC base and the IOAPIC list come from the table, with validation and a logged fallback to `0xFEE00000`. The **IOAPIC is not programmed**, so interrupt routing is unchanged, and the path has never run in a VM (audit A-03, resolved in part; see docs/specs/acpi-platform.md).
- The system version has a single source (`VERSION` → `version.zig`, mirrored in `build.zig.zon`, guarded by `version-tests`) and the native ABI has one revision (`shared/syscall_abi.zig`, revision 1), aliased by the kernel and the SDK and checked by `abi-conformance-tests`. That closes audit A-01 and the A-04 inconsistency; it does **not** make the ABI stable, because the door has never executed in a VM. The generation name is derived from the major, never typed by hand.
- There is no CI, and no QEMU result has been recorded in the repository. Only the host build and host test suite have executed evidence (see below). The three QEMU targets were attempted on 2026-10-31 and all stop at "no OVMF firmware found"; the procedure and the attempt table are in docs/validation/qemu.md.

## What's already in the tree

- Native UEFI bootloader and KNB→KNK handoff.
- Freestanding x86-64 kernel and Assembly entry, interrupt, syscall and context-switch paths.
- CPU, paging, PMM, heap, DMA, ACPI discovery (RSDP → XSDT/RSDT → MADT), PCI, APIC and early SMP components.
- User-mode tasks, native syscall dispatch, IPC channels and capability delegation/revocation.
- ELF64 parser/loader, KEX executable container, KPK package codec and initial Zig SDK.
- RamFS, KFSX mount namespace, KNV volume serialization and block abstraction.
- KVDI modern VirtIO transport and synchronous VirtIO Block read/write/flush path.
- Rasterizer, framebuffer bridge, compositor, window manager, input routing and desktop scene.
- Host unit tests (672) and QEMU integration scripts for boot, storage persistence and interactive graphics/input.
- Two native applications built from the SDK and embedded in the boot image (`user/hello.zig`, `user/client.zig`).

## Build

Requires **Zig 0.17.0** (pinned by `build.zig.zon` → `minimum_zig_version`).

```sh
zig version          # must print 0.17.0
zig build
```

> Zig 0.17.0 is not published on the GitHub releases page (which carried 0.15.x
> at the time of the audit). Obtain it from a distribution channel that
> publishes 0.17.0 — the audit verified the build with the `ziglang` 0.17.0
> package from PyPI. There are no other build prerequisites: `build.zig.zon`
> declares no external dependency.

Build outputs include:

- zig-out/bin/kynox-boot.efi — UEFI boot application
- zig-out/bin/kynox-kernel — freestanding kernel ELF
- zig-out/bin/kynox.img — bootable EFI system partition image

## Tests

```sh
zig build test
zig build qemu-test
zig build qemu-storage-test
zig build qemu-interactive-test
zig build check
```

- zig build test — host unit tests.
- zig build qemu-test — automated QEMU boot test.
- zig build qemu-storage-test — VirtIO Block I/O and persistence across two QEMU boots.
- zig build qemu-interactive-test — interactive PS/2/graphics checks.
- zig build check — unit, boot and storage tests; it does **not** include the interactive target.

Run the commands locally before reporting them as passing. See [AGENTS.md](AGENTS.md) for the development contract.

### Verification record (2026-10-31)

| Command | Result |
|---|---|
| `zig version` | `0.17.0` |
| `zig build` | success — 13/13 steps; `kynox-boot.efi` 181,760 B, `kynox-kernel` 65,770,762 B, `kynox.img` 128 MiB |
| `zig build test` | success — 45/45 steps, **672/672 tests passed** |
| `zig build qemu-test` | **not executed** — no QEMU/OVMF in that environment |
| `zig build qemu-storage-test` | **not executed** — same reason |
| `zig build qemu-interactive-test` | **not executed** — same reason |

The QEMU suites assert 117 markers and patterns (handoff, GDT/IDT, NX, PCI, DMA,
virtqueue, timer, PS/2, incremental redraw, filesystem, KNV commit/recover, KPK,
task creation, native ELF execution, page permissions). Their results must be
recorded in the release notes once a machine with QEMU + OVMF runs them; the
recorded attempt and the exact procedure are in
[docs/validation/qemu.md](docs/validation/qemu.md).

## Architecture and development documents

- [AGENTS.md](AGENTS.md) — mandatory rules for coding agents and contributors.
- [strategy.md](strategy.md) — architecture strategy, phases and roadmap.
- [KYNOX_NATIVE.md](KYNOX_NATIVE.md) — own-technology policy and native/Linux/Windows execution architecture.
- [docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md) — detailed progress, evidence, gaps and priorities.
- [docs/PROJECT_STATUS.json](docs/PROJECT_STATUS.json) — machine-readable progress inventory (schema v2).
- [docs/specs/boot-handoff-spec.md](docs/specs/boot-handoff-spec.md) — normative KNB→KNK handoff contract.
- [docs/specs/syscall-abi.md](docs/specs/syscall-abi.md) — normative native syscall ABI (revision 1).
- [docs/VERSIONING.md](docs/VERSIONING.md) — identity, SemVer policy and the four independent version lines.
- [docs/roadmap/ERAS.md](docs/roadmap/ERAS.md) — normative chart of generations and eras.
- [docs/specs/acpi-platform.md](docs/specs/acpi-platform.md) — MADT discovery, validation and fallback.
- [docs/validation/qemu.md](docs/validation/qemu.md) — how to run the QEMU suites and what has actually been attempted.
- [docs/decisions/](docs/decisions/README.md) — architecture decision records (ADR-0001…0003).
- [docs/audits/2026-10-31-audit.md](docs/audits/2026-10-31-audit.md) — audit, findings and prioritized plan.
- [CHANGELOG.md](CHANGELOG.md) — release history and unreleased changes.
- [docs/releases/0.1.0-alpha.1.md](docs/releases/0.1.0-alpha.1.md) — release notes (draft; the tag does not exist).

## License

GPL-3.0-only
