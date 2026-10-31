# Kynox

**Kynox** is an experimental x86-64 operating system built primarily with **Zig 0.17.0** and x86-64 Assembly. The project is developing its own boot flow, kernel, executable format, runtime, drivers, libraries, filesystem, graphics stack and desktop environment.

The long-term goal is a native operating system with its own technology stack, plus independently implemented compatibility environments for **Linux and Windows binaries**. Those compatibility environments are planned; they are not available yet.

> **Development status:** early-stage OS engineering. Source code and test infrastructure exist across several subsystems, but the system is not a general-purpose desktop OS and is not production-ready.

## Progress overview

Percentages represent estimated **subsystem engineering maturity**, not the percentage of the whole OS that is complete. A source file or a test being present does not mean the feature is complete or that the test passed.

| Area | Progress | Current state |
|---|---:|---|
| UEFI bootloader and handoff | **70%** | Core path implemented; broader firmware validation remains |
| Kernel CPU, exceptions and interrupts | **60%** | Core paths exist; hardening and hardware coverage remain |
| Physical memory, heap and DMA | **60%** | Core allocators and DMA path exist; scalability/reclaim remain |
| Virtual memory and address spaces | **45%** | User mappings and isolation foundations; advanced VM remains |
| ACPI, PCI and APIC | **50%** | Parsers and access paths exist; discovery/routing need completion |
| SMP | **30%** | AP startup exists; normal per-CPU scheduling is incomplete |
| Scheduler and task switching | **55%** | Preemptive task switching exists; SMP scheduling remains |
| User mode and syscalls | **55–60%** | Ring 3 apps and native syscall path exist; ABI is still small |
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
| Tests and validation infrastructure | **65%** | Host and QEMU test targets exist; current results need to be run and recorded |

The full evidence-based inventory, including gaps and next steps, is maintained in **[PROJECT_STATUS.md](docs/PROJECT_STATUS.md)** and the machine-readable **[PROJECT_STATUS.json](docs/PROJECT_STATUS.json)**.

### Status labels

- **Implemented:** code exists and is connected to a real execution path for the stated scope.
- **Partial / In progress:** a meaningful part exists, but the complete subsystem contract is not delivered.
- **Planned:** no implementation of the stated capability has been established.
- **Validated:** relevant tests were actually executed in a named environment. A test target in the build graph alone is not validation.

### Important limitations

- Kynox has early SMP/AP startup code, but APs do not yet participate in the normal scheduler workload.
- The active VirtIO Block path is **KVDI** (kernel/drivers/kvdi/block.zig), which implements synchronous requests. kernel/arch/x86_64/virtio_blk.zig is a separate legacy stub and is not the active driver.
- VirtIO Block completion currently uses polling; interrupt/MSI-X-driven asynchronous I/O and multi-queue support are not established.
- KNV commit/recovery and a QEMU two-boot block persistence probe exist. This does not yet provide journaled, power-loss-safe filesystem guarantees.
- KFSX currently provides a mount namespace and RamFS routing, not a mature multi-filesystem VFS.
- KEX is the Kynox executable container around an ELF64 payload. It is **not** Linux binary compatibility.
- Linux and Windows binary compatibility are both **0%** at this snapshot. No claim of running arbitrary Linux or Windows applications is made.
- zig build check runs unit, boot and storage checks. The interactive QEMU check is separate: zig build qemu-interactive-test.

## What's already in the tree

- Native UEFI bootloader and KNB→KNK handoff.
- Freestanding x86-64 kernel and Assembly entry, interrupt, syscall and context-switch paths.
- CPU, paging, PMM, heap, DMA, ACPI, PCI, APIC and early SMP components.
- User-mode tasks, native syscall dispatch, IPC channels and capability delegation/revocation.
- ELF64 parser/loader, KEX executable container, KPK package codec and initial Zig SDK.
- RamFS, KFSX mount namespace, KNV volume serialization and block abstraction.
- KVDI modern VirtIO transport and synchronous VirtIO Block read/write/flush path.
- Rasterizer, framebuffer bridge, compositor, window manager, input routing and desktop scene.
- Host unit tests and QEMU integration scripts for boot, storage persistence and interactive graphics/input.

## Build

Requires **Zig 0.17.0**.

```sh
zig version
zig build
```

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

## Architecture and development documents

- [AGENTS.md](AGENTS.md) — mandatory rules for coding agents and contributors.
- [strategy.md](strategy.md) — architecture strategy, phases and roadmap.
- [KYNOX_NATIVE.md](KYNOX_NATIVE.md) — own-technology policy and native/Linux/Windows execution architecture.
- [docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md) — detailed progress, evidence, gaps and priorities.
- [docs/PROJECT_STATUS.json](docs/PROJECT_STATUS.json) — machine-readable progress inventory.

## License

GPL-3.0-only
