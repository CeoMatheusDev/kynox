# Kernel and core systems completion roadmap

- Status: **planning document**. No stage below is started. Nothing in this
  document is an implementation claim. Work done after it was written is
  recorded, with its evidence level, in
  [`../audits/2026-11-01-kernel-core-fixes.md`](../audits/2026-11-01-kernel-core-fixes.md);
  this document keeps the initial state that the audit measured, so that the
  plan is not rewritten to match what happened.
- Date: 2026-10-31. Identity: **Kynox One 0.1.0-alpha.1** (this roadmap does not
  change the version, and no stage completion implies a version change).
- Basis: [`../audits/2026-10-31-kernel-core-audit.md`](../audits/2026-10-31-kernel-core-audit.md)
  (read-only audit of the tree at `343e9fb`). Every "initial state" below is the
  audit's classification, not an estimate.
- Companion architecture documents: [`kernel-internals.md`](../architecture/kernel-internals.md),
  [`memory-management.md`](../architecture/memory-management.md),
  [`execution-model.md`](../architecture/execution-model.md),
  [`device-driver-model.md`](../architecture/device-driver-model.md).
- Scope: kernel and essential systems only. Linux/Windows compatibility, the
  graphics pipeline (KGA/KGX/KGL/KVK/KGR/KWM), the compositor, applications and
  the desktop are **out of scope** and are not ordered by this document.

## 1. How to read this roadmap

### 1.1 Status ladder (unchanged, from the product roadmap)

| Level | Meaning | Evidence required |
|---|---|---|
| **P** Prototype | Code exists, may be incomplete, possibly not in the boot path | Builds; unit tests where the code is pure |
| **F** Functional | Integrated into the real path, works on the reference machine | Host tests + a recorded run |
| **E** Emulator-validated | Works under QEMU/OVMF with the suite green | Recorded serial log and marker assertions |
| **H** Hardware-validated | Works on named physical hardware | Recorded evidence per device, published matrix |

The ladder is cumulative and it is per deliverable, not per repository. A stage is
complete only at the level it declares, and no stage in this document is above
**P** today.

### 1.2 Subsystem classification (from the audit)

`NOT_STARTED` · `STUB` · `PARTIAL` · `IMPLEMENTED` · `INTEGRATED` · `VALIDATED`.
"Implemented" never means "works at runtime"; the audit's rule applies here
unchanged: a compile is not a run, and a host test is not a boot.

### 1.3 Stage numbering and ordering

Fourteen stages, one per area the initiative asks for. The set of areas is the
requested one; the **order is the dependency graph**, and it differs from the
requested order in two places, both stated in §3.

```text
K0 boot/arch
 └─▶ K1 memory ──┬─▶ K2 interrupts, time base, SMP
                 │        └─▶ K3 synchronisation, scheduler
                 │                 └─▶ K4 processes, threads
                 │                          └─▶ K5 security, capabilities
                 │                                   └─▶ K6 syscalls, IPC
                 │                                            └─▶ K7 drivers, device model
                 │                                                     ├─▶ K8 DMA, IOMMU readiness
                 │                                                     │      └─▶ K9 block, storage
                 │                                                     │              └─▶ K10 VFS, filesystems
                 │                                                     └─▶ K11 input, console, terminal
                 │                                                     └─▶ K12 timekeeping, power
                 └─────────────────────────────▶ K13 diagnostics, hardening (continuous)
```

Dashed edges that matter and are easy to get wrong:

- **K1 → K2** is partly mutual: the VMM needs remote TLB invalidation, which is an
  IPI. The order is fixed by putting the *use* of the shootdown in K2 and treating
  K1's invariant M4 as satisfied only at the end of K2.
- **K5 before K6**, not after: a syscall that creates an IPC endpoint returns a
  handle, and a handle is a capability. Building dispatch first would mean
  rewriting its return contract.
- **K13 is continuous**: the minimal crash record lands inside K0, counters land
  in each stage, and only the full diagnostics work (tracepoints, crash store,
  invariant checkers) is a stage of its own.

## 2. Quality standards binding every stage

These are acceptance criteria, not aspirations. A change that violates one is
rejected regardless of what it enables.

1. **Small, explicit internal APIs.** A module's public surface is enumerated in
   its header; above ~12 public functions is a review signal.
2. **Defined ownership.** Every allocation has a named owner and a named
   destructor; borrowed pointers say "borrow" in the name.
3. **Mechanism and policy separated.** `arch` programs hardware; policy modules
   decide when. Policy is pure where possible so it is host-testable.
4. **Explicit errors.** No function returns success after doing nothing (the
   audit's `net_transmit` defect is the canonical violation). Failure to init a
   non-critical device degrades; it does not halt silently and it does not lie.
5. **No dangerous implicit behaviour.** No implicit page-table switch inside an
   allocator, no implicit lock acquisition, no "if this fails, continue anyway"
   without a recorded state.
6. **Correct SMP synchronisation.** Any structure reachable from two CPUs has a
   lock or is documented as single-writer. Atomics state their ordering and the
   ordering is justified in one line.
7. **Predictable allocation.** No allocation in interrupt context; no unbounded
   allocation during a fault; allocation failure is a clean error.
8. **Hot paths optimised only after measurement**, with the number cited from
   `kernel/diag` counters or a benchmark in `tools/benchmarks/`.
9. **Diagnostics available.** Each stage adds the counters needed to tell whether
   it works, and they are readable from the serial log.
10. **Deterministic tests.** No test depends on wall-clock timing beyond a bounded
    wait; host tests do not touch hardware.
11. **No needless external dependencies.** The kernel remains freestanding Zig
    0.17.0 with no runtime library.
12. **No silent contract change.** ABI, on-disk format and binary format changes
    require the compatibility assessment the project rules demand.

## 3. Where this order differs from the request, and why

| Requested position | Roadmap position | Reason |
|---|---|---|
| syscalls+IPC before security+capabilities | **K5 security → K6 syscalls/IPC** | the syscall ABI returns handles; handles are capabilities; the return contract cannot be designed before the object exists |
| timekeeping+power before input/console | **K11 input/console → K12 timekeeping/power** | the monotonic tick (needed by everything) is already delivered in K2; what remains in K12 is the wall clock and ACPI power, both of which are observed through the console built in K11 |
| diagnostics last | **K13 last, with a K0 seed** | a crash record is needed to debug every earlier stage, so the seed ships in K0; the full diagnostic surface is last because it instruments everything else |

No stage is reordered for convenience; each dependency is a symbol the later stage
imports from the earlier one.

## 4. Genuine parallelism

Work that can proceed simultaneously without creating a contract debt. Each pair
lists the interface that must be agreed in advance.

| Pair | Shared interface agreed first |
|---|---|
| K1 memory ∥ K2 interrupts/APIC | the IPI vector number and the kernel-stack allocation entry point |
| K5 capability core ∥ K6 IPC data path | `Handle` representation (index + generation) and the endpoint capability tag |
| K7 device model ∥ K12 RTC/HPET/power | the resource type for a fixed platform device and the ACPI table accessor |
| K9 block/storage ∥ K10 VFS on RamFS | the block-device interface (`read`/`write`/`flush`/`capacity`) |
| K10 VFS ∥ K11 console/terminal | the file-object interface used by terminal read/write |
| K13 hardening ∥ everything after K1 | the counter registration call and the crash-record write |

Everything else is sequential. The table exists so that a second engineer does not
start K5 before K4 lands, which would produce two half-process objects.

## 5. Validation layers

Every stage is evaluated against this ladder, in order. A stage that has not
climbed a layer does not claim it.

| Layer | What it proves | Where |
|---|---|---|
| 1. Compile | the tree builds for x86_64-freestanding and for the host test target | `zig build`, `zig build test` |
| 2. Unit | pure logic: parsers, policy, bitmap allocators, codecs | host test roots |
| 3. Integration | two or more modules working through their real interface | QEMU boot with assertions |
| 4. Invariants | the memory/lock/scheduler invariants hold after each operation | debug-build assertions + counters |
| 5. Concurrency | the same assertions with 2+ CPUs and interrupts enabled | QEMU `-smp 4` |
| 6. QEMU boot | the system reaches a defined steady state and shuts down cleanly | recorded serial log |
| 7. Virtual devices | drivers complete real requests against emulated hardware | QEMU with virtio devices |
| 8. Stress | 10⁴–10⁶ operations without leak, corruption or timeout | QEMU stress run |
| 9. Real hardware | the same, on a named machine, with a published matrix | physical machine |

**Current position of the whole project: layer 2.** Layers 3–9 are blocked by the
absence of an OVMF firmware image in the build environment (§10).

## 6. The stages

---

### K0 — Boot and architecture foundation

**Objective.** Turn the kernel from a boot-time script into a system with an
explicit initialisation contract, a per-CPU-ready architecture layer, and a
diagnosable failure path. Nothing in this stage is a feature; all of it is
structure that every later stage depends on.

**Initial state (audit §A).**
Bootloader `PARTIAL` (loads and jumps, no memory map sanitisation beyond the
present checks, no initrd, no config). Handoff `IMPLEMENTED`/host-validated.
GDT/TSS `PARTIAL` — **one global TSS**, one `rsp0`, one IST stack, so ring 3 on an
AP is structurally impossible. IDT `PARTIAL` — 32 exception vectors, 16 IRQ
vectors, fixed assignment. Exceptions `PARTIAL` — no demand paging, no COW, no
user-fault termination path. Kernel entry `PARTIAL` — a 4 974-line `main.zig`
whose top-level function list *is* the boot order. Panic `STUB` — halt with a
message; no record survives.

**Files.** `boot/uefi/main.zig`, `boot/uefi/knb/*`, `shared/handoff.zig`,
`kernel/main.zig`, `kernel/arch/x86_64/{entry,segment,interrupt}.{s,zig}`,
`kernel/arch/x86_64/cpu.zig`, `kernel/root.zig`, `build.zig`.

**Depends on.** Nothing.

**Required work.**
1. Introduce `kernel/init/` with a **phase table** (`early`, `cpu`, `memory`,
   `devices`, `services`, `user`, `self_test`), each step carrying `name`, `run`,
   `required`. `main.zig` becomes: validate handoff → `init.run()` → enter idle.
2. Move the demonstration (reports, self-tests, framebuffer benchmark, KPK
   round-trip) into a `self_test` phase that a build option can disable; the CI
   boot keeps it, the production boot does not.
3. Replace the global TSS with **one TSS per CPU**, allocated with the per-CPU
   area; `rsp0` is updated on privilege transitions of that CPU only. IST stacks
   become per-CPU as well. *(2026-11-01: done in `segment.zig` — eight segments,
   each with its own `rsp0`, `ist1` and descriptor table, installed by
   `installForCpu`; see `docs/audits/2026-11-01-idle-task-and-per-cpu-tss.md`.
   The per-CPU area of item 4 is still missing.)*
4. Define the per-CPU area now (this is the K2 prerequisite): a fixed struct
   containing `self`, `apic_id`, `current_thread`, `kernel_stack`, `tss`, `idle`,
   `preempt_count`, reached through the GS base *or* through a single accessor
   that hides the mechanism. The accessor is the contract; the GS base can land
   in K2.
5. Minimal **crash record**: a fixed 512-byte structure with a magic, reason,
   vector, `rip`, `cr2`, the last init phase reached and the last 16 tracepoints.
   Written by the panic path and by the double-fault/`#MC` stubs. On the next boot
   the kernel reads and reports it if storage is writable.
6. Actually resolve the **double tick source**: at the end of K0 only one component
   may call `scheduler.tick()`. (The full timer rework is K2; K0 makes the current
   behaviour single-sourced so that K3 can build on it.)
7. Delete dead files identified by the audit: `arch/x86_64/elf_compat.zig`,
   `fs/dir_entry.zig`, `fs/test_ramfs_runner.zig`, the unused
   `paging.window_pages`.
8. Add a **boot marker contract**: a fixed set of `[kynox:phase] name=result`
   lines, machine-checkable by `tests/integration/boot-qemu.sh`.

**Completion criteria.**
- `main.zig` under 200 lines and contains no phase-specific logic.
- The phase transcript prints once per boot and lists every step with its result.
- A required-step failure prints the phase, the step, the error and the crash
  record; an optional-step failure prints `degraded` and boot continues.
- Two CPUs, if started, have distinct TSS/`rsp0`; code that assumes one TSS is gone.
- Dead files deleted, tests updated, no test deleted.

**Tests.**
*Unit* (host): handoff validation, phase-table ordering (a table with a
dependency violation is rejected at build time), crash-record encode/decode.
*Integration* (QEMU): phase transcript matches the expected ordered list; an
injected failure of an optional step yields `degraded` and a complete boot.
*Stress*: not applicable at this stage.

**QEMU validation.** Boot to the `self_test` phase and to a clean halt; the serial
log contains the full transcript. Blocked until an OVMF image is available.

**Hardware validation.** The phase transcript and the crash record on a named
machine, after the emulator tier passes.

**Risks.** Moving code out of `main.zig` can change initialisation order silently,
which is exactly the class of bug this stage exists to prevent — mitigate by
recording the pre-change boot marker sequence and asserting the new one matches
except where the change is deliberate. Per-CPU TSS changes the fault path; a
mistake there turns a `#GP` into a triple fault with no output.

**Promotion.** P → F when the phase table drives the real boot and the transcript
is recorded. F → E when the QEMU suite asserts the transcript. E → H on the
reference machine.

**Parallel.** K1 and K2 can start once the phase table (step 1) and the per-CPU
accessor (step 4) are agreed; both import them.

---

### K1 — Memory management

**Objective.** Make memory an object with a lifetime: frames are reclaimed,
address spaces are destroyed, regions exist, and a page fault becomes a decision
instead of a halt. This is the stage that unblocks everything else, because today
nothing can rely on "an unmapped frame is free".

**Initial state (audit §B).** PMM `IMPLEMENTED`/host-validated below 4 GiB.
VMM `PARTIAL` — maps kernel, a 24 KiB user window and a 64 MiB DMA window;
**never unmaps a frame** outside the DMA path and the loader failure path.
Address spaces `PARTIAL` — 8 static slots, no destroy, a private level-2 copy that
shadows later kernel mappings. Heap `IMPLEMENTED`, no lock, no accounting.
Regions, demand paging, COW, file-backed pages, page cache, IOMMU:
`NOT_STARTED`.

**Files.** `kernel/memory/{physical,heap,dma}.zig`,
`kernel/arch/x86_64/{paging,frame}.zig`, `shared/memmap.zig`,
`kernel/main.zig` (call sites), new `kernel/memory/{vmm,region}.zig`.

**Depends on.** K0.

**Required work.**
1. **Unmap frees.** `unmap` invalidates the mapping and returns the frame to the
   PMM when the mapping owned it; `unmapRange` is the width-first version.
2. **Address space as an object** with `create`/`destroy` and reference counting:
   destroy walks regions, unmaps, frees, frees page-table pages, returns the slot.
3. **Shared kernel mappings.** Replace the private level-2 copy with one shared
   kernel PDPT plus a per-space window PDPT, so later kernel mappings are visible
   everywhere by construction.
4. **Regions** (`anonymous`, `file`, `device`, `stack`, `guard`, `shared`) with
   `map`, `unmap`, `protect`, and the invariant that the list is consistent after
   any single failure.
5. **Page fault as policy**: region lookup → lazy allocation / page-in / permission
   decision → user fault terminates only the faulting task with a recorded reason.
6. **Frame availability above 4 GiB**: one bitmap per GiB region built from the EFI
   memory map instead of rejecting the range. No allocator algorithm change.
7. **Heap**: spinlock, `allocations`/`frees`/`high_water`/`failed` counters, and a
   debug-only guard + fill pattern.
8. **Accounting**: per-space resident pages, global free/used/pinned, faults by
   reason. Exposed through `kernel/diag`.
9. Make the DMA release path an instance of the general unmap path instead of a
   special case.

**Completion criteria.**
- Creating and destroying an address space returns frame accounting to the exact
  pre-creation value, repeatedly, for 10⁴ cycles.
- No mapping outlives its region; no region outlives its address space.
- A user fault on an unmapped address terminates that task only, and the record
  names the address and the region state.
- A kernel-mode fault produces a crash record, not a triple fault.
- Kernel heap byte accounting balances.
- `paging.window_pages` is gone and the window size has one source of truth.

**Tests.**
*Unit* (host): region list operations under injected failures; bitmap accounting
with double free; page-table walk against a fake CR3; fault-policy function
(pure, table-driven).
*Integration* (QEMU): map/unmap/protect syscalls from ring 3 with accounting read
back; a deliberate fault terminates only the faulting thread.
*Stress*: 10 000 create/fault/exit cycles with counters balanced; a fragmentation
run that allocates and frees in a random order and asserts frame count.

**QEMU validation.** The stress run plus a post-run accounting dump; no leak in the
serial log. Blocked by §10.

**Hardware validation.** Memory map handling on a machine with memory above 4 GiB
and a non-trivial EFI map (the emulator's map is too regular to prove this).

**Risks.** Unmapping frames changes the failure mode of *every* existing caller;
the loader and the process window are the sensitive ones. The page-table change
(shared kernel PDPT) can hide a mapping bug until a second address space is created
— the test must create two.

**Promotion.** P → F when unmap frees and destroy is symmetric in the real path.
F → E when the create/destroy stress run is recorded. E → H when the memory-map
handling is verified on hardware.

**Parallel.** With K2 (see §4). The IPI vector and the kernel-stack allocation
must be agreed first.

---

### K2 — Interrupts, time base and SMP

**Objective.** One interrupt registration path, one schedulable time base, honest
per-CPU state, and APs that actually start. Today the vector table is hard-coded,
the PIT and the LAPIC timer both drive scheduling, and `smp.startAps()` has no
caller.

**Initial state (audit §A.4–A.10).** IDT `PARTIAL` (32 exceptions, 16 IRQs, fixed
vectors 32/33, 34–47 acknowledged and ignored). Exceptions `PARTIAL`. LAPIC
`PARTIAL` — initialised, timer programmed, EOI handled. IOAPIC `PARTIAL` — MADT
entries programmed, **delivery never observed**; `-Dioapic-delivery=true` has
never been booted. ACPI `IMPLEMENTED`/host, AML `NOT_STARTED`. SMP `PARTIAL` —
`publishTrampoline` has no caller, so no AP is ever started; per-CPU `STUB` —
`Cpu.current_task` is never written. TLB shootdown: **absent**.

**Files.** `kernel/arch/x86_64/{interrupt,apic,ioapic,timer,smp,acpi}.zig`,
`kernel/arch/x86_64/{interrupt,ap_trampoline,task}.s`, `kernel/arch/x86_64/cpu.zig`,
new `kernel/arch/x86_64/ipi.zig` and `kernel/devices/irq.zig`.

**Depends on.** K0 (per-CPU area, phase table); K1 for the shootdown *target*
(unmap paths).

**Required work.**
1. **Break the `apic ↔ timer` import cycle.** The timer owns the tick; the APIC
   exposes the timer register block. One direction only, asserted by a test.
2. **One tick source**: LAPIC timer in periodic or TSC-deadline mode; the PIT is a
   fallback and a calibration reference only. Calibrate against the PIT or the
   HPET once at boot and record the value.
3. **Interrupt registration API** (`register`/`acknowledge`/`unregister`) with
   abstract lines: a legacy IOAPIC line and an MSI vector both resolve to a
   `Line`. Slot table with bounds checks.
4. **Per-CPU state becomes real**: `percpu.current()` is the only accessor;
   `current_thread`, `idle`, `preempt_count` live in it; nothing indexes by
   `apic.readApicId()` at a use site.
5. **AP startup** with a real INIT-SIPI-SIPI sequence: trampoline published,
   AP enters long mode on a per-CPU stack, initialises its GDT/TSS/APIC, then
   signals ready. `smp.startAps()` has a caller. APs that fail to start are
   counted, not ignored. *(2026-11-01: the trampoline is published below 1 MiB
   and patched per AP, `smp.startAps()` has a caller, and the AP installs its
   segment before it waits — but no AP has answered, the per-CPU block does not
   exist, and the AP initialses no APIC of its own yet. See
   `docs/audits/2026-11-01-ap-trampoline.md`.)*
6. **IPI infrastructure**: TLB shootdown (address + generation, with an ack
   counter), reschedule IPI, and a halt IPI. Shootdown is wired into `unmap`, which
   is what finally satisfies memory invariant M4.
7. **Unhandled interrupts are counted and named**, not silently acknowledged. A
   spurious vector has its own counter.
8. **MSI programming** for devices that advertise the capability (needed by K7);
   the parsed-but-unused capability from the audit is the starting point.

**Completion criteria.**
- Exactly one component calls `scheduler.tick()`; the call site is listed in the
  module header.
- An interrupt can be registered by a module that does not know its vector; an
  unregistered line increments a counter and prints once.
- Two APs start, each with its own TSS, stack, APIC and per-CPU block, verified by
  a report line per AP.
- A TLB shootdown reaches every CPU that ran a given address space; the ack count
  equals the target count or the operation fails loudly.
- No test asserts "one CPU" by accident; the guest is booted with `-smp 2` and
  `-smp 4` in the suite.

**Tests.**
*Unit* (host): APIC/IOAPIC register encodings; vector allocation and slot
recycling; tick conversion arithmetic.
*Integration* (QEMU): an AP reports its own CPU id and runs a bound loop;
shootdown test that maps, unmaps and re-reads the old address on another CPU.
*Stress*: 10⁶ timer ticks with no drift beyond the documented bound; 10⁵
shootdowns with the ack count always exact.

**QEMU validation.** `-smp 4` boot with per-AP report lines; IOAPIC delivery
observed (the feature flag that has never been booted becomes the default);
shutdown via K12.

**Hardware validation.** AP startup on a machine whose firmware does not map the
APIC base at the default address, and one with more than 4 CPUs. This is the
highest-risk hardware item in the roadmap and is not claimed before it runs.

**Risks.** AP startup is the classic triple-fault generator: the trampoline's
page tables must be the shared kernel PDPT, and the AP stack must be mapped before
the AP uses it. TLB shootdown has a lost-wakeup-style failure mode (an ack lost
because the IPI arrived while interrupts were disabled) — the design must use a
generation counter, not a handshake between two sequence numbers.

**Promotion.** P → F when APs start and the shootdown is used by unmap. F → E when
the `-smp 4` suite passes with recorded logs. E → H on a named multi-core machine.

**Parallel.** K1 (see §4) and K12's RTC/HPET work.

---

### K3 — Synchronisation and scheduler

**Objective.** A scheduler with a testable policy, a lock, an idle task and real
timeouts; and the synchronisation primitives the rest of the kernel needs (wait
queues, mutex, rwlock).

**Initial state (audit §C.1–C.7).** Scheduler `PARTIAL` with **0 tests**, 32 static
slots, a ready ring, no lock, `current[]`/queues/statistics written from IRQ and
thread context. Context switch `PARTIAL` — **FPU/SSE state is not saved**.
Preemption by PIT tick. Synchronisation: spinlock and a counting semaphore only.
Timers `PARTIAL` — no sleep queue, no wall clock. Atomics used with inconsistent
ordering.

**Files.** `kernel/task/{scheduler,context}.zig` (moved to `kernel/exec/` by this
stage), `kernel/arch/x86_64/task.s`, `kernel/arch/x86_64/spinlock.zig`, new
`kernel/exec/{policy,wait,mutex,rwlock}.zig`, `kernel/arch/x86_64/cpu.zig`.

**Depends on.** K2 (one tick, per-CPU), K1 (kernel stacks from the frame allocator).

**Required work.**
1. **Move `kernel/task/` to `kernel/exec/`** as part of this stage, so the new
   files land in their target home instead of being moved twice.
2. **Split policy from mechanism**: `policy.zig` is pure functions over queue state
   (`pickNext`, `shouldPreempt`, `chargeBudget`) with no globals; `scheduler.zig`
   owns the queues and the lock.
3. **Lock the scheduler.** One lock per run queue plus a documented ordering
   against the wait-queue lock. Preemption is disabled while holding it.
4. **Idle task per CPU** at the lowest priority that `hlt`s. The kernel stops
   falling off the end of `kmain`. *(2026-11-01: the idle task exists and the
   policy chooses it only when nothing else can run — one task, not one per CPU,
   because the scheduler still has one array. See
   `docs/audits/2026-11-01-idle-task-and-per-cpu-tss.md`.)*
5. **FPU state in the context**: `xsave`/`xrstor` with a per-CPU save area; the
   test writes a distinct pattern per thread and reads it back.
6. **Wait queues** with the standard predicate loop (`while (!cond) wait`), a
   timeout on every wait, and a lost-wakeup test.
7. **Mutex** (owner, recursion count, sleepers) and **reader/writer lock**
   (writer-preferring). Both sleep, therefore both assert "not in interrupt
   context".
8. **Timer queue and sleep**: `timer.sleep(ticks)`, wakeups from the tick handler
   moving threads to ready without switching.
9. **Lock-order table** in `kernel/exec/locks.md` plus a debug-build held-level
   counter that asserts the order.
10. **Fix the task-slot leak**: `terminateCurrent` no longer strands a slot; exit
    is a state transition and the slot is released by the reaper.

**Completion criteria.**
- The scheduler has host tests for its policy and at least one QEMU integration
  test that would fail with the lock removed.
- Two threads writing a shared counter under a mutex reach the exact expected
  value on `-smp 4`.
- A thread's FPU registers survive a switch (test).
- A wait with a timeout wakes exactly once at the deadline and not before.
- No code holds a spinlock across an allocation or a copy.

**Tests.**
*Unit* (host): policy functions; queue invariants under random operations; lock
try-acquire semantics; wait-queue lost-wakeup property.
*Integration* (QEMU): counter under mutex on 2 CPUs; sleep/deadline accuracy within
one tick; priority preemption observed by an ordering trace.
*Stress*: 10 000 create/exit cycles with no slot or stack leak; 10⁶ tick/switch
cycles with counters balanced.

**QEMU validation.** The `-smp 4` counter test and the tick stress run.

**Hardware validation.** None specific beyond K2's SMP hardware run; the scheduler
is CPU-model independent.

**Risks.** Removing `haltForever` from the boot path reveals every latent "assume
this is the last thing that runs" bug. FPU saving costs cycles per switch — record
the cost, do not optimise it before the measurement.

**Promotion.** P → F when the lock, idle and policy split are in the real path.
F → E when the SMP counter test and the stress run are recorded. E → H with K2.

**Parallel.** The rwlock and wait queue can be developed while the policy work is
in review (different files, no shared state).

---

### K4 — Processes and threads

**Objective.** Two objects with real lifetimes: a thread that can exit and be
joined, and a process that owns an address space, a handle table and an exit
status.

**Initial state (audit §C.3, §D.5).** No process object at all: scheduling slots
are treated as processes, `fs` indexes by a process id bounded by
`max_processes = 8`. `terminateCurrent` never frees the slot; no join, wait, reap
or exit code. Ring 3 exists but ring 3 on an AP does not (single TSS, fixed in K0).

**Files.** new `kernel/exec/{process,thread,reaper}.zig`,
`kernel/exec/scheduler.zig` (moved in K3), `kernel/security/capability.zig`
(handle table hook), `kernel/fs/fs.zig` (process id source),
`shared/usermode.zig`.

**Depends on.** K3, K1 (address space destroy), K0 (per-CPU TSS).

**Required work.**
1. **Thread** as the schedulable object: kernel stack, saved context, FPU state,
   state, priority, affinity, owning process.
2. **Process** as the resource container: address space, handle table, limits
   (threads, handles, virtual bytes, resident pages), exit status, parent, reaping
   state.
3. **Lifecycle**: `exit` records a status and moves to `exited`; the reaper frees
   the stack and the slot; `join` returns the status. A thread never frees its own
   stack.
4. **Affinity mask** with an empty mask rejected at creation; `thread.setAffinity`
   documented as a hint until K2's balancing exists.
5. **Process limits enforced** at the allocation point, with a clean error to the
   caller, not a panic.
6. **Remove the `max_processes = 8` coupling** in `fs`: file ownership refers to a
   process handle or id from the process object, with a generation to prevent
   reuse confusion.
7. **Kernel threads** as a first-class form (no user address space) so drivers and
   deferred work use the same scheduler path.

**Completion criteria.**
- Create → run → exit → join returns the exit code and leaves the accounting at
  baseline.
- Destroying a process destroys its address space, its handles and its threads, in
  that order, verified by counters.
- 10⁴ process create/exit cycles exhaust nothing.
- A process that exceeds a limit gets an error, not a kernel crash.

**Tests.**
*Unit* (host): lifecycle state machine; limit enforcement; id/generation
allocation.
*Integration* (QEMU): two processes each spend their own address space; one exits;
the other's memory is untouched.
*Stress*: 10 000 create/exit with a leak check after each 1 000.

**QEMU validation.** The process lifecycle integration run; the accounting dump
after the run.

**Hardware validation.** Not distinct from K2's hardware run.

**Risks.** Process teardown ordering (threads before address space, handles before
address space) is where use-after-free lives; the reaper must be the only place
that frees a stack.

**Promotion.** P → F when the lifecycle runs in the real path. F → E when the
stress run is recorded.

**Parallel.** None inside the stage; the handle table is designed here and
implemented in K5.

---

### K5 — Security and capabilities

**Objective.** A handle table with a lifetime and an attachment model, so that
every resource a process can name is a capability with rights, and destroying it is
well defined.

**Initial state (audit §D.4–D.5).** Capabilities `PARTIAL`: a 16-entry table, no
`destroy`, `max_held = 8`, rights checked at some call sites. IPC channels exist
as objects but are not typed. Isolation is structural (the syscall window), not
enforced by ownership.

**Files.** `kernel/security/{capability,root}.zig`, new
`kernel/security/handle_table.zig`, `kernel/ipc/channel.zig` (attachment),
`shared/syscall_abi.zig` (handle encoding).

**Depends on.** K4.

**Required work.**
1. **Handle table per process**: index + generation, growable in fixed steps,
   destroyed with the process, `close` releases and revokes.
2. **Capability object**: kind (channel endpoint, shared memory, device, file),
   rights mask, owning process, reference count, destructor.
3. **Channel endpoints are capabilities**; creating a channel returns two handles
   with send/receive rights. This is the contract K6 needs.
4. **Rights enforcement at the syscall boundary**, not inside the object: the
   syscall resolves a handle, checks the right, then calls the object.
5. **Revocation** removes the handle from the table and invalidates the generation,
   so a stale handle is an error, never a use-after-free.
6. **Audit counters**: handles open/peak, rights denials, revocation count.

**Completion criteria.**
- A handle from a destroyed process cannot be used (generation check test).
- Closing a channel endpoint wakes the peer with a defined error.
- Rights are enforced: a receive-only handle cannot send, and the failure is a
  status code, not a crash.
- The table has no fixed 16-entry ceiling; the limit is a per-process setting.

**Tests.**
*Unit* (host): table growth, generation wraparound, revoke semantics.
*Integration* (QEMU): two processes exchange a channel handle and use it after the
creator exits, per the defined ownership rule.
*Stress*: 10⁵ handle open/close cycles with no table growth.

**QEMU validation.** The cross-process handle test.

**Hardware validation.** None distinct.

**Risks.** Generation wraparound at 2¹⁶ is plausible under stress; either widen to
32 bits or document and test the wrap. Reference counting cycles are possible
between channel objects — the design forbids ownership cycles by construction
(endpoints do not own each other, the channel owns both).

**Promotion.** P → F when the handle table replaces the 16-entry table in the real
path. F → E with the cross-process test recorded.

**Parallel.** The IPC data path (K6) can be built against the agreed `Handle`
representation; see §4.

---

### K6 — Syscalls and IPC

**Objective.** A syscall surface that is complete enough to run a real program,
safe about user memory, and honest about time; and IPC that moves more than 16
bytes and can share memory.

**Initial state (audit §D.1–D.3).** 22 syscalls (`shared/syscall_abi.zig`),
dispatch through a table, revision-checked. **No time syscall.** `copyUserPath`
validates and copies, but later code re-reads the same user buffer (TOCTOU).
IPC: `kernel/ipc/channel.zig`, 16-byte messages, blocking receive with a bound.
Shared memory `NOT_STARTED`.

**Files.** `kernel/arch/x86_64/syscall.{s,zig}`, `shared/syscall_abi.zig`,
`kernel/ipc/channel.zig`, new `kernel/ipc/shared_memory.zig`, `sdk/src/syscall.zig`.

**Depends on.** K5, K4, K3.

**Required work.**
1. **Single validation point**: `copyIn`/`copyOut`/`copyInPath` take the *whole*
   buffer once, produce a kernel-owned copy, and the handler uses only that copy.
   Path handling never re-reads user memory.
2. **Time syscall** (monotonic ticks → nanoseconds, and a wall-clock query once K12
   lands), plus `sleep` on the K3 timer queue.
3. **Message size beyond 16 bytes**: either larger messages or a scatter form
   (header + body pages), decided by what the first real client needs; the current
   fixed 16-byte payload is documented as the v1 limit and kept compatible.
4. **Shared memory objects**: create from anonymous pages, attach to a process,
   map read-only or read-write, revoke through the handle table.
5. **Blocking IPC with a timeout** and a defined error for the timeout, so a
   client cannot hang the system.
6. **Syscall table completeness check**: a compile-time assertion that every
   declared syscall number has a handler and every handler has a test.
7. **Dispatch hardening**: user-supplied pointers, lengths and handles are all
   validated before any state change; a table-driven negative test per syscall.

**Completion criteria.**
- No handler dereferences a user pointer; `grep` for direct user accesses is empty
  and the rule is documented in the header.
- The negative test suite passes: each syscall rejects a bad pointer, a bad length,
  a stale handle and an out-of-range value without changing state.
- A 1 MiB shared buffer is created, attached by two processes and read by both.
- Every syscall number has a handler and a test.

**Tests.**
*Unit* (host): argument validation table; ABI struct layout assertions.
*Integration* (QEMU): a user program that exercises every syscall and prints
results; a two-process shared-memory exchange; a timeout on a blocking receive.
*Stress*: 10⁵ syscalls with no leak; 10⁴ shared-memory attach/detach cycles.

**QEMU validation.** The syscall conformance program plus the IPC exchange,
recorded.

**Hardware validation.** None distinct.

**Risks.** ABI stability: `shared/syscall_abi.zig` is contract-checked, so every
addition is additive and the revision stays at 1 until the surface is complete;
the compatibility assessment is written before any change to an existing call.

**Promotion.** P → F when the validation point and the time syscall are in the real
path. F → E with the conformance program recorded.

**Parallel.** The IPC data path can proceed alongside K5 (see §4).

---

### K7 — Drivers and the device model

**Objective.** A device/driver/resource model so that adding a device is a
registration, not an edit to `main.zig`; and real drivers for the classes the
system needs.

**Initial state (audit §E).** PCI `IMPLEMENTED`/host (port I/O only, 36 tests).
Device model `NOT_STARTED`. Interrupt routing for drivers `NOT_STARTED` (fixed
vectors). KVDI transport `IMPLEMENTED`/`INTEGRATED` (173 tests, containment).
VirtIO-blk `IMPLEMENTED` (synchronous). VirtIO-net `STUB` (`net_transmit` returns
success with an empty body). Legacy VirtIO duplicates the modern transport (15
tests). PS/2 `PARTIAL`. Serial `IMPLEMENTED` (output only).

**Files.** `kernel/arch/x86_64/pci.zig`, new `kernel/devices/{device,driver,resource,irq}.zig`,
`kernel/drivers/kvdi/*`, `kernel/arch/x86_64/{virtio,virtio_blk,virtio_net}.zig`
(removal per ADR-0002/0003), `kernel/input/ps2.zig`, `shared/arch/x86_64/serial.zig`.

**Depends on.** K2 (IRQ registration, MSI), K3 (wait queues for blocking I/O).

**Required work.**
1. **Device/driver/resource objects** as described in
   [`device-driver-model.md`](../architecture/device-driver-model.md): static
   driver descriptors, match rules, probe/start/stop, exclusive resource grants.
2. **Registration, not search**: a driver receives its device and resources; it
   never walks the bus and never picks a vector.
3. **MSI/MSI-X programming** through the resource layer, using K2's vector pool.
4. **VirtIO-blk becomes asynchronous** behind the block interface (K9 defines it),
   with a completion callback and a bounded timeout per request.
5. **VirtIO-net is implemented or removed.** A `transmit` that returns success
   without transmitting is deleted in this stage even if the implementation is not
   ready; the class interface reports `Unsupported`.
6. **Retire the legacy VirtIO transport** (ADR-0002 step 3): move its live tests to
   the modern transport, delete `virtio_blk.zig` and the legacy paths, per
   ADR-0003.
7. **Serial gets a receive path** and becomes the console backend (K11 consumes it).
8. **PS/2 keyboard** is registered as an input driver through the model, not by
   hard-coded vector 33.
9. **Containment** per class: quarantine state and fault counters for each driver,
   reusing KVDI's model.

**Completion criteria.**
- Adding a driver requires no edit outside its own file plus one registration line.
- Every device's interrupt comes from the registration API; no driver knows a
  vector number.
- The block driver completes 10⁴ requests with balanced counters and a bounded
  worst-case latency reported by diagnostics.
- `net_transmit` either transmits and is measured, or does not exist.
- Legacy VirtIO files are gone and no test coverage was lost.

**Tests.**
*Unit* (host): match rules, resource arbitration (double claim is refused),
register encodings, descriptor-ring logic against a fake device.
*Integration* (QEMU): each driver probes, starts, completes a request, and stops.
*Stress*: 10⁴ block requests; 10⁵ interrupts with no lost completion.

**QEMU validation.** The virtio suite (blk, net, keyboard) with device-specific
marker assertions.

**Hardware validation.** One real block device (SATA/AHCI or NVMe) and one real NIC,
published per device. Not claimed before that runs.

**Risks.** The device model is where over-abstraction happens. Mitigation: the
class interfaces in §5 of the model doc are defined by their consumers, and no
interface gets a second consumer before a second driver exists.

**Promotion.** P → F when the model is in the real path for blk and input.
F → E with the QEMU driver suite recorded. E → H per device.

**Parallel.** K12's RTC/HPET work (see §4).

---

### K8 — DMA and IOMMU readiness

**Objective.** One DMA interface every driver uses, with ownership rules that make
use-after-free detectable; and a seam where an IOMMU can be inserted later without
touching drivers.

**Initial state (audit §B.5, §E.13).** DMA `PARTIAL`: a 64 MiB identity window with
a bitmap and allocate/free/release. IOMMU `NOT_STARTED`; the audit found no
`DMAR`/`IVRS` handling.

**Files.** `kernel/memory/dma.zig`, `kernel/devices/resource.zig`,
`kernel/arch/x86_64/{acpi,pci}.zig` (DMAR discovery, parse only).

**Depends on.** K1, K7.

**Required work.**
1. **Typed DMA handles**: `{ bus_addr, vaddr, phys, len, owner }`; freeing before
   completion is a detectible error in debug builds.
2. **Constraints at allocation**: alignment, 32-bit-only devices, contiguity; the
   interface refuses an impossible request instead of returning memory the device
   cannot address.
3. **Discovery passthrough**: parse `DMAR` (Intel) and `IVRS` (AMD) tables and
   record their presence and unit count in diagnostics. **Parsing only** — no
   translation, and the roadmap says so explicitly.
4. **The seam**: drivers receive a `DmaDomain` (today a thin wrapper over the
   identity window). A future IOMMU-backed domain implements the same struct.
5. **Coherency rules documented**: the x86-64 DMA model, when a flush is required
   (not on this architecture for normal memory), and why the interface still has a
   `sync_for_device`/`sync_for_cpu` pair (portability of drivers, not of the
   kernel).

**Completion criteria.**
- No driver calls the physical allocator directly for a buffer it hands to hardware.
- A double free or an early free is caught by the debug assertion.
- A 32-bit-only device is given a buffer below 4 GiB without the driver asking.
- Diagnostics report DMAR/IVRS presence, and the report is explicitly labelled
  "parsed, not used".

**Tests.**
*Unit* (host): constraint solver, bitmap reuse, handle lifecycle.
*Integration* (QEMU): a virtio device is given a constrained buffer and completes a
request with it.
*Stress*: 10⁵ allocation/free cycles with no map leak.

**QEMU validation.** The virtio request path with the constrained allocator; a
`-machine q35` boot with a DMAR table present, parsed and reported.

**Hardware validation.** A machine with an IOMMU present and enabled by firmware,
verifying the parse and the report; translation is out of scope.

**Risks.** The word "IOMMU" in a roadmap invites the assumption that isolation
exists. The documentation and the diagnostics string must both say "parsed, not
enforced" until a translation stage exists.

**Promotion.** P → F when every driver uses the interface. F → E with the QEMU
run. E → H with the parse verified on hardware.

**Parallel.** With K9's block interface design (the buffer contract is shared).

---

### K9 — Block layer and storage

**Objective.** A block layer that can carry more than one device, partitions that
are discovered rather than assumed, and a storage path that survives errors.

**Initial state (audit §F.1–F.2, §E.5).** Block layer `PARTIAL`:
`kernel/storage/block.zig` + `phys_blk.zig`, a single default device,
`installDefault` silently overwrites, `blockCurrent` timeouts share the tick
counter. Ramdisk exists. **GPT `NOT_STARTED`** — no partition discovery. VirtIO-blk
is synchronous.

**Files.** `kernel/storage/{block,phys_blk,ramdisk}.zig`, new
`kernel/storage/{partition,gpt,queue}.zig`, `kernel/drivers/kvdi/block.zig`.

**Depends on.** K7, K8, K1 (contiguous buffers), K3 (blocking requests).

**Required work.**
1. **Device registry**: block devices are named and enumerated; `installDefault`
   becomes `register`, and the default is an explicit selection.
2. **GPT parsing**: protective MBR, primary/backup header CRC, entry array CRC,
   partition bounds validation against the device capacity, and a fixed error for
   each rejection reason.
3. **Queue**: a request queue per device with a bounded depth, asynchronous
   submission through K7's interface, completion on interrupt, and a **real
   timeout** (ticks, not a shared counter).
4. **Error recovery**: `read` returns typed errors (`Io`, `Timeout`, `Bounds`,
   `NotReady`); repeated failures move the device to `degraded` and the layer
   refuses new requests with `Quarantined`.
5. **Buffer contract**: aligned, physically contiguous within a limit, allocated
   through K8's DMA domain.
6. **Statistics**: requests, bytes, retries, timeouts, per device.

**Completion criteria.**
- Two block devices coexist; the default is chosen explicitly.
- A GPT image with 3 partitions is discovered with correct bounds, and a corrupted
  header is rejected with a specific reason, not a crash.
- A read beyond the capacity fails with `Bounds` and does not reach the device.
- An injected device timeout produces `Timeout`, a retry per policy, and then
  `Quarantined` — with no infinite loop.
- The request queue never loses a completion (counter equality test).

**Tests.**
*Unit* (host): GPT parser against a corpus of good and malformed images (CRC
failures, overlapping entries, backup mismatch); queue state machine.
*Integration* (QEMU): virtio-blk with a partitioned image, read each partition,
verify a known pattern.
*Stress*: 10⁵ reads with random offsets and lengths; a fault-injection run where
every N-th request times out.

**QEMU validation.** The partitioned-image test with a recorded checksum.

**Hardware validation.** One SATA/AHCI or NVMe device with a real GPT disk.

**Risks.** The GPT parser is attacker-controlled input (a disk image); it must be
treated as untrusted, with bounds checks and no allocation proportional to the
declared entry count.

**Promotion.** P → F when the registry and GPT are in the real path. F → E with the
QEMU partitioned-image run. E → H per device.

**Parallel.** With K12 and with K11 (see §4).

---

### K10 — VFS and filesystems

**Objective.** A filesystem interface that is not RamFS-specific, with a page cache,
enforced permissions, and two backends that exercise the interface differently.

**Initial state (audit §F.3–F.7).** VFS `PARTIAL`: `kernel/fs/fs.zig` is hardwired
to RamFS, no vtable, no page cache, permissions stored but not enforced. RamFS
`IMPLEMENTED`/host (60 tests). KNV `IMPLEMENTED` codec, crash safety `PARTIAL`.
KFSX `IMPLEMENTED`/host (20 tests) but not mounted by the VFS. File handles exist
per process; no buffering beyond a fixed block cache in RamFS.

**Files.** `kernel/fs/{fs,ramfs,knv,knv_volume,kfsx,inode,superblock}.zig`, new
`kernel/fs/{vfs,page_cache,perm}.zig`, `kernel/security/capability.zig`.

**Depends on.** K9 (block-backed mount), K4 (process context), K5 (file handles as
capabilities).

**Required work.**
1. **VFS interface**: `mount`, `open`, `close`, `read`, `write`, `seek`, `stat`,
   `readdir`, `unlink`, `mkdir`, `rename`, `sync`, with `Inode`/`File` operations
   and a mount table. RamFS, KNV and KFSX implement it; the syscall layer touches
   only the interface.
2. **Page cache** keyed by (filesystem id, inode, page index), with a bounded size,
   write-back for writable backends, and invalidation on truncate.
3. **Permissions enforced** at open time (owner/mode and the process identity),
   not merely stored. The policy is a pure function with a table-driven test.
4. **Mount KFSX through the VFS**, so there are two real backends.
5. **Path resolution** hardened: no traversal above the root, bounded component
   count, no user-pointer re-reads.
6. **KNV crash safety** completed for the metadata path that is written today, with
   a documented recovery rule and a test that cuts the write at each step.
7. **Buffer/block size independence**: a 512-byte device and a 4 KiB device both
   work; the interface states the granularity.

**Completion criteria.**
- The syscall layer contains no RamFS reference.
- Two backends (RamFS and KFSX) pass the same interface test suite.
- A file written on a block-backed mount survives a clean reboot.
- A permission denial is a status code at `open`, with a test per mode bit.
- Page-cache accounting is bounded and returns to baseline on unmount.

**Tests.**
*Unit* (host): VFS interface conformance suite run against RamFS, KFSX and KNV;
permission function; path resolver; page-cache eviction.
*Integration* (QEMU): mount, write, sync, reboot, read; a permission-denied case.
*Stress*: 10⁵ create/write/unlink cycles; cache pressure with a small bound.

**QEMU validation.** The persistence-across-reboot test with a checksum, recorded.

**Hardware validation.** Persistence on a real disk, once K9's hardware tier runs.

**Risks.** The interface is the hardest thing to change later; it is therefore
defined by the three existing backends' common needs, not by an imagined POSIX
subset. Anything the backends do not need is not in the interface.

**Promotion.** P → F when the interface is in the real path with two backends.
F → E with the reboot persistence run. E → H on hardware.

**Parallel.** With K11 (see §4). The VFS interface on RamFS can be built before K9
lands; the block-backed mount waits.

---

### K11 — Input, console and terminal

**Objective.** A human can type at the machine and read what it says, through
interfaces, not through a driver's global function.

**Initial state (audit §G.1, §E.8, §G.4).** Console/tty `STUB` — serial output and
framebuffer text, no terminal, no line discipline, no job control. Input
`PARTIAL` — PS/2 keyboard scanned, no mouse. Logging `STUB` — `serial.print` with
no levels, no ring, no per-subsystem control.

**Files.** `kernel/input/{ps2,keyboard}.zig`, new `kernel/input/{input,event}.zig`,
`kernel/arch/x86_64/*` serial, new `kernel/tty/{tty,line,console}.zig`,
`kernel/diag/log.zig`.

**Depends on.** K7 (driver registration), K3 (wait queues for blocking reads),
K5 (handles for terminal devices, later).

**Required work.**
1. **Input events** as a typed record (key down/up, scancode, translated key,
   modifiers; pointer motion/buttons), produced by drivers and consumed by a
   dispatcher.
2. **Keyboard translation** with a layout table, modifier state machine, and a
   test for each modifier combination.
3. **Line discipline**: canonical mode with editing (backspace, `^U`, `^C`
   deferred as a signal until signals exist), echo, and a raw mode for future
   consumers.
4. **Terminal object** with a read queue and a write path, backed by serial and by
   the framebuffer text renderer; blocking read through K3's wait queue with a
   timeout.
5. **Logging levels** (`error`/`warn`/`info`/`debug`) with a compile-time filter and
   a per-subsystem runtime mask; the log becomes the first consumer of K13's ring.
6. **PS/2 mouse** driver or an explicit decision that it is out of scope with the
   reason recorded (no pointer-consuming system exists yet).

**Completion criteria.**
- Typing on the emulated keyboard appears on the console; editing works; `Enter`
  completes a line to a consumer.
- A blocking terminal read returns on input and on timeout.
- Log level filtering demonstrably suppresses and admits messages.
- No driver is called directly by the console; the input dispatcher routes.

**Tests.**
*Unit* (host): keymap and modifier state machine; line editing; log filter.
*Integration* (QEMU): the guest receives injected keystrokes through the monitor and
prints the resulting line.
*Stress*: 10⁵ keystrokes with no queue overflow and no lost event (counter).

**QEMU validation.** `sendkey`-driven input test with a recorded transcript.

**Hardware validation.** A real PS/2 or USB keyboard path (USB is a later stage;
if only USB exists on the reference machine, record the blocker).

**Risks.** Keyboard layout handling is a policy problem that tempts a big table and
a locale system; the scope here is one layout plus an explicit extension point.

**Promotion.** P → F when the terminal is the real console. F → E with the injected
input test. E → H on hardware.

**Parallel.** With K10.

---

### K12 — Timekeeping and power

**Objective.** A wall clock, a monotonic clock with a documented resolution, and
the ability to reboot and power off — the three things that make the machine
behave like a computer instead of a demo.

**Initial state (audit §G.3, §G.6, §E.11–E.12).** Timekeeping `PARTIAL`: ticks
only, no wall clock, no RTC, no HPET (`NOT_STARTED`). Power management
`NOT_STARTED`: no shutdown, no reboot, no ACPI platform services; `main.zig` ends
in `haltForever`.

**Files.** `kernel/arch/x86_64/{timer,acpi}.zig`, new
`kernel/arch/x86_64/{rtc,hpet,power}.zig`, `kernel/diag/*`, `boot/uefi/*`
(handoff of the FADT/RSDP is already present).

**Depends on.** K2 (tick source) and K0 (ACPI tables available early). Not on the
driver model: RTC and HPET are fixed platform devices.

**Required work.**
1. **Clock sources**: TSC (calibrated against PIT or HPET), HPET if present, LAPIC
   timer as the tick; a documented preference order and a `clock_source` report.
2. **Monotonic time** in nanoseconds derived from the selected source, with the
   resolution and the worst-case read cost measured.
3. **Wall clock**: read the RTC at boot (BCD and binary modes, 12/24h), store an
   offset against the monotonic clock, and expose both `monotonic_now` and
   `wall_now`. No time-zone handling (the ABI carries UTC).
4. **Shutdown and reboot** via the FADT's PM1a/PM1b control registers (`SLP_TYP`
   `S5` and reset), with a fallback to the keyboard controller reset line and a
   documented failure per path.
5. **CPU idle hint** (the `hlt` in K3's idle task) and the power states that are
   actually reachable; suspend is explicitly out of scope.
6. **Report**: boot time from handoff to idle, in the log, as the first honest
   performance number.

**Completion criteria.**
- Two successive `wall_now` reads differ by the elapsed monotonic time within a
  documented tolerance.
- Power off in QEMU terminates the guest (the harness observes exit); reboot
  restarts it.
- The clock source is reported and a fallback path is exercised by forcing the
  preferred source unavailable.
- No code derives a timeout from the wall clock.

**Tests.**
*Unit* (host): BCD conversion, RTC register decode table, monotonic/wall
arithmetic including offset changes.
*Integration* (QEMU): poweroff and reboot with observable guest termination; a
clock-advance test using the emulator's time.
*Stress*: 10⁷ monotonic reads with no drift against the emulator's clock beyond the
documented bound.

**QEMU validation.** `-no-reboot` poweroff, reboot loop with a marker counter.

**Hardware validation.** RTC offset on a machine whose firmware leaves the RTC in
an unexpected mode; shutdown on a named laptop/desktop.

**Risks.** ACPI shutdown without an AML interpreter works only for the fixed
hardware path in the FADT; machines that need `_S5` are unsupported until an AML
interpreter exists. This is a documented limitation, not a bug.

**Promotion.** P → F when poweroff/reboot and the two clocks are in the real path.
F → E with the QEMU power tests. E → H on two named machines.

**Parallel.** With K7 (see §4), and with K11.

---

### K13 — Diagnostics and hardening

**Objective.** The system can tell you what it is doing and what went wrong, and
its invariants are checked continuously in debug builds.

**Initial state (audit §A.12, §D.8, §G.4, §G.7).** Panic `STUB`. Diagnostics
`PARTIAL`: ad-hoc report functions in `main.zig`, counters scattered across
modules, no unified registry. Resource accounting `NOT_STARTED`.

**Files.** new `kernel/diag/{crash,trace,counters,health}.zig`, `kernel/main.zig`,
every module that registers counters.

**Depends on.** Everything; the seed landed in K0, the counters accumulate from
K1 onward.

**Required work.**
1. **Crash record** completed (from K0): ring of tracepoints, register dump,
   phase, last syscall, last lock. Stored to a reserved block when available and
   read back on the next boot.
2. **Tracepoints**: compile-time categories, per-CPU ring buffer, zero cost when
   disabled (verified by comparing a benchmark with and without).
3. **Counter registry**: a single table with name, value and subsystem; dumped on
   demand and at shutdown. This replaces the report functions in `main.zig`.
4. **Invariant checkers** (debug builds only): frame accounting, region list,
   handle table consistency, scheduler queue integrity, lock order. Each has a
   "break it on purpose" test that proves the checker fires.
5. **Resource accounting**: per-process CPU time, resident pages, handles, open
   files; global totals that must balance at idle.
6. **Health states** per subsystem (`ok`/`degraded`/`quarantined`) reported once at
   boot and on change.
7. **Benchmarks** for the paths that claim to be hot (syscall round trip, context
   switch, page fault) wired into `tools/benchmarks/`, so later optimisations have
   a baseline.

**Completion criteria.**
- An injected fault (a deliberate null dereference behind a build option) produces
  a crash record that is read back on the next boot and printed in full.
- Tracepoints disabled cost nothing measurable in the syscall benchmark.
- Every counter that appears in a stage's completion criteria is in the registry.
- Each invariant checker has a negative test.

**Tests.**
*Unit* (host): ring buffer, record encoding, counter table.
*Integration* (QEMU): injected fault → crash record → reboot → report.
*Stress*: trace ring under 10⁶ events with no loss beyond the documented drop
counter.

**QEMU validation.** The crash-and-recover test, recorded.

**Hardware validation.** The crash record on a machine with real storage.

**Risks.** Instrumentation becomes a source of bugs; every checker is debug-only
and every tracepoint has a cost test.

**Promotion.** P → F when the registry replaces the report functions. F → E with
the crash-recovery run. E → H on hardware.

**Parallel.** Continuous from K1.

## 7. Refactor list (only what the stages require)

| Refactor | Stage | Why it is necessary, not cosmetic |
|---|---|---|
| `main.zig` → phase table | K0 | every later stage adds an init step; a 5 000-line function makes order unreviewable |
| one TSS per CPU | K0 | ring 3 on an AP is otherwise impossible |
| break `apic ↔ timer` | K2 | the cycle makes both untestable and hides tick ownership |
| one tick source | K2 | two `tick()` callers make scheduling non-deterministic |
| unmap frees frames | K1 | nothing can reclaim or trust memory without it |
| shared kernel PDPT | K1 | the private copy hides kernel mappings in every space after the first |
| scheduler policy extracted | K3 | 0 tests is a consequence of policy and mechanism being fused |
| wait queue replaces ad-hoc blocking | K3 | every driver needs blocking with a timeout |
| VFS interface over RamFS | K10 | the syscall layer must not name a filesystem |
| retire legacy VirtIO | K7 | two transports for one device is duplication with divergent tests |
| delete dead files | K0 | `elf_compat.zig`, `dir_entry.zig`, `test_ramfs_runner.zig` have no callers |

Not on the list, deliberately: rewriting RamFS, replacing the KVDI transport,
moving the compositor, redesigning the syscall ABI. Reasons in
[`kernel-internals.md`](../architecture/kernel-internals.md) §9.

## 8. Directory layout, target

```text
kernel/
  init/        phase table and steps             (K0)
  arch/x86_64/ mechanisms: segments, IDT, APIC, timers, paging, ports, context
  memory/      physical, vmm, region, heap, dma  (K1, K8)
  exec/        process, thread, scheduler, policy, wait, mutex  (K3, K4)
  security/    handle table, capabilities        (K5)
  ipc/         channels, shared memory           (K6)
  devices/     device, driver, resource, irq     (K7)
  drivers/     kvdi, ps2, (later: sata, nvme, nic)
  storage/     block, queue, gpt                 (K9)
  fs/          vfs, ramfs, knv, kfsx             (K10)
  tty/         terminal, line discipline         (K11)
  diag/        crash, trace, counters, health    (K13)
  main.zig     entry, phases, idle               (<200 lines)
```

`kernel/graphics/` moves out of this layout when the user-space compositor exists;
it is not part of this initiative and must not be moved "for tidiness" before
then.

## 9. Test tiers per stage (summary)

| Stage | Host unit tests | QEMU integration | Stress/SMP |
|---|---|---|---|
| K0 | phase table, handoff, crash record | boot transcript, degraded path | — |
| K1 | regions, bitmap, fault policy, tables | map/unmap/protect, fault isolation | create/destroy 10⁴, fragmentation |
| K2 | APIC encodings, vector table | AP startup, shootdown | 10⁶ ticks, 10⁵ shootdowns, `-smp 4` |
| K3 | policy, locks, wait queue | counter under mutex, sleeping | 10⁵ switches, SMP counter |
| K4 | lifecycle, limits | process isolation, exit/join | 10⁴ process cycles |
| K5 | handle table, revoke | cross-process handle | 10⁵ open/close |
| K6 | arg validation, ABI layout | syscall conformance, shm | 10⁵ syscalls |
| K7 | match, resources, rings | per-driver request | 10⁴ requests |
| K8 | constraints | constrained DMA request | 10⁵ alloc/free |
| K9 | GPT corpus, queue FSM | partitioned image | 10⁵ reads, fault injection |
| K10 | VFS conformance ×3 backends | mount/write/reboot | 10⁵ ops, cache pressure |
| K11 | keymap, line edit, log filter | injected keystrokes | 10⁵ keys |
| K12 | BCD/RTC decode, clock math | poweroff, reboot, clock | 10⁷ reads |
| K13 | ring buffer, record codec | crash → recover | 10⁶ tracepoints |

## 10. Blockers and dependencies outside this document

| Blocker | Effect on this roadmap | Status |
|---|---|---|
| **No OVMF firmware in the build environment.** `curl: (35) SSL_ERROR_SYSCALL` to `release-assets.githubusercontent.com:443`; every QEMU target exits 2 with `no OVMF firmware found`. | Layers 3–9 of §5 are unreachable. No stage can pass E or H. | open, documented in `docs/validation/qemu.md` |
| **No CI execution.** `.github/workflows/ci.yml` exists and has never run. | Compile+host-test is only ever verified locally. | open |
| **No KVM / no admin rights.** | QEMU runs would be TCG-only, which is acceptable for correctness but not for timing claims. | environment constraint |
| **No physical reference machine on record.** | No stage can be promoted to H, and no hardware matrix exists. | open |
| **AML interpreter absent.** | ACPI `_PRT` route tables and `_S5`-only shutdown paths are unsupported; IOAPIC routing is limited to the MADT description. | by design for now (K7/K12 notes) |

These are environmental facts. This document does not invent results to route
around them: every stage's E and H tiers are explicitly unverified.

## 11. What this roadmap does not cover

- Linux and Windows binary compatibility, Wine/Proton-style loaders, PE execution.
- The graphics pipeline: KGA, KGX, KGL, KVK, KGR, KWM, the compositor and the
  display core beyond the framebuffer handoff.
- Applications, SDK surface beyond the syscall layer, package management, desktop.
- Networking beyond the device class (no TCP/IP stack in this initiative).
- USB, audio, hot-plug, suspend/resume, NUMA, swap, SMP load balancing.

Each belongs to a different roadmap and is listed here only so that its absence is
not read as an oversight.

## 12. Definition of "kernel complete" for this initiative

The initiative's goal is not feature parity with another system. It is that the
kernel can be described by the properties in
[`kernel-internals.md`](../architecture/kernel-internals.md) §12, each with
evidence: it reaches a steady state; it stays correct under concurrency; it can
shut down and reboot; and its failures are diagnosable. When those four hold at
tier E on the emulator, the kernel has a foundation on which drivers, filesystems
and services can be finished without re-cutting the foundation.

Until then, every status statement about the kernel must carry the classification
from the audit and the validation layer from §5. No percentage is derived from
this roadmap.
