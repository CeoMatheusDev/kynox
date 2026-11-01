# Which CPU owns a task — 2026-11-01

- Status: **implementation record**. It states what the tree does now, with the
  commands that were executed and their results. It claims no runtime behaviour:
  no AP has answered a startup IPI here.
- Companions:
  [`2026-11-01-ap-trampoline.md`](2026-11-01-ap-trampoline.md) (the AP reaches
  the kernel),
  [`2026-11-01-idle-task-and-per-cpu-tss.md`](2026-11-01-idle-task-and-per-cpu-tss.md)
  (the idle task and the per-CPU segment) and
  [`2026-11-01-scheduler-lock.md`](2026-11-01-scheduler-lock.md) (the lock that
  makes a choice atomic).
- Scope: the ownership of a task by a CPU, one idle task per CPU, and the task
  that an AP gets when it enters the scheduler.
- Not in scope: a wake-up path for the AP (the reschedule IPI), migration,
  per-CPU clocks and any run on a machine with more than one processor.

## 0. What was executed

| Command | Result |
|---|---|
| `zig build` | success — kernel image and `kynox.img` (128 MiB) written |
| `zig build test --summary all` (fresh cache) | success — **52/52 steps, 821/821 tests**, 24 artifacts |
| `zig build docs-check` | success — every link resolves, every document classified |

`task-tests` moved from 63 to **68**, `arch-tests` from 155 to **156**. The total
moved from 815 to 821.

## 1. The defect: the choice ignored the queue

`kernel/task/scheduler.zig` has one `current[]` and one `ready_queue[]` **per
CPU**, and the choice did not look at either of them:

```zig
fn describeQueue(self, current) [max_tasks]policy.Entry {
    for (self.tasks, 0..) |slot, index| {   // every task in the pool
        ...
        if (task.state != .ready) continue; // the only filter
```

So a second processor that called `prepareNext` would have taken **any** ready
task — a task of the BSP, the BSP's idle task included — and the two processors
would have shared one stack and one saved context. The per-CPU arrays were a
shape the code did not keep, for the second time in this subsystem (the first
was the state lock).

## 2. The fix: the task names its CPU

| Where | What |
|---|---|
| `Task.cpu` | the CPU that owns the task, `u8`, set by `allocate` to the CPU that creates it |
| `enqueueReady(task, cpu)` | records `task.cpu = cpu`: ownership travels with the queueing, so a task woken by an interrupt of CPU 1 is chosen by CPU 1 |
| `describeQueue` | iterates the pool but **skips every task whose `cpu` is not the current one**, so the queue of a CPU holds exactly the tasks that CPU may run |
| `idleVruntime` / policy | unchanged: the idle task is still chosen only when nothing else of its own CPU can run |

The choice stays a scan of the pool filtered by ownership instead of the array
`ready_queue[cpu]`. That is deliberate: the array is filled by `enqueueReady` and
drained by `dequeueReady`, and a task that reaches `.ready` by another path
(a spawn, a wake, a preemption) is not necessarily in it — a filter over the
pool cannot miss a task, and the state lock is what makes "chosen once" true for
two processors (the first one that chooses marks it `.running` inside the lock).

## 3. One idle task per CPU

`ensureIdle(cpu_id)` used to return the single idle task of the kernel. It now
returns the idle task of **that** CPU and creates one when the CPU has none, with
its own 8 KiB user stack and its own 8 KiB kernel stack (`idle_user_stacks`,
`idle_kernel_stacks`, indexed by the CPU). Two idle tasks on one stack would
overwrite each other's frames the moment both processors halted.

A number above `max_cpus` is clamped to the last CPU **before** anything is
created, so a stray call cannot produce a task with `cpu = 12` and the stack of
the last slot.

The BSP still asks for its own: `ensureIdle(smp.cpuId())`.

## 4. The task that an AP gets: `adoptKernelTask`

An AP arrives from the trampoline in ring 0, on the stack the BSP filled in, with
`current[cpu] == null`. `prepareNext` starts with

```zig
const current = self.current[smp.cpuId()] orelse return false;
```

so an AP would have returned from every tick before looking at its queue — the
reason it halted in a loop and the reason a "just start the clock on the AP"
change would not have worked either.

`Scheduler.adoptKernelTask(cpu, kernel_stack_top, stack)` gives the processor a
task of its own: ring 0 (`kernel_code_selector`), the state `running`, the stack
the trampoline gave it, `quantum = 0` (the kernel thread of a CPU is not
time-sliced), and `current[cpu]` pointing at it. It is **not** queued: it is
already running, and a queue would offer it to itself. It becomes `ready` the
first time a switch takes the processor from it.

`smp.installCpuEntryHook` is how the processor calls that: `kynox_ap_entry` does
not import the scheduler, because the scheduler imports `smp` — a hook keeps the
dependency one-way and gives the kernel a place to say "this is what an AP does".

The boot line is the observable:

```text
[KNK] smp: cpu=1 entered the scheduler as task 6, idle task 7
[KNK] tasks: 2 CPU(s) entered the scheduler
```

## 5. What the AP still does not do — and why not

It sleeps. The reason is not missing code in this round, it is the tick policy:

- the kernel has **one** tick source by decision (`timer.TickSource`, audit
  finding `K-C6`), and the local APIC timer of the BSP is calibrated and left
  disarmed while the 8254 owns the tick;
- the 8254 is wired to one processor; an AP has no timer of its own armed;
- therefore an AP wakes only on an interrupt addressed to it, and nothing
  addresses one: the reschedule IPI does not exist yet.

So the honest statement of this round is: *the AP enters the scheduler, owns a
queue and an idle task, and waits*. Taking a task needs the IPI (or a per-CPU
tick source chosen by the same policy), and that is the next step.

## 6. The six tests added

| Artifact | Test | Asserts |
|---|---|---|
| `task-tests` (5) | a task belongs to one CPU and the other CPU never chooses it | a ready task with a smaller runtime and `cpu = 1` is invisible to CPU 0, and chosen once it is moved to CPU 0 |
| | the idle task of a CPU is not the last resort of another CPU | CPU 0 with nothing to run returns "nobody" while only CPU 1 has an idle task; its own idle task is then chosen |
| | each CPU has one idle task, and asking twice returns the same one | two distinct tasks, distinct stacks, idempotent per CPU, clamped above `max_cpus` |
| | an AP that enters the scheduler gets a task of its own | `current[1]`, `running`, `cs` of the kernel, the stack it was given, `entered_cpus = 1`, not in its own queue, idempotent, refused above `max_cpus`, and it is the task that a ready task of CPU 1 is chosen *instead of* |
| | queueing a task on a CPU makes that CPU its owner | `enqueueReady(task, 3)` sets `cpu = 3` and the queue of 3 holds it |
| `arch-tests` (1) | the stack of a CPU is handed out for the numbers the table has | 16 KiB per logical CPU, distinct addresses, `null` above `max_cpus` |

## 7. Correction to a previous record

[`2026-11-01-idle-task-and-per-cpu-tss.md`](2026-11-01-idle-task-and-per-cpu-tss.md)
said that "the idle task is a task of ring 3, exactly like every other task of
the kernel". That is **false**: `spawn` creates tasks in ring 0
(`kernel_code_selector`), and the boot workers are those. The idle task is ring 3
because it is created with `spawnUser` and its body is user code that halts in
the kernel on the way back from an interrupt — a design choice, not a rule about
the kernel. The comment in the scheduler is corrected with this record.

## 8. What is still open

| Item | Why |
|---|---|
| An AP that takes a task | No wake-up path: no reschedule IPI, no per-CPU tick source. The AP sleeps in `sti; hlt` |
| Migration | A task never changes CPU; a per-CPU queue with a migration protocol is the K3 item that follows |
| A fairness policy across CPUs | Nothing balances the queues: the CPU that creates a task keeps it |
| Runtime evidence | No `qemu-system-x86_64`, no OVMF: no AP has answered a startup IPI in this environment |

## 9. Documentation updated with the code

- `docs/PROJECT_STATUS.{md,json}`: `scheduler` **74% → 79%**, `smp` **44% → 52%**,
  the measured counts (821, task 68, arch 156), the limitation lists, `K-01`.
- `README.md`: the SMP and scheduler rows and the test counts.
- `docs/ai/context-pack.md`: the state of the tree in one page.
- `docs/architecture/execution-model.md`: the ownership of a task by a CPU.
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md`: the annotations of K3.
- `CHANGELOG.md`: the entry of this round.
