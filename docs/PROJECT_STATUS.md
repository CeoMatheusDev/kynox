# Kynox — Project Status & Progress

> Snapshot: **2026-11-01**, produced by a source-tree review that **executed** the
> build and the host test suite, and that also implemented the audit defects which
> did not need a hypervisor. Percentages are **engineering maturity estimates**,
> not measured completion of the entire operating system.
>
> Identity: **Kynox One 0.1.0-alpha.1** — technical version `0.1.0-alpha.1`
> (`VERSION`), generation `Kynox One` (major `0`). Policy in
> [`VERSIONING.md`](VERSIONING.md), chart in [`roadmap/ERAS.md`](roadmap/ERAS.md).
>
> Audit reports: [`docs/audits/2026-10-31-audit.md`](audits/2026-10-31-audit.md)
> (tree, findings, alpha gate) and
> [`docs/audits/2026-10-31-kernel-core-audit.md`](audits/2026-10-31-kernel-core-audit.md)
> (kernel and core systems A–G, classification and ranked defects), plus
> [`docs/audits/2026-11-01-kernel-core-fixes.md`](audits/2026-11-01-kernel-core-fixes.md)
> (the implementation record of the defects closed after it).
> Machine-readable counterpart (schema v2): [`PROJECT_STATUS.json`](PROJECT_STATUS.json).

## How to read the percentages

The percentage estimates the maturity of the scoped subsystem, based on source
implementation, integration evidence, tests present in the repository, and known
limitations:

| Range | Meaning |
|---:|---|
| 0% | No implementation found; only a goal or proposal |
| 1–19% | Initial design, types, or isolated groundwork |
| 20–39% | Partial implementation; important execution paths are missing |
| 40–59% | Core implementation exists, but integration or semantics remain limited |
| 60–79% | Integrated path exists and has repository-level test coverage; important limitations remain |
| 80–99% | Broadly implemented; hardening, compatibility, or validation remains |
| 100% | Scope fully specified, integrated, tested, validated, and documented |

These are not percentages of lines of code, feature count, or time spent. A
module with many source files can still have a low score if its real execution
path is missing. Do not calculate a single overall OS percentage by averaging
unrelated areas.

**State vocabulary** (mandated by `AGENTS.md`): `not_started`, `scaffolding`,
`in_progress`, `implemented`, `integrated`, `validated`, `blocked`. The previous
schema used `partial`/`planned`; the migration is recorded in the JSON
(`status_migration`). No subsystem is `validated` today, because no runtime
(QEMU/hardware) evidence exists for this snapshot.

**Validation distinction.** On 2026-11-01 the following were executed:
`zig build` (image written) and `zig build test` (52/52 steps, **815/815 tests**
with a fresh cache). `zig build qemu-test`, `qemu-storage-test`,
`qemu-interactive-test` and `check` were **not executed** — the environment has
no QEMU, no OVMF and no reachable package mirror. Host test results therefore
appear as `host_tests_passed`; every runtime claim remains `not_executed`.

**Correction of the previous snapshot.** The 2026-10-31 record claimed 716 tests
for a tree whose `arch-tests` artifact did not compile (an unnamed inline-assembly
operand in `fpu.zig` and an out-of-module import in `paging.zig`), so the
architecture tests — paging, ACPI, SMP, PCI — were absent from the suite. The
count below is measured after the fix, and the artifact is part of the run.

## Executed validation record

| Command | Date | Result |
|---|---|---|
| `zig version` | 2026-11-01 | `0.17.0` |
| `zig build` | 2026-11-01 | success — `kynox-boot.efi` 185,344 B · `kynox-kernel` (debug) · `kynox.img` 134,217,728 B (128 MiB, FAT16 ESP, 32,731 clusters) |
| `zig build test --summary all` (fresh cache) | 2026-11-01 | success — 52/52 steps, **815/815 tests** (24 artifacts): kvdi 173 · fs-loader 154 · arch 155 · shared 64 · task 63 · kernel 22 · user-composition 22 · security 22 · docs-conformance 24 · damage 15 · version 13 · keyboard-motion 13 · kpk 9 · compositor 9 · ipc 9 · sdk 8 · abi-conformance 7 · kex 7 · display 7 · raster 5 · keyboard 4 · block-api 4 · ai 3 · boot-markers-conformance 3; includes `docs-check`, the link check, the document-index check and the four QEMU targets **not executed** |
| `zig build docs-check` | 2026-11-01 | success — every relative link resolves |
| `zig build qemu-test` | — | **not executed** (no QEMU/OVMF) |
| `zig build qemu-storage-test` | — | **not executed** |
| `zig build qemu-interactive-test` | — | **not executed** |
| `zig build check` | — | **not executed** (depends on the QEMU steps) |

## Current progress matrix

| Subsystem | Maturity | State | What exists | Main gaps |
|---|---:|---|---|---|
| UEFI bootloader / handoff | **70%** | in_progress | Native UEFI application, kernel placement (ET_DYN bias, RELA), versioned KNB→KNK handoff, framebuffer/ACPI RSDP capture, ExitBootServices retry | No host tests for loader logic; firmware/hardware matrix; `processor_count` fixed to 1; boot never observed here |
| Kernel entry / CPU / interrupts | **66%** | in_progress | x86-64 entry with kernel-owned stack, IDT, exception/interrupt stubs, timer, fault self-test, NX enforced before use; **interrupt-line registry** (one owner per line, counters, spurious accounting) with the 8254 and PS/2 lines registered at boot; one tick source per system (`timer.selectTickSource`), the local APIC timer calibrated and left disarmed; the **segment, its table and the double-fault stack are per processor** (`segment.installForCpu`, used by the entry of an AP) | Exception recovery audit, the per-CPU interrupt state beyond the segment, the dispatch path has never run, hardware coverage |
| Physical memory / heap / DMA | **60%** | in_progress | PMM over the handoff map, kernel heap, DMA allocation/mapping and window probe | Scalability, fragmentation policy, reclaim, IOMMU |
| Virtual memory / address spaces | **50%** | in_progress | Four-level paging, per-process user windows, W^X encoded with negative tests, `isUserRange` validation everywhere; **ownership bit for frames** so an unmap returns the page it owns and leaves a borrowed one, address-space destruction that returns the frames, the private chain and the slot, slot reuse with a per-slot generation | Region abstraction, demand paging, COW, ASLR, TLB shootdown, high-half |
| ACPI / PCI / APIC | **50%** | in_progress | ACPI RSDP/XSDT/MADT discovery at boot with validated LAPIC base and recorded IOAPICs/overrides, I/O APIC access and redirection-entry programming for the ISA lines (masked), PCI config + BAR + capability walking, LAPIC xAPIC access and IPIs | **I/O APIC entries are programmed masked**; delivery still comes from the 8259 (I/O APIC delivery is an unproven build option); PCI GSI routing and interrupt remapping absent; no QEMU/hardware evidence |
| SMP / AP startup | **44%** | in_progress | CPU table built from the MADT (APIC ids, BSP by id), one stack per logical CPU indexed by the table number, and the AP trampoline **copied and patched below 1 MiB** by `smp.prepareTrampoline` (placement validated against the firmware map, fields validated against the block, `ready` written last per AP, `EFER` bits of the BSP carried into the block), then gated INIT/SIPI | No AP has ever answered, so no second processor has run; no same-timer kick per CPU; no IPI beyond INIT/SIPI; the EBDA pointer is not checked; no SMP run ever recorded |
| Scheduler / task switching | **74%** | in_progress | Timer-driven preemption, EEVDF policy in its own pure module, a **state lock with per-CPU ownership** (`task/lock.zig`: owner, depth, contentions, re-entries, refused releases) taken by every entry point, `blockCurrentOn` as the generic blocking primitive, a wait queue with deadlines and no lost wakeup, a mutex with ownership and direct handoff, an **idle task** that the policy chooses only when nothing else can run (ring 3, `sti; hlt`), and **63 host tests** (`task-tests`) — including a four-thread contention test of the lock, an end-to-end mutex → wait queue → scheduler test and the idle-task choice | No AP has ever run, so no two processors ever contend in the kernel and the idle task has never halted here; the mutex has no user in the kernel yet; the state lock does not cover `statisticsOf` (documented); no rwlock, no condition variable; migration, fairness and SMP validation remain |
| User processes / Ring 3 | **60%** | in_progress | User-mode tasks, separate address spaces, two embedded native apps, lifecycle probe | General process API, resource limits, isolation stress |
| Native syscall ABI | **55%** | in_progress | `syscall`/`iretq` door with MSR programming, 22 calls (12 reserved), pointer validation, SDK wrappers; one normative contract (`shared/syscall_abi.zig`, revision 1) aliased by kernel and SDK; conformance suite against the spec | Door never executed in a VM here; no argument fuzzing; revision checked at build/test time only |
| IPC | **60%** | in_progress | Bounded channels, blocking receive, receive with timeout, scheduler integration | Shared memory, service discovery, cancellation |
| Capabilities / security model | **60%** | in_progress | Typed kinds, per-holder rights, delegation/revocation, enforcement in syscalls; **destroy / destroySubject / releaseProcess** so the table is a pool and not a 16-entry lifetime budget, and the reap releases the set and the capabilities that named the dead process | Handle generations, per-process handle namespace, quotas, adversarial tests |
| ELF64 loader | **60%** | in_progress | Parsing, load planning, segment checks, relative relocations, materialization | Dynamic linking, TLS, richer relocations, malformed-input corpus |
| KEX native container | **55%** | in_progress | KEX v1 around ELF64, manifest entries, CRC validation, loader integration | Specification document, signature/trust, dependency metadata, ABI version |
| KPK package format | **45%** | in_progress | Codec with validation/checksum; pack/unpack exercised at boot | Package manager, signatures, dependencies, atomic update |
| Native SDK / runtime | **40%** | in_progress | Raw syscall layer, typed wrappers, shared contracts, two sample apps, startup assembly | Stable API promise, libraries, dynamic linker, allocator/libc |
| RamFS | **55%** | in_progress | In-memory FS: inodes, blocks, directories, file operations | Permissions, scale, crash recovery |
| KFSX namespace / VFS | **35%** | in_progress | Mount namespace, longest-prefix routing, mount generations, RamFS routing | Multiple backends, complete VFS operations, permissions, concurrency |
| KNV volume format | **60%** | in_progress | Deterministic little-endian image codec, validation, CRC, commit/recover; two-boot probe script | Journal, atomic dual-image commit, power-loss consistency |
| Physical block storage | **65%** | in_progress | PCI VirtIO Block discovery, feature negotiation, DMA virtqueue, synchronous read/write/flush | Interrupt/MSI-X, multi-queue, timeouts/reset, hardware coverage |
| KVDI / VirtIO transport | **65%** | in_progress | Transport layer, PCI capabilities/BAR validation, virtqueue, containment/quarantine, fault injection | Async completion, multi-device/queue, more device classes |
| Networking | **10%** | scaffolding | VirtIO-net identifiers/features, Ethernet/ARP/IPv4/UDP/TCP/ICMP header types, and a transmit path that **fails explicitly** (`error.NotImplemented`) instead of reporting a delivery that never happened | Driver, queues, frames, Ethernet/ARP/IP/UDP/TCP stack, sockets, service |
| Graphics / compositor | **60%** | in_progress | Rasterizer, framebuffer bridge, window manager, damage tracking, surface presentation | GPU acceleration, isolated compositor service, display modes/hotplug |
| Graphics API and compatibility (KGA/KGL/KVK) | **0%** | not_started | No implementation; architecture and phases documented | KGA, KGX shared core, OpenGL front-end, Vulkan front-end, shader ingestion |
| Input | **40%** | in_progress | PS/2 keyboard decode, event queue, pointer motion, input syscalls with capability checks | Mouse/HID/USB, hotplug, keymaps, input service |
| Desktop / windowing UX | **35%** | in_progress | Managed desktop scene, window handles, focus/input routing, boot graphics demo | Taskbar, launcher, shell, terminal, file manager, settings, session model |
| Linux binary compatibility | **0%** | not_started | No implementation; architecture in `architecture/linux-compatibility.md`, phases C-L0…C5 | Personality gate, syscall translation, signals/futex/TLS, KLD/KLIBC, window bridge |
| Windows binary compatibility | **0%** | not_started | No implementation; architecture in `architecture/windows-compatibility.md`, phases C-W0…W6 | PE32+ loader, TEB/PEB, KOB handles, SEH/unwind, user32/GDI, COM |
| Security hardening | **45%** | in_progress | Ring 3, page permissions, NX/W^X, capabilities, device containment, bus-master revocation | SMEP/SMAP policy, ASLR/KASLR, threat models, fuzzing, audit |
| Tests / validation infrastructure | **65%** | in_progress | 24 host artifacts (**815 tests**, measured on 2026-11-01) in `zig build test`, including a documentation link check and a planning-document structure guard; the architecture artifact compiles again (155 tests) and `virtio_net.zig` is finally part of a test root; QEMU boot/storage/interactive scripts with 117 marker/pattern assertions; framebuffer/presentation comparison scripts; CI workflow defined (build/test/docs + explicit-failure QEMU job) | CI never executed; no recorded QEMU result; no fuzzing; no hardware matrix |
| Performance / observability | **40%** | in_progress | Scheduler/syscall/graphics counters, per-interrupt-line counters and unhandled-interrupt accounting, TSC timing, boot-time framebuffer benchmark, serial diagnostics | Benchmark source not in the build graph; no baselines/percentiles/thresholds |
| Build / developer tooling | **60%** | in_progress | Zig 0.17.0 build graph (boot, kernel, 2 apps, image, 22 host-test artifacts, `docs-check`, QEMU steps), `fatimg --version`, `bin2zig`, single version source (`VERSION`), generation-name resolution guarded by tests, zero external deps | CI defined but never run; toolchain installed by hand; no reproducible-artifact story |

## Implemented foundations

Present in the source tree; this does not imply completeness or runtime
validation:

- UEFI boot application and the versioned KNB→KNK handoff
  (`docs/specs/boot-handoff-spec.md`).
- Freestanding x86-64 kernel; Assembly entry, context-switch, interrupt and
  syscall paths.
- CPU, interrupt, timer, ACPI, PCI, APIC and early SMP code.
- PMM, heap, four-level paging, per-process address spaces and DMA support.
- User-mode tasks, native syscall dispatch
  (`docs/specs/syscall-abi.md`), IPC channels and capabilities.
- ELF64 parsing/loading/materialization, KEX container, KPK codec.
- RamFS, KFSX mount namespace, KNV volume codec, block layer.
- KVDI transport and a synchronous VirtIO Block request path.
- Rasterization, framebuffer presentation, compositor, window manager, PS/2
  input and a boot-time desktop scene.
- Host unit tests (815) and QEMU integration scripts.

## Planning documents (not implementation)

The following documents were created on 2026-10-31 to fix contracts before any
graphics, desktop, packaging or compatibility code is written, and — for the
kernel — before any further kernel work is ordered. They are listed
here so that a reader cannot mistake a plan for a capability. **No percentage in
this file moved because of them.**

| Document | Content | State of the described work |
|---|---|---|
| [strategy/market-landscape.md](strategy/market-landscape.md) | Market structure, nine technology deep dives, ranked opportunities, dated sources S1–S26 | Analysis only |
| [architecture/platform-architecture.md](architecture/platform-architecture.md) | Layer map, kernel/user-mode split, twenty subsystem contracts, dependency graph, cross-cutting rules | Target architecture; §10 maps the tree as it is today |
| [architecture/graphics-platform.md](architecture/graphics-platform.md) | Display System, GPU driver model, graphics core, native API, renderer, compositor, tools, security and performance model | Nothing implemented; the tree has a software rasteriser and an in-kernel compositor |
| [architecture/application-ecosystem.md](architecture/application-ecosystem.md) | KEX v2 layout, loader pipeline, SDK layers, KPK packaging, sandbox portals, atomic updates, compatibility contract | Planning; KEX/KPK codecs exist, no package manager, no SDK API beyond the syscall wrappers |
| [architecture/security-architecture.md](architecture/security-architecture.md) | Threat model, trust boundaries, capability proof obligations, device isolation, supply chain, recovery, explicit non-guarantees | Planning; SMEP/SMAP and KPTI exist, IOMMU and measured boot do not |
| [architecture/user-experiences.md](architecture/user-experiences.md) | Five profiles (home, gaming, development, enterprise, professional) with measurable requirements, what they share, and the rule that a profile is policy, never a separate ABI | No profile exists beyond the boot scene |
| [architecture/graphics-compatibility.md](architecture/graphics-compatibility.md) | KGA formalised; KGL (OpenGL) and KVK (Vulkan) over one shared execution core (KGX); deviation and performance-claim policy | Nothing implemented; no API exists |
| [architecture/linux-compatibility.md](architecture/linux-compatibility.md) | KLC: seven separated contracts, ELF64, syscall translation options, signals, futex/TLS, KLD/KLIBC/KVD, namespace and permissions, phases C-L0…C-L5 | Nothing implemented; 0% |
| [architecture/windows-compatibility.md](architecture/windows-compatibility.md) | KWC: PE32+ loader, TEB/PEB, KOB handles, ntdll/kernel32/CRT, SEH/unwind, registry, user32/GDI, COM, D3D evaluation, phases C-W0…C-W6 | Nothing implemented; 0% |
| [roadmap/COMPATIBILITY_ROADMAP.md](roadmap/COMPATIBILITY_ROADMAP.md) | Phases C0–C11 with criteria, conformance and performance tests, evidence and promotion rules; critical review of the proposed order | No phase complete |
| [roadmap/PRODUCT_ROADMAP.md](roadmap/PRODUCT_ROADMAP.md) | Stages S0–S15 ordered by dependency, with the P/F/E/H evidence ladder | No stage complete |
| [architecture/kernel-internals.md](architecture/kernel-internals.md) | Target kernel layering, module contracts, global-state policy, error model, initialisation phases, observability and the coding standards binding on kernel work | The tree still has the structure the audit describes; `main.zig` is the boot order |
| [architecture/memory-management.md](architecture/memory-management.md) | Frames, address spaces, regions, page-fault policy, heap locking, DMA interface and eight memory invariants | PMM, paging, heap and DMA exist. Unmap now returns the frames the space owns and address spaces are destroyed and their slots reused (invariant M2 has a unit test); regions, demand paging and COW do not exist |
| [ai/README.md](ai/README.md), [ai/context-pack.md](ai/context-pack.md), [ai/doc-index.json](ai/doc-index.json) | The entry point for an agent: reading order, what each document is allowed to be quoted for, the state of the tree in one page, and the generated index of all 65 documents with their authority | Executed: the index is generated by `tools/scripts/gen-doc-index.py` and checked by `zig build test` (a document that nobody classified fails the build) |
| [architecture/execution-model.md](architecture/execution-model.md) | Process and thread objects, lifecycle, scheduling policy, synchronisation primitives, time and the user/kernel transition contract | A minimal process object exists; the scheduler has host tests over its policy and 21 more exercise the wait queue and the mutex, but the scheduler still has no lock; no rwlock and no condition variable |
| [architecture/device-driver-model.md](architecture/device-driver-model.md) | Device, driver and resource objects, interrupt registration, DMA ownership, class interfaces, containment and the per-class test tiers | No driver model. **Interrupt registration now exists** (`interrupt_registry.zig`, one owner per line, counters, spurious accounting, host-tested); device and driver objects do not |
| [roadmap/KERNEL_COMPLETION_ROADMAP.md](roadmap/KERNEL_COMPLETION_ROADMAP.md) | Fourteen stages K0–K13 in dependency order, each with objective, initial state, files, dependencies, work, completion criteria, tests, QEMU/hardware validation, risks and P/F/E/H promotion; genuine parallelism; blockers | No stage complete and nothing above P. Several required-work items are implemented without a recorded run — see [audits/2026-11-01-kernel-core-fixes.md](audits/2026-11-01-kernel-core-fixes.md) |
| [audits/2026-11-01-ap-trampoline.md](audits/2026-11-01-ap-trampoline.md) | Implementation record of the AP trampoline as data: the copy below 1 MiB, the fields the BSP writes, the order of `ready`, the EFER bits and the single CPU numbering | Code and host tests only; **no AP has ever answered a SIPI here** |
| [audits/2026-11-01-idle-task-and-per-cpu-tss.md](audits/2026-11-01-idle-task-and-per-cpu-tss.md) | Implementation record of audit defects 2 (a single global TSS) and the idle half of 1: the per-CPU segment, table and double-fault stack, and the idle task of ring 3 | Code and host tests only; no AP has run and no `hlt` of this tree has executed here |
| [audits/2026-10-31-kernel-core-audit.md](audits/2026-10-31-kernel-core-audit.md) | Audit record, not a plan: A–G classification with evidence levels, test-coverage truth, fifteen ranked defects, documentation-versus-code review | Describes the tree at `343e9fb`; claims no capability |

The last row is an audit record, not a plan: it is listed here so that the
inventory is complete, and it plans nothing.

Decisions with analysed alternatives are recorded in
[ADR-0004…0010](decisions/README.md) and marked "accepted for planning". A
`docs-conformance-tests` host test asserts that these documents keep their
required sections, their dated sources and their presence in this inventory.

## Important limitations and corrections

1. **SMP is not complete — and no AP has ever answered.** The CPU table is now
   built from the MADT (enabled processors, BSP by APIC id, duplicates skipped),
   the segment, its table and the double-fault stack exist per processor and
   `kynox_ap_entry` installs them, and the trampoline **is** copied and patched
   below 1 MiB at boot (`installApTrampoline` → `smp.prepareTrampoline`), so
   `startAps()` sends INIT/SIPI instead of refusing. What has never happened is
   an AP answering one: no boot of this tree has run anywhere, the AP would only
   install its segment and wait, and there are no per-CPU run queues. Do not
   describe Kynox as SMP, and do not read the boot log as evidence of a second
   CPU: there is none.
2. **The active VirtIO Block path is KVDI** (`kernel/drivers/kvdi/block.zig`),
   used by `kernel/main.zig`, and the boot marker `virtio: split queue layout
   ok` is produced by a KVDI virtqueue probe
   (`kernel/drivers/kvdi/virtqueue_probe.zig`, ADR-0002 steps 1–2).
   `kernel/arch/x86_64/virtio_blk.zig` is a legacy stub that unconditionally
   returns `NotImplemented` and is referenced only by the test root; it is not
   the active driver (removal decided in ADR-0003). The duplicate queue code in
   `kernel/arch/x86_64/virtio.zig` no longer has a boot-path caller; its
   deletion is ADR-0002 step 3.
3. **The I/O APIC is programmed, but it does not deliver.**
   `discoverAcpi` in `kernel/main.zig` reads the MADT through the RSDP before
   the kernel page tables replace the firmware identity map, validates the
   local APIC address and installs it with `apic.setBase`; an unusable table
   leaves the documented default `0xFEE00000` in place and logs why.
   `installIoApic` then maps the first usable controller, masks every entry and
   programs IRQ0 (PIT) and IRQ1 (keyboard) with the effective GSI, polarity and
   trigger from `acpi.isaRoute`, **masked**. Delivery stays on the 8259; the
   build option `-Dioapic-delivery=true` switches it, masks both 8259s first,
   and has never been booted. So: discovery and programming are host-tested,
   routing is unproven, and no interrupt has been observed through the I/O
   APIC (audit A-02/A-03).
4. **VirtIO Block uses synchronous polling.** No interrupt/MSI-X completion,
   no multi-queue, no asynchronous I/O.
5. **Persistence has bounded evidence.** KNV commit/recover code and a two-boot
   raw block probe exist; neither is a journaled, power-loss-safe filesystem,
   and the probe has not been executed in this snapshot.
6. **KFSX is not a complete VFS.** It routes RamFS volumes; multiple mature
   on-disk backends are not supported.
7. **ELF/KEX is not Linux compatibility.** KEX wraps an ELF64 payload for
   Kynox; Linux ABI compatibility is 0%.
8. **Windows compatibility is 0%.** No PE32+/Win64/NT/Win32 environment exists.
9. **The system version is centralized but the release gate is not met.**
   `VERSION` is the only source (`0.1.0-alpha.1`), `version.zig` embeds it, the
   manifest mirrors it and tests fail on divergence; the public identity is
   derived (`Kynox One 0.1.0-alpha.1`). That closes audit A-01, it does not make
   the tree releasable.
10. **The ABI has one revision now, and it is still unstable.** Revision 1 is
    declared in `shared/syscall_abi.zig`, aliased by the kernel and the SDK and
    checked by `abi-conformance-tests`, but the door has never run in a VM and
    a future revision may still change semantics. Audit A-04 is closed only for
    the *inconsistency*, not for stability.
11. **No CI and no recorded QEMU result.** Every runtime statement about the
    built image is unverified.
12. **The `check` target excludes the interactive QEMU test.** It runs unit,
    boot and storage steps; `zig build qemu-interactive-test` is separate.
13. **Seven files remain unreachable** from any build target or script. The
    audit (A-13) listed eight; `kernel/fs/test_ramfs_runner.zig` was deleted on
    2026-11-01 (it did not compile). The other three dead files of the same
    finding — `arch/x86_64/elf_compat.zig`, `fs/dir_entry.zig` and the unused
    `paging.window_pages` — are gone as well, and `virtio_net.zig` was added to
    the architecture test root, so its ten helper tests run now. What remains:
    `tests/f9/verify-integration.sh`, `tests/integration/log-assertions-test.sh`,
    `tests/integration/f4_physblk_knv_integration.zig`,
    `tests/user_apps/minimal_test.zig`, `tests/user_apps/test_fs.zig`,
    `tools/benchmarks/syscall_bench.zig` and `tools/scripts/recovery-mode.sh`.
    The benchmark is still not built, so no syscall benchmark can be run today.
    A different file, `tests/wait_lifecycle_regression.zig`, was reachable by no
    target either and was not in this list; it was deleted on 2026-11-01 because
    one of its five assertions ("no lost-wakeup mechanism because wait.zig is
    absent") had become false.
14. Only **two** native applications are built into the image
    (`user/hello.zig`, `user/client.zig`); the files under `tests/user_apps/`
    are not part of the build.

## Next priorities

Kernel work is now ordered by
[roadmap/KERNEL_COMPLETION_ROADMAP.md](roadmap/KERNEL_COMPLETION_ROADMAP.md)
(stages K0–K13, dependency order). Where the list below and the roadmap disagree
on *ordering*, the roadmap wins; the list remains a statement of what matters.

Taken from the audit plan (see the audit for evidence and scope):

1. Record the exact toolchain and QEMU/OVMF prerequisites in `docs/BUILD.md`
   (done) and make the build claim machine-verifiable (**CI still missing**).
2. ~~Unify the project version and expose the ABI revision from the kernel~~ —
   done: `version.zig`, `shared/syscall_abi.zig`, `version-tests` and
   `abi-conformance-tests`.
3. Execute and record `qemu-test`, `qemu-storage-test` and
   `qemu-interactive-test` on a QEMU-capable machine; fix what they reveal.
   The procedure and the failed attempt are in `docs/validation/qemu.md`;
   **no run has succeeded**.
4. ~~Wire ACPI/MADT discovery into LAPIC/IOAPIC initialization~~ — done for the
   LAPIC base, the IOAPIC list, the overrides and the redirection entries
   (masked); **delivery through the I/O APIC remains unproven and the
   `ioapic-delivery` option has never been exercised**.
5. ~~Decide the fate of the legacy `virtio_blk.zig` stub and of the parallel
   `arch/x86_64/virtio.zig` queue code~~ — decided in ADR-0002 and ADR-0003
   (`docs/decisions/`). ADR-0002 steps 1–2 are executed; step 3 (deletion of
   the duplicate queue and of `virtio_net.zig`, which depends on it) and
   ADR-0003's deletion are pending.
6. Extract boot-time probes from `kernel/main.zig` into a diagnostics module
   (ADR-0001: accepted, deferred until a boot can be compared before/after;
   ADR-0002 step 2 already repointed the virtqueue probe to KVDI).
7. Complete SMP scheduler integration, then VMM regions/TLB shootdown. The
   state lock and the generic blocking primitive are in place (see
   [`audits/2026-11-01-scheduler-lock.md`](audits/2026-11-01-scheduler-lock.md));
   the per-CPU segment is installed by the entry of an AP and the idle task
   exists ([`audits/2026-11-01-idle-task-and-per-cpu-tss.md`](audits/2026-11-01-idle-task-and-per-cpu-tss.md))
   and the trampoline is published below 1 MiB
   ([`audits/2026-11-01-ap-trampoline.md`](audits/2026-11-01-ap-trampoline.md)),
   so what remains before an AP can work is the scheduler side: per-CPU run
   queues, IPIs and a task that an AP may take.
8. Strengthen native KEX/ELF ABI, linker and SDK before any compatibility
   personality.
9. Define Linux compatibility as an isolated personality starting from a small
   static ELF64 matrix; Windows as a separate PE32+/Win64 personality.
10. Expand VFS and durable storage (journal/atomic commit) with recovery tests.
11. **`preempt_disable` / `preempt_enable` exist** (`kernel/task/scheduler.zig`)
    with an interruption-nesting counter, and the scheduler is now part of a
    test root (`kernel/task_root.zig`, artifact `scheduler-tests`, 12 tests).
    The two functions themselves have no test: they touch the flags of the
    processor, which the host cannot execute.
12. **Reports from other working copies are not evidence.** Earlier revisions of
    this section listed "audit K3.12.2/3.12.4/3.12.5" branches and a table of
    `qemu-test` and `qemu-interactive-test` passes. Those branches and the
    commits they name (`39335ae`, `5d5a9ac`, `dfa0f8b`) do not exist in this
    repository's history (it has a single commit), no serial log, screenshot or
    artifact accompanies any of them, and they claim a QEMU pass in an
    environment that the executed record above says has no QEMU and no OVMF.
    The same applies to [`AUDIT_K3.12.5_REPORT.md`](../AUDIT_K3.12.5_REPORT.md),
    which is kept with a header that says so. **None of those results is
    counted.** The only executed results for this tree are `zig build`,
    `zig build test` (52/52 steps, 806/806 tests, 2026-11-01) and
    `docs-check`; the three QEMU targets are **not executed**.
13. **The architecture test artifact used to be broken, and the inventory said
    otherwise.** Until 2026-11-01 `arch-tests` did not compile (an unnamed
    inline-assembly operand and an out-of-module import), so the paging, ACPI,
    SMP, PCI and timer tests were absent from a suite that reported 716 tests.
    The previous revision of this file described the failure as "infrastructure,
    not a functional failure"; that was wrong on both counts — it removed real
    tests from the run, and one of the two causes was an inverted dependency in
    the kernel code itself. Both are fixed and the count is now measured.
14. **The defects those pasted reports named are now partly closed, and the
    rest are open.** Closed: the per-CPU `ready_queue` is used (`enqueueReady`
    on preemption and on wake), `wakeTask` enqueues, `prepareNext` no longer
    resurrects a blocked task, and `registerCpu` no longer counts a CPU twice.
    Two more were found and closed by the new host tests of the policy: the
    tick switched tasks whatever the quantum, and the quantum was never
    refilled (`audits/2026-11-01-scheduler-tests.md`). Since then the scheduler
    has a state lock with per-CPU ownership
    (`audits/2026-11-01-scheduler-lock.md`), and the segment and the idle task
    of `audits/2026-11-01-idle-task-and-per-cpu-tss.md` closed defect 2 and the
    last resort of the queue. Still open: `cpuId()` still returns the BSP id
    in the interrupt path, `State` has no `failed` member, the trampoline is
    never published below 1 MiB, no AP schedules, and
    `metrics.zig`/`clock.zig`/`irq.zig`/`ipi.zig` do not exist.

## Updating this status

1. Update `PROJECT_STATUS.json` (schema v2) and this file in the same change as
   the code/documentation that changes reality.
2. Keep subsystem `id` values stable; never renumber or repurpose syscall
   numbers, handoff fields or status values.
3. Raise a percentage only when scoped behavior is integrated **and** supported
   by executed evidence. Test code, new files and new TODOs are not evidence.
4. Record the exact command, environment and result under `validation`; use
   `not_executed` when a test was not run.
5. Keep `README.md`, `CHANGELOG.md` and the release notes consistent with this
   file.
