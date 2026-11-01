# The reschedule IPI and the migration of a task — 2026-11-01

- Status: **implementation record**. It states what the tree does now, with the
  commands that were executed and their results. It claims no runtime behaviour:
  no AP has answered a startup IPI here, so no IPI has ever been delivered.
- Companions:
  [`2026-11-01-cpu-affinity.md`](2026-11-01-cpu-affinity.md) (the ownership of a
  task by a CPU, which this round uses),
  [`2026-11-01-ap-trampoline.md`](2026-11-01-ap-trampoline.md) (the AP reaches
  the kernel) and [`2026-10-31-kernel-core-audit.md`](2026-10-31-kernel-core-audit.md)
  §A.9 (SMP).
- Scope: the vector of the reschedule IPI, the decision that is not a tick, the
  migration of a task to another CPU, and the wake that lands on another CPU.
- Not in scope: a per-CPU tick source, TLB shootdown, migration of a running
  task, and any observation of a second processor.

## 0. What was executed

| Command | Result |
|---|---|
| `zig build` | success — kernel image and `kynox.img` (128 MiB) written |
| `zig build test --summary all` (fresh cache) | success — **52/52 steps, 828/828 tests**, 24 artifacts |
| `zig build docs-check` | success — every link resolves, every document classified |

`task-tests` moved from 68 to **72**, `arch-tests` from 156 to **159**. The total
moved from 821 to 828.

## 1. The gap this closes

The previous round ended with the honest sentence "an AP that answered would
sleep": its queue existed, its idle task existed, its own kernel task existed —
and nothing woke it. Two facts made that a dead end:

- a queue belongs to one CPU (`Task.cpu`), so a task that becomes ready on CPU 1
  cannot be taken by CPU 0, which is the one that is running;
- the kernel has **one tick source** by decision (`timer.TickSource`, finding
  `K-C6`), the 8254 is wired to one processor, and the local APIC timer of the
  BSP stays disarmed while the 8254 owns the tick. An AP therefore has no clock
  of its own to wake it.

The missing piece was a way for one processor to tell another "look at your
queue". That is the reschedule IPI.

## 2. The vector and its handler

| Piece | What |
|---|---|
| `apic.reschedule_vector` | 65, above the local timer (64) and outside the hardware range |
| `apic.sendReschedule(apic_id)` | a fixed IPI to one physical destination |
| `interrupt.s` | `INTERRUPT_ENTRY 65`, the same stub as every other vector |
| `interrupt.zig` | the gate in `install()`, and a branch in the handler that ends the interrupt with `apic.eoi()` and asks the scheduler |
| `scheduler.rescheduleCurrent()` | takes the state lock, counts the reschedule, and decides |

The stub is the same one as the timer, so the handler can return "switch": the
comment in `interrupt.s` says a non-zero `RAX` jumps to `kynox_task_switch`
with the frame still on the stack. The IPI therefore switches contexts through
exactly the path the timer uses — no second mechanism.

## 3. A reschedule is not a tick

`prepareNext` did two things at once: it decided, and it charged the slice. The
second part is the definition of a tick, and doing it from an IPI handler would
have made two statements false:

- the tick counter would move because another processor asked a question, and
  every timeout in the system is measured in ticks;
- the quantum of the running task would shrink, so a task's slice would depend
  on how often another CPU happened to wake somebody.

The decision is now one function with a flag (`decideNext(forced)`):

| Caller | `forced` | Moves the quantum? | Counts a tick? | Switches when… |
|---|---|---|---|---|
| `tick()` (the clock) | false | yes | yes | the slice ends or the task is no longer running |
| `rescheduleCurrent()` (the IPI) | true | **no** | **no** | another task of this CPU can run now |

A forced decision with nothing to run returns false and leaves the task where it
was, with the quantum it had.

## 4. A task can now be placed on another CPU: `migrateTo`

Ownership alone was not enough to give an AP work: the tasks of the boot are
created by the BSP, so every queue except the BSP's was empty. `migrateTo(task,
cpu)` is the primitive:

- refuses a **running** task (it is on a processor; changing its owner under it
  would leave the processor running a task that no longer belongs to it);
- refuses a **terminated** task and an id above `max_cpus`;
- refuses a move to the CPU that already owns it;
- sets the owner, queues the task on the destination when it is ready, and sends
  the reschedule IPI when the destination is not this CPU.

At boot, `distributeWorkToAps()` migrates the second worker as soon as
`startAps()` reports an online AP, and says why when there is none:

```text
[KNK] smp: worker task 3 moved to cpu=1
[KNK] smp: no AP online; the workers stay on the BSP
```

The migration is what a machine with more than one processor needs to make the
AP usable; on the machines this environment has, the second line is the one that
would print.

## 5. The wake that lands on another CPU

`wakeTask` used to queue the awakened task on **its own** CPU — the CPU that runs
the waker — regardless of who owned the task. With the ownership of the previous
round, that would have put a task of CPU 1 in the queue of CPU 0 and changed its
owner on the way (the queueing records the CPU), a silent migration of a blocked
task.

It now queues on `value.cpu`, and when that is not the CPU that runs the waker it
asks `smp.reschedule(value.cpu)`. The outcome is not a boolean, because each
refusal is a different reason:

| Outcome | When |
|---|---|
| `.sent` | the IPI was written to the controller; counted in `reschedule_requests` |
| `.same_cpu` | the destination is the CPU that asked (an IPI to itself can be refused by the hardware, and a self-wake needs no IPI) |
| `.unknown_cpu` | the number is not in the CPU table |
| `.not_online` | the CPU exists but has not registered: an IPI to a processor that is not in long mode delivers a vector to a processor with no table |
| `.no_apic` | the local APIC is not mapped (always the case on the host) |

`smp.rescheduleRequests()` is reported at boot, next to the number of reschedules
the handler served.

## 6. A defect found while wiring it: two counters for one processor

`startAps()` incremented `online_cpu_count` when its wait saw the AP online, and
the AP incremented it in `registerCpu` — a machine with two processors reported
three. The increment in `startAps` is gone: the AP is the one that knows it
arrived, and it counts itself once. A host test registers an AP twice and asserts
the counter moves once.

## 7. The tests added (7)

| Artifact | Test | Asserts |
|---|---|---|
| `task-tests` (4) | a reschedule switches to a ready task without moving the quantum or the clock | after a tick (which moves the slice by one) the IPI hands the processor over, the tick counter stays at 1, the counted reschedules at 1, and the slice is not charged again |
| | a reschedule with nothing to run keeps the task and its quantum | no candidate ⇒ no switch, the same task, the same state, the same slice, and the reschedule is still counted |
| | a task moves to another CPU and leaves the queue of the one that had it | chosen while it belongs to CPU 0, invisible to CPU 0 after the move; a running task, a terminated task, an id above `max_cpus` and a move to the current owner are refused |
| | a wake that lands on another CPU asks for that CPU and does not queue here | the state becomes ready, the owner does not change, and no IPI is counted on a host with no controller |
| `arch-tests` (3) | an AP that registers itself is counted once | two processors reported for two, not three, and a second registration changes nothing |
| | a reschedule asks for the CPU that can receive it, and refuses the others | `.same_cpu`, `.unknown_cpu` (twice), `.not_online`, then `.no_apic` once the AP is online on a host without a controller; the delivery counter does not move |
| | the first online AP is the one that is not the BSP | null while no AP registered, then the lowest online index |

## 8. What is still open

| Item | Why |
|---|---|
| An IPI that is actually delivered | No second processor has ever answered here; the vector, the gate, the stub and the handler are code, and the decisions they drive are host-tested |
| An AP with a clock | The reschedule covers "somebody woke me"; it does not give the AP a periodic tick, so its tasks are only preempted when another CPU pokes them |
| TLB shootdown | The same mechanism, a different payload: an address and a generation, with an acknowledgement counter |
| Migration of a running task | Needs a stop-the-world of one CPU or an IPI that makes it switch first |
| Fairness across CPUs | Nothing balances the queues: the BSP keeps what it creates unless the boot moves a worker |

## 9. Documentation updated with the code

- `docs/PROJECT_STATUS.{md,json}`: `scheduler` **79% → 83%**, `smp`
  **52% → 60%**, the measured counts (828, task 72, arch 159), the limitation
  lists and `K-01`.
- `README.md`: the SMP and scheduler rows and the test counts.
- `docs/ai/context-pack.md` and
  `docs/architecture/execution-model.md`: the reschedule path and the
  migration.
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md`: the K2 annotations about the
  IPI infrastructure.
- `CHANGELOG.md`: the entry of this round.
