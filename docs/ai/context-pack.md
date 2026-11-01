# Context pack — the state of the tree

Everything below is measured on the tree of **2026-11-01**, with Zig **0.17.0**.
Every number has a command behind it (see [`README.md`](README.md) §4). Nothing
here is a runtime claim: this environment has **no QEMU and no OVMF**, so every
statement about a running system is `not_executed`.

If a number here disagrees with [`../PROJECT_STATUS.md`](../PROJECT_STATUS.md),
that file wins and this one is stale — regenerate it as part of the change.

## 1. Identity

| Item | Value |
|---|---|
| Product | Kynox One **0.1.0-alpha.1** (no tag exists) |
| Version source | `VERSION`, mirrored by `version.zig`, guarded by `version-tests` |
| Toolchain | Zig 0.17.0 (exact; the declared minimum) |
| Licence | GPL-3.0-only |
| Target | x86-64, UEFI boot, freestanding kernel |

## 2. Commands and their results

| Command | Result on 2026-11-01 |
|---|---|
| `zig build` | success — `kynox-boot.efi`, `kynox-kernel`, `kynox.img` (128 MiB, FAT16 ESP, 32 731 clusters) |
| `zig build test --summary all` | success — **52/52 steps, 806/806 tests**, 24 artifacts |
| `zig build docs-check` | success — every relative link resolves |
| `gen-doc-index.py --check` | success — every document classified |
| `zig build qemu-test` / `qemu-storage-test` / `qemu-interactive-test` | **not executed** (no QEMU, no OVMF) |

Per artifact: kvdi 173 · fs-loader 154 · arch 146 · shared 64 · task 63 · kernel
22 · user-composition 22 · security 22 · docs-conformance 24 · damage 15 ·
version 13 · keyboard-motion 13 · kpk 9 · compositor 9 · ipc 9 · sdk 8 ·
abi-conformance 7 · kex 7 · display 7 · raster 5 · keyboard 4 · block-api 4 ·
ai 3 · boot-markers-conformance 3.

## 3. The matrix, and what each line means

Percentages are **subsystem engineering maturity**, not the share of a finished
operating system.

| Area | % | In one line |
|---|---:|---|
| UEFI bootloader and handoff | 70 | core path implemented, firmware coverage thin |
| Kernel CPU, exceptions, interrupts | 66 | registry of interrupt lines, one tick source, per-CPU segment and double-fault stack, no hardware coverage |
| Physical memory, heap, DMA | 60 | allocators and DMA path exist |
| Virtual memory, address spaces | 50 | unmap returns the frames it owns; spaces are destroyed and reused with a generation |
| ACPI, PCI, APIC | 50 | MADT drives the LAPIC; IOAPIC entries are **masked**, delivery is still the 8259 |
| SMP | 30 | CPU table exists, **no AP has ever run** |
| Scheduler and task switching | 74 | EEVDF policy in a pure module, a state lock with per-CPU ownership, a generic blocking primitive, a wait queue and a mutex, and an idle task that is chosen only when nothing else can run — all tested; **no AP has ever run**, the idle task has never halted here, the mutex has no user |
| User mode and syscalls | 55–60 | ring 3 and ABI revision 1, contract-checked, never ran in a VM |
| IPC and capabilities | 60 | channels and a real capability lifecycle |
| ELF64 and KEX | 55–60 | native loading; no dynamic linking |
| Native SDK | 40 | initial contracts and samples |
| RamFS, KFSX, KNV | 35–60 | in-memory FS, mount namespace, volume codec |
| VirtIO Block / KVDI | 65 | real synchronous block I/O |
| Networking | 10 | types and an explicit refusal |
| Graphics and compositor | 60 | raster, windows, composition |
| KGA / KGL / KVK | 0 | architecture only |
| Input | 40 | keyboard and pointer |
| Desktop | 35 | managed windows, boot scene |
| Linux compatibility | 0 | planned |
| Windows compatibility | 0 | planned |
| Security hardening | 45 | capabilities and W^X |
| Tests and validation | 65 | 24 host artifacts; no CI, no QEMU record |
| Performance | 40 | counters and TSC timing; benchmarks not in the graph |
| Build tooling | 60 | Zig graph, image generator, zero external dependencies |

## 4. What was actually built (the parts an agent will touch)

| Area | Files | State |
|---|---|---|
| Scheduling policy | `kernel/task/policy.zig` | pure functions, 13 tests, no globals |
| Scheduler | `kernel/task/scheduler.zig` | EEVDF over 32 slots, quantum enforced and refilled, 18 tests, state lock taken by every entry point |
| State lock | `kernel/task/lock.zig` | owner per CPU, depth, contentions, re-entries; 6 tests, one with four threads |
| Wait queue | `kernel/task/wait.zig` | FIFO, deadlines, remembered wake, 11 tests; first caller is the channel |
| Mutex | `kernel/task/mutex.zig` | owner, recursion ≤255, direct handoff, 10 tests; **no caller** |
| Channels | `kernel/ipc/channel.zig` | bounded queues, blocking receive with deadline, 8 tests |
| Interrupts | `kernel/arch/x86_64/interrupt_registry.zig` | one owner per line, per-line counters, 5 tests |
| Memory | `kernel/arch/x86_64/paging.zig` | ownership bit, frame release on unmap, slot reuse with generation |
| Capabilities | `kernel/security/capability.zig` | destroy, destroySubject, releaseProcess |

## 5. The open defects that matter

| # | Defect | Consequence |
|---|---|---|
| 1 | The scheduler lock is never contended in the kernel: **no AP has ever run** | the lock is host-tested only; the SMP path is unproven |
| 2 | Single global TSS with one `rsp0` | ring 3 on an AP is impossible |
| 8 | FPU/SSE state is not saved on the context switch | a switch between threads that use SSE corrupts state |
| 9 | `kernel/main.zig` mixes bring-up, demo and self-test | the boot order is the source of the system |
| 11 | No CI, no recorded QEMU result | every runtime claim is unverified |
| 13 | The mutex has no user in the kernel; the wait queue has one (the channel) | the mutex is tested code, not live code |
| A | Seven files remain unreachable from any target | the syscall benchmark cannot run at all |

The full list, with severities and closures, is in
[`../PROJECT_STATUS.json`](../PROJECT_STATUS.json) (`open_findings`).

## 6. Invariants that a change must not break

1. **Architecture must not import the memory manager** (AGENTS.md §4.1). The
   dependency goes the other way: memory offers a hook, the kernel installs it.
2. **A frame that a space does not own is never freed.** `Flags.owned` decides;
   the release callback decides whether it can be returned at all.
3. **A blocked task is never made ready by a quantum.** Only the event, the
   timeout or an explicit wake changes its state.
4. **The wake of a handoff comes after the transfer of the ownership.** The
   mutex asserts this from inside its wake routine.
5. **The version has one source.** `VERSION`; tests fail on a second copy.
6. **A test that asserts nothing is a defect.** `true == true` is not a test, and
   an artifact that reports zero tests is not a pass.

## 7. Where the work goes next

From [`../roadmap/KERNEL_COMPLETION_ROADMAP.md`](../roadmap/KERNEL_COMPLETION_ROADMAP.md),
in order: the trampoline below 1 MiB with a per-CPU TSS and the idle task, so that
an AP can run and contend the state lock (K2/K3), a user of the mutex, the
process/thread split with `join` and reap (K4), then the syscall and IPC surface
(K6). The unverified QEMU suites (K0 evidence) are the shortest path to
turning any of it from "host-tested" into "works".
