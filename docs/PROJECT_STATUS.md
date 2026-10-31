# Kynox — Project Status & Progress

> Snapshot: 2026-10-31. This is a source-tree audit, not a claim that the listed tests were executed on this date. Percentages are **engineering maturity estimates**, not measured completion of the entire operating system.

## How to read the percentages

The percentage estimates the maturity of the scoped subsystem, based on source implementation, integration evidence, tests present in the repository, and known limitations:

| Range | Meaning |
|---:|---|
| 0% | No implementation found; only a goal or proposal |
| 1–19% | Initial design, types, or isolated groundwork |
| 20–39% | Partial implementation; important execution paths are missing |
| 40–59% | Core implementation exists, but integration or semantics remain limited |
| 60–79% | Integrated path exists and has repository-level test coverage; important limitations remain |
| 80–99% | Broadly implemented; hardening, compatibility, or validation remains |
| 100% | Scope fully specified, integrated, tested, validated, and documented |

These are not percentages of lines of code, feature count, or time spent. A module with many source files can still have a low score if its real execution path is missing. Do not calculate a single overall OS percentage by averaging unrelated areas.

**Validation distinction:** tests existing in the tree is not the same as tests passing. The audit that produced this snapshot inspected code and build definitions; it did not run Zig builds or QEMU. Therefore no test is marked as newly passed by this snapshot.

## Current progress matrix

| Subsystem | Maturity | State | What exists | Main gaps |
|---|---:|---|---|---|
| UEFI bootloader / handoff | **70%** | In progress | Native UEFI application, KNB→KNK handoff, memory map, framebuffer and boot image generation | Broader firmware/hardware matrix, relocation/high-half transition, stronger failure/recovery validation |
| Kernel entry / CPU / interrupts | **60%** | In progress | x86-64 entry, GDT/TSS, IDT, exception/interrupt stubs, CPU helpers, timer and syscall entry assembly | Full exception recovery audit, per-CPU state, hardware diversity and hardening |
| Physical memory / heap / DMA | **60%** | In progress | PMM, kernel heap, DMA allocation/mapping and DMA window probes | Scalability, fragmentation policy, reclaim, allocator stress and broader DMA/IOMMU protection |
| Virtual memory / address spaces | **45%** | Partial | Four-level paging, user mappings, separate process roots, W^X checks and translation tests | General-purpose VM regions, dynamic page-table allocation, demand paging, COW, ASLR, TLB shootdown and high-half layout |
| ACPI / PCI / APIC | **50%** | In progress | ACPI table parsing, MADT discovery code, PCI configuration/BAR helpers, local APIC and IPI primitives | APIC base is still a fixed default in parts of the path; IOAPIC routing and robust hardware discovery need completion |
| SMP / AP startup | **30%** | Partial | AP stacks, trampoline, INIT/SIPI startup path and AP entry code are present and invoked | APs do not yet participate in normal scheduling; per-CPU timers, IPI coordination and SMP-safe scheduler/locks need completion |
| Scheduler / task switching | **55%** | Partial | Timer-driven preemption, task contexts, task states, context-switch assembly and scheduler statistics | Scheduling remains effectively BSP-centric; per-CPU run queues, migration, fairness policy and SMP stress |
| User processes / Ring 3 | **60%** | In progress | User-mode execution, process address spaces, multiple built test applications and lifecycle checks | General process creation/teardown, resource limits, dynamic mappings and robust isolation under stress |
| Native syscall ABI | **55%** | Partial | SYSCALL/SYSRET entry path, register frame, syscall dispatch and SDK wrappers | Stable versioned ABI, broader syscall surface, complete pointer/buffer validation and ABI conformance suite |
| IPC | **60%** | In progress | Bounded channels, message queues, blocking wait/wakeup paths and tests | Generalized service discovery, shared-memory IPC, backpressure/cancellation semantics and user-space service architecture |
| Capabilities / security model | **60%** | In progress | Typed capability kinds, per-holder rights, delegation/revocation and syscall enforcement paths | Complete object coverage, process lifecycle integration, auditing, adversarial testing and broader threat-model validation |
| ELF64 loader | **60%** | In progress | ELF64 parsing, load planning, segment checks, relative relocations, materialization and execution of test applications | Dynamic linking, shared libraries, TLS, richer relocations, robust ABI/runtime support |
| KEX native executable container | **55%** | Partial | KEX v1 wrapper around ELF64, manifest capability entries, CRC validation and kernel integration | Finalize executable specification, signature/trust model, dependency metadata, ABI versioning and production-grade toolchain |
| KPK package format | **45%** | Partial | Package codec and install/read-back test path | Package manager, trust/signature policy, dependency resolution and atomic update lifecycle |
| Native SDK / runtime | **40%** | Partial | Zig SDK modules, syscall wrappers, sample native apps and assembly startup | Stable public API, libc-like/native library surface, dynamic linker and developer tools |
| RamFS | **55%** | Partial | In-memory filesystem, inode/block allocation, directories, file operations and validation tests | Persistent general-purpose backend, permissions, larger files/scale and crash recovery |
| KFSX namespace / VFS | **35%** | Partial | Mount namespace, longest-prefix routing, mount generations and RamFS volume routing | Multiple real backends, complete VFS operations, permissions, concurrency and device integration |
| KNV volume format | **60%** | In progress | Deterministic little-endian image codec, validation, CRC, commit/recover logic and tests | Journal, atomic dual-image replacement, power-loss consistency and larger-volume strategy |
| Physical block storage | **65%** | In progress | Modern PCI VirtIO Block discovery, negotiated transport, DMA virtqueue, block driver, read/write/flush and QEMU two-boot persistence probe | Interrupt/MSI-X completion path, multi-queue, timeout/performance tuning and broader physical hardware validation |
| KVDI / VirtIO transport | **65%** | In progress | Modular KVDI transport, PCI capabilities/BAR validation, feature negotiation, queue ownership and containment/quarantine | Async/interrupt-driven I/O, multi-device/multi-queue support and broader device coverage |
| Networking | **10%** | Early groundwork | VirtIO network identifiers/features and module scaffolding | Working network device driver, Ethernet, ARP, IP, UDP/TCP, sockets and user-space network service |
| Graphics / compositor | **60%** | In progress | Rasterizer, framebuffer bridge, window manager, damage tracking, composition, surfaces and presentation tests | GPU acceleration, robust multi-client service boundary, display hotplug/modes and full desktop shell |
| Input | **40%** | Partial | PS/2 keyboard path, input abstractions, pointer/event routing and tests | Mouse/device discovery, HID/USB input, hotplug, keymap/layout and full input service |
| Desktop / windowing UX | **35%** | Partial | Managed desktop scene, window handles, focus/input routing and boot graphics demo | Taskbar, launcher, shell, terminal, file manager, settings, notifications and independent compositor process |
| Linux binary compatibility | **0%** | Planned | No Linux personality/compatibility runtime established | Linux ELF process ABI, syscall translation, signals, futexes, TLS, dynamic linker and library compatibility |
| Windows binary compatibility | **0%** | Planned | No PE32+/NT/Win32 compatibility runtime established | PE loader, Win64 ABI, NT/Win32 APIs, DLLs, TLS, unwind/exceptions and runtime libraries |
| Security hardening | **45%** | Partial | Ring 3, page permissions, W^X checks, capabilities and device containment mechanisms | SMEP/SMAP policy, ASLR/KASLR, systematic threat models, fuzzing and security audit |
| Tests / validation infrastructure | **65%** | In progress | Host test targets, QEMU boot/storage/interactive scripts, framebuffer/presentation comparisons and integration checks | Run and publish current results, CI matrix, fuzz harnesses, hardware coverage and reproducible performance reports |
| Performance / observability | **40%** | Partial | Scheduler/syscall/graphics counters, TSC timing, benchmark source and serial diagnostics | Reproducible baselines, p50/p95/p99 reports, cross-hardware measurements and regression thresholds |
| Build / developer tooling | **60%** | In progress | Zig build graph, UEFI/kernel/app artifacts, image generation, host tests and QEMU targets | Reproducible CI, artifact packaging, symbol/debug workflow and user-facing SDK/toolchain completeness |

## Implemented foundations

The following are present in the source tree; this does not imply that every feature is complete or production-ready:

- UEFI boot application and shared boot handoff.
- Freestanding x86-64 kernel and Assembly entry/context-switch/syscall paths.
- CPU, interrupt, timer, ACPI, PCI, APIC and early SMP code.
- PMM, heap, virtual paging, process address spaces and DMA support.
- User-mode tasks, native syscall dispatch, IPC channels and capabilities.
- ELF64 parsing/loading, KEX executable container and KPK package codec.
- RamFS, KFSX mount namespace, KNV volume codec and block abstraction.
- KVDI modern VirtIO transport and a synchronous VirtIO Block request path.
- Rasterization, framebuffer presentation, compositor, windows and desktop scene.
- Host unit tests and QEMU integration scripts.

## Important limitations and corrections

1. **SMP is not complete.** AP startup code exists and is called, but APs currently do not run the normal scheduler workload. Do not describe Kynox as a fully SMP operating system.
2. **The active VirtIO Block path is KVDI.** `kernel/drivers/kvdi/block.zig` is the real request driver used by `kernel/main.zig`; it is distinct from the legacy `kernel/arch/x86_64/virtio_blk.zig` stub, which still returns `NotImplemented`.
3. **VirtIO Block uses synchronous polling.** The queue is not yet driven by an interrupt/MSI-X completion path; multi-queue and asynchronous I/O are not established.
4. **Persistence has bounded evidence.** The repository contains KNV commit/recovery code and a QEMU two-boot raw block persistence probe. This is not equivalent to a journaled, power-loss-safe production filesystem.
5. **KFSX is not a complete VFS.** The current mount namespace routes RamFS volumes; do not imply support for multiple mature on-disk filesystem backends.
6. **ELF/KEX is not Linux compatibility.** KEX wraps an ELF64 payload for Kynox. Linux ABI compatibility is currently 0%.
7. **Windows compatibility is currently 0%.** There is no implemented PE32+/Win64/NT/Win32 execution environment.
8. **The `check` target does not include the interactive QEMU test.** It includes unit, boot and storage tests; `zig build qemu-interactive-test` is a separate target.
9. **Test status is unknown for this snapshot.** Test scripts and build targets exist, but this audit did not execute them.

## Next priorities

1. Run and record `zig version`, `zig build`, `zig build test`, `zig build qemu-test`, `zig build qemu-storage-test` and `zig build qemu-interactive-test`.
2. Correct stale module comments so documentation matches the active KVDI block driver and SMP startup path.
3. Complete SMP scheduler integration and per-CPU invariants.
4. Finish VMM/address-space foundations and remove fixed hardware assumptions from APIC/IOAPIC discovery.
5. Strengthen native KEX/ELF ABI, linker and SDK before adding compatibility personalities.
6. Define Linux compatibility as an isolated execution personality; start with a deliberately small ELF64 static test matrix.
7. Define Windows compatibility as a separate PE32+/Win64/NT personality; do not conflate PE parsing with Win32 support.
8. Expand VFS and durable storage guarantees, including journal/atomic commit and recovery testing.
9. Evolve graphics/input into isolated user-space services and a complete desktop shell.
10. Add fuzzing, CI, security audits and reproducible performance baselines.

## Updating this status

The machine-readable counterpart is [`PROJECT_STATUS.json`](PROJECT_STATUS.json). Update both files in the same change whenever implementation status changes. See [`AGENTS.md`](../AGENTS.md) for mandatory agent rules.

Never raise a percentage because files were added, code was written, or a test was authored. Raise it only when the subsystem's defined behavior is integrated and supported by evidence. Record blockers and validation separately.
