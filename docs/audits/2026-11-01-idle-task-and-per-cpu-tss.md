# Per-CPU TSS and the idle task — 2026-11-01

- Status: **implementation record**. It states what the tree does now, with the
  commands that were executed and their results. It claims no runtime behaviour:
  no `hlt` of the idle task and no AP has ever executed here.
- Companions:
  [`2026-11-01-scheduler-lock.md`](2026-11-01-scheduler-lock.md) (the state lock
  this builds on), [`2026-11-01-kernel-core-fixes.md`](2026-11-01-kernel-core-fixes.md)
  (audit §10 defect list) and
  [`2026-10-31-kernel-core-audit.md`](2026-10-31-kernel-core-audit.md) (§A.3, §C.1).
- Scope: audit defect **2** (a single global TSS with one `rsp0`) and the idle
  half of defect **1** (the scheduler has nothing to run when nothing can run).
- Not in scope: the trampoline below 1 MiB (an AP still never starts), AP
  scheduling, and any runtime measurement.

## 0. What was executed

| Command | Result |
|---|---|
| `zig build` | success — kernel image and `kynox.img` written |
| `zig build test --summary all` (fresh cache) | success — **52/52 steps, 806/806 tests**, 24 artifacts |
| `zig build docs-check` | success — every link resolves, every document classified |

`task-tests` moved from 59 to **63** (13 policy → 15, 18 scheduler → 20) and
`arch-tests` from 144 to **146** (segment). The total moved from 800 to 806.

## 1. Defect 2: one TSS for every processor

> **The audit:** `rsp0` is a single global updated by the scheduler on every
> switch, which is only correct on one CPU. **The risk:** silent stack corruption
> the moment a second CPU runs ring 3.

`kernel/arch/x86_64/segment.zig` had one `TaskStateSegment`, one GDT table and
one `GdtPointer`. All three are now arrays of `max_cpus` (8):

| Object | Shape | Why |
|---|---|---|
| `tss_per_cpu` | `[8]TaskStateSegment align(16)`, 104 bytes each | one `rsp0` and one `ist1` per processor |
| `double_fault_stacks` | `[8][16 KiB]u8 align(16)` | the double fault is the one interrupt that arrives **while** another is handled; two CPUs sharing a stack overwrite each other's frame |
| `tables` | `[8][entry_count]Entry align(16)` | a descriptor is bound to a base address, so a second segment needs a second descriptor in a second table |
| `table_pointers` | `[8]GdtPointer align(8)` | what `lgdt` of that CPU loads |

The accessor clamps instead of indexing outside the table:

```zig
pub fn tssFor(cpu: u8) *TaskStateSegment {
    return &tss_per_cpu[@min(cpu, max_cpus - 1)];
}
```

`tss` was kept as `&tss_per_cpu[0]`, because the scheduler and the boot path that
run before the CPU table is known used that name; the two write sites that set
`rsp0` on every switch now use `segment.tssFor(smp.cpuId())`, so the BSP is the
same object it always was and an AP gets its own.

`installForCpu(cpu, stack_top)` is the whole of the per-CPU installation:
`rsp0`, `ist1 = doubleFaultStackTop(cpu)`, the table and the pointer, `lgdt`, and
the reload of the data segments (the code segment follows through a far jump).
`install()` is `installForCpu(0, …)`. It has a caller on a real path:
`kynox_ap_entry` calls it with the stack of the AP, **before** the CPU enters its
loop — which is the reason the segment of an AP can now be right.

The boot log states the shape instead of assuming it:

```text
[KNK] segments: 8 task state segments, ist1 of the BSP at 0x…, table verified yes
```

`verifyForCpu(cpu)` compares the pointer read back from the processor (`sgdt`)
with the table of that CPU; the BSP is verified at boot.

## 2. The other half of defect 1: what runs when nothing runs

> **The audit:** an idle task is missing.

Without one, a blocking call on a processor whose queue is empty returned
without switching (`blockCurrentOn` documented exactly that), and a timer that
expired the last wait had nobody to return to: the interrupt returned to whatever
it interrupted.

`Scheduler.ensureIdle()` creates it once (idempotent, returns the existing task),
and `Statistics.idle` reports its id at boot (`-1` when absent). Three decisions
are worth stating:

**It is a ring 3 task.** *(Correction, same day: "every task of this kernel is"
is false — `spawn` creates ring 0 kernel threads, and the boot workers are those.
The idle task is ring 3 because it is created with `spawnUser` and its body is
user code, which is a choice; see
[`2026-11-01-cpu-affinity.md`](2026-11-01-cpu-affinity.md) §7.)* Returning to a context
whose `cs` carries `rpl` 0 would leave the processor in ring 0 for the next
interrupt, and there is no way to switch *into* ring 0 that does not pretend the
frame came from the kernel. So the idle task has a user stack, a kernel stack of
8 KiB, and its body is user code that halts:

```zig
while (true) {
    x86_cpu.waitForInterrupt(); // sti; hlt
}
```

`sti; hlt` is one instruction pair in one `asm` block on purpose: `hlt` with
interrupts disabled never returns, and the pair closes the window in which an
interrupt arrives before the halt — `sti` only takes effect after the *next*
instruction, so the processor does not deliver an interrupt between them.

**The policy chooses it last, never first.** `policy.Entry` gained `idle`, and
`pickNext` keeps two candidates: the smallest virtual runtime among the real
tasks, and the smallest among the idle tasks. It returns the real one whenever
one exists, whatever the runtime of the idle task is — an idle task with a
smaller `vruntime` must not displace a task that could run, or the task would
wait for a halt to end. `policy.idleVruntime` (`maxInt(i64) / 4`, the largest
value that survives a slice being added) is the runtime the idle task starts
with, so even the tie between two idle tasks is decided by the policy and not by
an accident of geometry.

**A blocking call now always has somewhere to go.** The end-to-end scheduler test
blocks the only real task while the idle task is ready and asserts the switch;
the previous "nobody to switch to" path stays as the answer for the case where
the *current* task is the idle task itself.

## 3. The six tests added

| Artifact | Test | Asserts |
|---|---|---|
| `arch-tests` (2) | "each processor has its own task state segment and its own stack of ring 3" | writing `rsp0` of CPU 0 does not touch CPU 1, the double-fault stacks differ, and a CPU number above the limit is clamped to the last segment |
| | "the table of a processor names the task state segment of that processor" | the descriptor built from a segment parses back to its base (`taskSegmentBase` is the inverse of `taskSegment`) |
| `task-tests` (2) | "the idle task is chosen only when nothing else can run" | an idle entry with the smallest runtime loses to a real one; it wins when nothing else is eligible; two idle tasks are decided by the ring |
| | "an idle task never displaces a real one, even with a smaller runtime" | the same, over the four-slot shape the scheduler builds |
| | "the idle task exists once, and the policy only runs it when nothing else can" | `ensureIdle` twice returns the same task, `is_idle`, `vruntime = idleVruntime`, and the choice over the real queue |
| | "a task that blocks hands the processor to the idle task instead of failing" | `blockCurrentOn` succeeds on a queue where the idle task is the only candidate, and `current` becomes the idle task |

## 4. What is still open

| Item | Why it is still open |
|---|---|
| The trampoline below 1 MiB | `smp.startAps()` refuses while `trampoline_ready == false`, and nothing copies `ap_trampoline.s` to a page under 1 MiB. Until then no AP reaches `kynox_ap_entry`, so `installForCpu` has never run for a CPU other than the BSP |
| AP scheduling | `kynox_ap_entry` halts in a loop; the queue of the CPU is not consulted yet |
| The idle task in the running kernel | It is created at boot and reported, but nothing has observed it running: no `hlt` of this tree has executed here |
| Defect 8 (FPU/SSE in the switch) | Untouched: `task.s` changes without a boot to test them are blind |

## 5. Documentation updated with the code

- `docs/PROJECT_STATUS.{md,json}`: `scheduler` **68% → 74%** (the idle task, the
  per-CPU TSS under it, and the ring it takes part in), `kernel_cpu_interrupts`
  **60% → 66%** (per-CPU TSS/IST and the per-CPU table), the measured test counts
  (806, task 63, arch 146), the limitation lists, and `K-01`: the idle task is no
  longer a missing piece.
- `README.md`: progress table, test counts, limitations.
- `docs/architecture/execution-model.md` and `docs/ai/context-pack.md`: the idle
  task and the per-CPU segment are part of the description of the scheduler.
- `CHANGELOG.md`: the entry of this round.
