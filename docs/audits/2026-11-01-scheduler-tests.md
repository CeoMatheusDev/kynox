# Scheduler tests and preemption — 2026-11-01

- Status: **implementation record**. It describes what the tree does now, with
  the commands that were executed and their results. It claims no runtime
  behaviour.
- Companion: [`2026-11-01-kernel-core-fixes.md`](2026-11-01-kernel-core-fixes.md)
  (the sweep that closed the defects needing no hypervisor) and
  [`2026-10-31-kernel-core-audit.md`](2026-10-31-kernel-core-audit.md) (the
  read-only audit; its defect 1 is the subject of this record).
- Scope: the scheduling policy of `kernel/task/scheduler.zig` — the ready
  queue, the choice of the next task, the accounting of the virtual runtime,
  the time slice — and the host tests that did not exist for any of it.
- Not in scope: SMP, migration, an idle task, and a lock. Those need a
  second processor or a runtime to be observed, and this environment has
  neither.

## 0. What was executed

| Command | Result |
|---|---|
| `zig build` | success — image written (`zig-out/bin/kynox.img`, 128 MiB, 32 731 clusters) |
| `zig build test --summary all` (fresh cache) | success — **51/51 steps, 748/748 tests**, 24 artifacts |
| `zig build docs-check` | success (it is part of `zig build test`) |

The new artifact is `scheduler-tests`: **12 tests** (11 named tests plus the
unnamed `task_root.test_0` that brings the module into the binary). The total
moved from 736 to 748, and no other artifact changed its count: `ipc-tests`
still reports 6, `arch-tests` still reports 144.

## 1. The policy had no test, and the tests found three defects

Defect 1 of the audit of 2026-10-31 said the scheduler "has no synchronisation
and pretends to be per-CPU". Both halves are still true of the design. What was
also true, and was not in the audit, is that **not one line of the scheduling
policy was executed by the 736-test suite**: no test root reached
`task/scheduler.zig`.

Writing the tests exposed three defects that a boot could not have shown
without a very patient observer.

| # | Defect | What the code did | Fix |
|---|---|---|---|
| 1 | The policy had no host test | 0 of 736 tests touched the queue, the choice or the accounting | New root `kernel/task_root.zig` and the `scheduler-tests` artifact: 12 tests over the FIFO queue, the full-queue refusal, the EEVDF minimum, the skip of blocked/terminated tasks and of threads of an `exiting`/`reaped` process, the stack-size refusal, the inherited start, the weight accounting, the pool limit, the tick, and the blocked task that must not be resurrected |
| 2 | A tick switched tasks even when the slice was not spent | `prepareNext` looked for the next ready task on every tick and switched to it: the quantum decided nothing, and the processor went to the task with the smallest virtual runtime on every timer interrupt | The switch now happens only when the current task cannot continue (it is blocked, terminated or exiting) or when its quantum reaches zero. The tick otherwise only moves the clock |
| 3 | The quantum was never refilled | `quantum` was set to 16 when the task was allocated and decremented on each tick; a task that spent its slice kept `quantum == 0` forever, and `quantumPreempts` treats zero as "not time-sliced" — so every task was time-sliced exactly once in its life | The entering task gets `quantum = slice` when it is scheduled |
| 4 | A preempted task with nobody to run stayed `ready` | After a slice expired, the task was marked `ready` and enqueued; if no other task could run, `prepareNext` returned false and the task kept the processor with `state == .ready` and a zero quantum — a task that no tick would ever account for again | The fallback restores `running` and a fresh quantum when the preemption found no successor |

Each of the four has a test that fails on the tree before the change: the tick
test asserts that the first tick returns `false` and that the second one — the
one that spends the quantum — returns `true`.

## 2. How the policy is tested without a processor

`task/scheduler.zig` reaches into the architecture for three things: the task
state segment, the page tables of the process, and the four symbols that
`arch/x86_64/task.s` defines for the real switch. The first two are pure
data structures on the host. The third does not exist, so the test root
`kernel/task_root.zig` **defines** the four symbols as plain variables:
`kynox_current_context`, `kynox_next_context`, `kynox_kernel_stack_pointer`
and `kynox_next_cr3`. Nothing jumps through them; the tests read the decision
that `prepareNext` makes and not the switch itself, which is exactly the part
that assembly cannot get wrong and policy can.

The root lives at the top of `kernel/` — next to `host_root.zig` and for the
same reason — because a root inside `task/` would sit below the files the
scheduler imports (`arch/`, `ipc/`, `fs/`), and Zig refuses that.

The artifact runs with `.filters = &.{"task.scheduler.test."}`. The module of
the scheduler imports the architecture modules, and their tests would otherwise
run a second time inside this artifact; counting them twice would inflate the
suite without testing anything new.

One detail that the tests had to respect, and that is a real property of the
scheduler: **every task needs its own kernel stack**. The canary lives at the
base of that stack, and two tasks sharing one stack overwrite each other's
canary and are killed on the next switch. The first draft of the tests did
exactly that and panicked the test binary — a panic that is evidence the canary
check works.

## 3. Still open

| Item | Why it is open |
|---|---|
| No lock, no per-CPU ownership | `ready_queue` is indexed by CPU, and `current[]` too, but nothing stops two processors from entering `prepareNext` at once. No AP has ever run (`startAps` refuses without the trampoline), so there is no second processor to interleave with — and a lock that no test can contend is a decoration |
| No idle task | With no ready task the scheduler returns `false` and the interrupt returns to whatever was interrupted. A real idle task belongs with SMP and the `hlt` path |
| No migration, no fairness/latency metrics | Both need more than one processor, or a runtime that can be observed |
| The switch itself | `task.s` still has no FPU/SSE state (defect 8 of the audit); changing it without a boot to test it is a blind change to every context switch |

## 4. Documentation updated with the code

- `README.md`, `docs/PROJECT_STATUS.md` and `docs/PROJECT_STATUS.json`: 748
  tests, 51 steps, 24 artifacts, `scheduler` from 55% to 60% (the policy is now
  executed and its three preemption defects are closed; the lock and SMP are
  not), and the count of unreachable files left as seven.
- `CHANGELOG.md`: an entry under `Unreleased` that names the commands and the
  result and does not claim a boot.
- `PROJECT_STATUS.md` item 11 and `PROJECT_STATUS.json` `scheduler.tests`: the
  sentence "the scheduler is not part of a test root" is no longer true and is
  replaced by the artifact that exists now.
