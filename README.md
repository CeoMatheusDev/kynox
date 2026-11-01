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
| Kernel CPU, exceptions and interrupts | **81%** | Core paths exist; an interrupt-line registry replaces the vector `switch`, the **device vector space has owners** — every vector of 68..254 has its own entry point and an IDT gate installed from the stub table (the stub is what names the vector to the handler), the registry refuses a second owner and counts a vector that arrives without one, and a **vector allocator** lends a driver a block of N aligned vectors (MSI) or one vector per table entry (MSI-X) and checks a grant before freeing it — with no device vector ever fired, the tick source is one per machine but its **ownership is per processor** — a tick that arrives where it is not the clock is counted as ignored instead of silently doing nothing, the segment, its table and the stack of the double fault are **per processor**, and four kernel vectors (timer 64, reschedule 65, TLB shootdown 66, halt 67) have a gate, a stub and a handler; hardening and hardware coverage remain |
| Physical memory, heap and DMA | **60%** | Core allocators and DMA path exist; scalability/reclaim remain |
| Virtual memory and address spaces | **56%** | User mappings and isolation foundations; unmap returns the frames the space owns, an address space is destroyed and its slot reused (generation-checked), and an unmap now **asks every other processor to drop the translation** through a hook; advanced VM (regions, demand paging, COW) remains |
| ACPI, PCI and APIC | **66%** | MADT discovery drives the LAPIC base at boot; IOAPIC redirection entries are programmed **masked** and delivery still comes from the 8259; the **MSI capability is now programmed** (message address/data, 32- and 64-bit layouts, vector allocation, enable last) behind `-Dmsi-delivery`, with no MSI ever delivered; the **MSI-X capability is decoded** (table size stored as N-1, BIR and offset of the table and the PBA, a 16-byte entry per vector, and the enable order that fills the table before any interrupt can leave) and its table located but never written; a device message now has somewhere to land — vectors 68..254 are deliverable, one stub each, the spurious 255 excluded — but nothing has landed |
| SMP | **78%** | CPU table from the MADT, one stack per logical CPU, the AP trampoline **copied and patched below 1 MiB**, an AP that enters the scheduler with a **task of its own**, a **reschedule IPI** (vector 65), a **TLB shootdown** (vector 66) with a mailbox, a **clock per processor** (the BSP counts the 8254, an AP arms its own local APIC timer from the frequency the BSP measured), and a worker migrated to the first online AP at boot, a **halt IPI** (vector 67) so a fatal failure stops the machine as one instead of leaving the other processors writing over the report, and the block of the APs placed **against the extended BIOS data area** the firmware allocated below 1 MiB (the word at 0x40E), not only against the memory map; **no AP has ever answered**, so no IPI has been delivered and no AP has ever armed a clock |
| Scheduler and task switching | **83%** | EEVDF policy in its own module, a state lock with per-CPU ownership that counts its re-entries (the scheduler calls itself inside one decision), a generic blocking primitive that queues a wait with a deadline, a wait queue that cannot lose a wakeup, a mutex with a direct handoff, and an **idle task** the policy chooses only when nothing else can run — 72 host tests in the task artifact, including a four-thread lock contention test, an end-to-end mutex/scheduler test and the idle-task choice; every task **names the CPU that owns it**, the idle task exists per CPU, `migrateTo` moves a task to another queue, a **reschedule IPI** hands the processor over without counting a tick or charging the slice, and a wake that lands on a foreign queue kicks its owner; **no AP has ever taken a task** and the mutex has no user in the kernel yet |
| User mode and syscalls | **55–60%** | Ring 3 apps and native syscall path exist; ABI revision 1 is contract-checked; the ABI is still small and never ran in a VM here |
| IPC and capabilities | **60%** | Core mechanisms and a real object lifecycle (destroy, destroySubject, releaseProcess); broader service model remains |
| ELF64 and KEX native executables | **55–60%** | Native ELF loading and KEX container exist; dynamic linking remains |
| Native SDK and runtime | **40%** | Initial SDK and sample apps exist; public runtime is incomplete |
| RamFS, KFSX and KNV | **43–60%** | In-memory FS, mount namespace and volume codec exist; the VFS now exposes a **directory listing in chunks** (cookie plus a namespace generation, so a stale cookie is refused instead of resumed onto a reused slot); permissions and a second backend remain |
| VirtIO Block / KVDI | **65%** | Real synchronous block I/O and QEMU persistence probe exist; async I/O remains |
| Networking | **10%** | Header types and a transmit path that fails explicitly; no device, queues or stack |
| Graphics and compositor | **60%** | Rasterization, windows and composition exist; full desktop remains |
| Native graphics API and OpenGL/Vulkan compatibility | **0%** | Planned; KGA, KGL and KVK exist only as architecture |
| Input | **40%** | Initial keyboard/pointer paths; HID and hotplug remain |
| Desktop environment | **35%** | Managed windows and boot scene; shell and desktop applications remain |
| Linux binary compatibility | **0%** | Planned; no Linux execution personality yet |
| Windows binary compatibility | **0%** | Planned; no PE32+/Win64/NT/Win32 runtime yet |
| Security hardening | **45%** | Capabilities and W^X foundations; systematic hardening remains |
| Tests and validation infrastructure | **65%** | Host suite executes and passes (**889 tests**, including a documentation link check and a planning-document guard); a CI workflow runs the build, the host suite and the docs check (green), and its QEMU job fails at the dependency install, so no boot suite has ever run |
| Performance and observability | **40%** | Counters (including per-interrupt-line and unhandled-line), TSC timing and a boot benchmark; benchmark sources are not in the build graph |
| Build and developer tooling | **60%** | Zig build graph, image generator, zero external dependencies and a single version source guarded by tests; CI remains |

The full evidence-based inventory, including gaps and next steps, is maintained in **[PROJECT_STATUS.md](docs/PROJECT_STATUS.md)** and the machine-readable **[PROJECT_STATUS.json](docs/PROJECT_STATUS.json)**. Agents start at **[docs/ai/README.md](docs/ai/README.md)**: reading order, the authority of every document, and a one-page context pack.

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

- Kynox has early SMP code: the CPU table is built from the MADT, the trampoline is copied and patched below 1 MiB, so `startAps()` sends INIT/SIPI, and an AP that answered would enter the scheduler with a task and an idle task of its own — but **no AP has ever answered** in this environment, and a reschedule IPI lets another CPU put it to work (a worker is migrated to the first online AP at boot) — but no AP has ever answered here and no AP has a clock of its own, so APs still do not participate in the scheduler workload in any observed run.
- **The interrupt dispatch has never run.** The registry that replaced the vector `switch` (`kernel/arch/x86_64/interrupt_registry.zig`), the single tick source (`timer.selectTickSource`) and the frame release on unmap are code with host tests only; no boot has exercised them.
- The active VirtIO Block path is **KVDI** (kernel/drivers/kvdi/block.zig), which implements synchronous requests. kernel/arch/x86_64/virtio_blk.zig is a separate legacy stub and is not the active driver; its removal is decided in ADR-0003 but not yet executed. The boot marker `virtio: split queue layout ok` now proves KVDI's virtqueue (ADR-0002 step 2); the parallel queue code left in kernel/arch/x86_64/virtio.zig is a duplicate with no boot-path caller, and its deletion is ADR-0002 step 3, still pending.
- VirtIO Block completion currently uses polling; interrupt/MSI-X-driven asynchronous I/O and multi-queue support are not established.
- KNV commit/recovery and a QEMU two-boot block persistence probe exist. This does not yet provide journaled, power-loss-safe filesystem guarantees.
- KFSX currently provides a mount namespace and RamFS routing, not a mature multi-filesystem VFS.
- KEX is the Kynox executable container around an ELF64 payload. It is **not** Linux binary compatibility.
- Linux and Windows binary compatibility are both **0%** at this snapshot. No claim of running arbitrary Linux or Windows applications is made. The same applies to graphics: Kynox exposes **no** OpenGL and **no** Vulkan today; KGL and KVK exist only as architecture in `docs/architecture/graphics-compatibility.md`.
- zig build check runs unit, boot and storage checks. The interactive QEMU check is separate: zig build qemu-interactive-test.
- ACPI/MADT is consumed at boot: the LAPIC base and the IOAPIC list come from the table, with validation and a logged fallback to `0xFEE00000`. The I/O APIC redirection entries for IRQ0 (PIT) and IRQ1 (keyboard) are programmed **masked**, with the GSI/polarity/trigger taken from the interrupt source overrides; delivery still comes from the 8259, and the `-Dioapic-delivery=true` option that switches it has never been booted. No interrupt has been observed through the I/O APIC, and the path has never run in a VM (audit A-03, resolved in part; see docs/specs/acpi-platform.md).
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
- Host unit tests (889) and QEMU integration scripts for boot, storage persistence and interactive graphics/input.
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

### Verification record (2026-11-01)

| Command | Result |
|---|---|
| `zig version` | `0.17.0` |
| `zig build` | success — image written; `kynox-boot.efi` 185,344 B, `kynox.img` 128 MiB (32 731 clusters) |
| `zig build test` | success — 52/52 steps, **889/889 tests passed** (fresh cache; 736 → 748 with the scheduler policy tests → 781 with the wait queue, the mutex and the policy split → 788 with the channel integration and the documentation index → 800 with the state lock and the generic blocking primitive → 806 with the per-CPU segment and the idle task → 815 with the AP trampoline → 821 with the ownership of a task by a CPU → 828 with the reschedule IPI and the migration → 837 with the TLB shootdown → 841 with the clock of each processor → 845 with the halt IPI and the fatal path → 850 with the extended BIOS data area → 860 with the MSI capability → 868 with the MSI-X table → 873 with the device vector space → 881 with the vector allocator → 889 with the directory listing) |
| `zig build qemu-test` | **not executed** — no QEMU/OVMF in that environment |
| `zig build qemu-storage-test` | **not executed** — same reason |
| `zig build qemu-interactive-test` | **not executed** — same reason |

`zig build test` also runs the documentation link check (`docs-check`). The QEMU suites assert 117 markers and patterns (handoff, GDT/IDT, NX, PCI, DMA,
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
- [docs/decisions/](docs/decisions/README.md) — architecture decision records (ADR-0001…0007).
- [docs/strategy/market-landscape.md](docs/strategy/market-landscape.md) — market and technology landscape, with dated sources (planning document).
- [docs/architecture/platform-architecture.md](docs/architecture/platform-architecture.md) — target platform architecture and kernel/user-mode split (planning document).
- [docs/architecture/kernel-internals.md](docs/architecture/kernel-internals.md) — target kernel layering, module contracts, init phases and coding standards (planning document).
- [docs/architecture/memory-management.md](docs/architecture/memory-management.md) — frames, address spaces, regions, fault policy and memory invariants (planning document).
- [docs/architecture/execution-model.md](docs/architecture/execution-model.md) — processes, threads, scheduling policy and synchronisation primitives (planning document).
- [docs/architecture/device-driver-model.md](docs/architecture/device-driver-model.md) — device, driver and resource model, interrupt registration and containment (planning document).
- [docs/architecture/graphics-platform.md](docs/architecture/graphics-platform.md) — display system, driver model, graphics core, native API, renderer, compositor and tools (planning document).
- [docs/architecture/application-ecosystem.md](docs/architecture/application-ecosystem.md) — executable format, SDK, packaging, sandbox and compatibility (planning document).
- [docs/architecture/security-architecture.md](docs/architecture/security-architecture.md) — threat model, capability proofs and explicit non-guarantees (planning document).
- [docs/architecture/user-experiences.md](docs/architecture/user-experiences.md) — home, gaming, development, enterprise and professional profiles with measurable requirements (planning document).
- [docs/architecture/graphics-compatibility.md](docs/architecture/graphics-compatibility.md) — KGA formalised, and KGL/KVK over a shared execution core (KGX) (planning document).
- [docs/architecture/linux-compatibility.md](docs/architecture/linux-compatibility.md) — KLC: ELF64, syscall translation, signals, libraries, namespace (planning document).
- [docs/architecture/windows-compatibility.md](docs/architecture/windows-compatibility.md) — KWC: PE32+, ntdll, handles, SEH, user32/GDI, D3D future (planning document).
- [docs/roadmap/COMPATIBILITY_ROADMAP.md](docs/roadmap/COMPATIBILITY_ROADMAP.md) — compatibility phases C0–C11 with criteria, tests and evidence (planning document).
- [docs/roadmap/PRODUCT_ROADMAP.md](docs/roadmap/PRODUCT_ROADMAP.md) — stages S0–S15 with an evidence ladder (planning document).
- [docs/roadmap/KERNEL_COMPLETION_ROADMAP.md](docs/roadmap/KERNEL_COMPLETION_ROADMAP.md) — kernel stages K0–K13 in dependency order, with criteria, tests and promotion rules (planning document).
- [docs/audits/2026-10-31-audit.md](docs/audits/2026-10-31-audit.md) — audit, findings and prioritized plan.
- [docs/audits/2026-10-31-kernel-core-audit.md](docs/audits/2026-10-31-kernel-core-audit.md) — kernel and core systems audit: A–G classification, test-coverage truth and ranked defects.
- [docs/audits/2026-11-01-msix-table.md](docs/audits/2026-11-01-msix-table.md) — MSI-X: the table in device memory, the size field that stores N-1, and the enable order that fills the table before any interrupt can leave.
- [docs/audits/2026-11-01-msi-programming.md](docs/audits/2026-11-01-msi-programming.md) — MSI: the message a device writes to interrupt, the register layout, the order of the writes and the build flag that decides whether it happens.
- [docs/audits/2026-11-01-bda-and-ebda.md](docs/audits/2026-11-01-bda-and-ebda.md) — the firmware data below 1 MiB: the EBDA pointer at 0x40E and why the memory map alone is not enough to place a block there.
- [docs/audits/2026-11-01-halt-ipi-and-fatal.md](docs/audits/2026-11-01-halt-ipi-and-fatal.md) — the halt IPI (vector 67) and the fatal path: a failing machine stops as one, and the report promises only what it can.
- [docs/audits/2026-11-01-per-cpu-clock.md](docs/audits/2026-11-01-per-cpu-clock.md) — the clock of each processor: the per-CPU role of a clock, the ledger of ticks, and the counter of ticks that were ignored.
- [docs/audits/2026-11-01-tlb-shootdown.md](docs/audits/2026-11-01-tlb-shootdown.md) — the TLB shootdown: vector 66, the mailbox that carries the page, the generation that survives a late answer, and the reported timeout.
- [docs/audits/2026-11-01-reschedule-ipi.md](docs/audits/2026-11-01-reschedule-ipi.md) — the reschedule IPI (vector 65): a decision that is not a tick, `migrateTo`, and the wake that lands on a foreign queue.
- [docs/audits/2026-11-01-cpu-affinity.md](docs/audits/2026-11-01-cpu-affinity.md) — every task names the CPU that owns it, and the idle task exists per CPU.
- [CHANGELOG.md](CHANGELOG.md) — release history and unreleased changes.
- [docs/releases/0.1.0-alpha.1.md](docs/releases/0.1.0-alpha.1.md) — release notes (draft; the tag does not exist).

## License

GPL-3.0-only
