# The task subsystem: policy, wait queue and mutex — 2026-11-01

- Status: **implementation record**. It states what the tree does now, with the
  commands that were executed and their results. It claims no runtime behaviour.
- Companion: [`2026-11-01-scheduler-tests.md`](2026-11-01-scheduler-tests.md)
  (the tests that came first and found three preemption defects) and
  [`../roadmap/KERNEL_COMPLETION_ROADMAP.md`](../roadmap/KERNEL_COMPLETION_ROADMAP.md)
  (K3 is the stage this record advances: "a scheduler with a testable policy, a
  lock, an idle task … and the synchronisation primitives the rest of the kernel
  needs").
- Scope: the split of the scheduling policy out of the scheduler, the wait queue
  that replaces the stub, the mutex that did not exist, and the dead run queue
  that was deleted.
- Not in scope: the lock, the idle task, the reader/writer lock, the condition
  variable, and any caller of the new primitives inside the kernel. All five are
  open, and §4 says why.

## 0. What was executed

| Command | Result |
|---|---|
| `zig build` | success — image written (`zig-out/bin/kynox.img`, 128 MiB, 32 731 clusters) |
| `zig build test --summary all` (fresh cache) | success — **51/51 steps, 781/781 tests**, 24 artifacts |
| `zig test kernel/task_root.zig` (host, filtered) | success — 109 tests with the module, 46 in the artifact |

The count moved from 748 to 781: **+12** for the policy module, **+11** for the
wait queue, **+10** for the mutex, and −1 for the anonymous test block of
`ipc-tests`, which no longer counts because the artifact is filtered to its own
channel tests. `ipc-tests` reports 5 (4 channel tests plus the root block) and
`task-tests` reports 46.

## 1. The policy left the scheduler

K3 step 2 asks for exactly this:

> Split policy from mechanism: `policy.zig` is pure functions over queue state
> (`pickNext`, `shouldPreempt`, `chargeBudget`) with no globals;
> `scheduler.zig` owns the queues and the lock.

`kernel/task/policy.zig` is that module. It knows nothing about tasks, tasks
state, processes, interrupts or hardware: it sees a flat array of `Entry`
(a slot index, a virtual runtime, an eligible flag) and answers with an index.

| Function | Answers |
|---|---|
| `pickNext(entries, after)` | which slot runs next: the smallest virtual runtime, walking the ring from the slot that is leaving, ties broken by that order |
| `shouldPreempt(state_is_running, quantum)` | whether the running task has to leave: it has a slice and it is actually running |
| `quantumFor(slice)` | the quantum a task receives when it enters: its slice, and zero stays zero |
| `budgetFor(slice, weight)` | the virtual runtime that a slice of that weight is worth; at least one, so a task always advances |
| `deadlineFor(vruntime, slice, weight)` | the deadline of a new task |
| `minVruntime(entries)` | where a new task starts, so that it is not granted an unbounded stretch |

`scheduler.zig` keeps the mechanism: it builds the description of the queue
(`describeQueue`), maps the answer back to a task, owns the counters and the
state, and calls the four assembly symbols. The three places that used to hold
policy inline now call the module: the preemption check, the refill of the
quantum, the charge of the virtual runtime, and both halves of `spawn`
(`minVruntime` and `deadlineFor`).

`context.quantumPreempts` survives as a one-line delegate, because it is the
name other modules know; there is one definition, and it is in the policy.

Why the split matters beyond tidiness: the scheduler was the one module that
mixed "what should happen" with "how the processor is programmed", so a test of
the decision needed the processor. The policy has 12 tests that need nothing but
numbers, including a property test over 200 random queues that compares the ring
choice with a slow reference implementation.

## 2. The wait queue is real now

`kernel/task/wait.zig` **existed** and was nearly empty: 42 lines that cast the
pointer of a task to a `WaitRecord` and wrote `next` into the task object
itself, whose `dequeueWaiter` returned a field that nothing ever set, and whose
`wakeAllWaiters` freed nothing and woke nobody. No test reached it, and the file
was the reason the audit could say "no wait queue" while a file with that name
sat in the tree.

It is now a FIFO queue of caller-owned nodes, and the lost wakeup is closed by
one counter:

- `add` returns `.queued` (sleep) or `.already_woken` (a wake arrived before the
  waiter; re-check the predicate and do not sleep), which is the remembered wake;
- `wakeOne`/`popAndWake` take the head and wake it; a wake with nobody in the
  queue increments `pending_wakes` instead of vanishing;
- `detachHead` takes the head **without** waking it, for the direct handoff;
- `remove` cancels a wait, and the counters separate a wake, a cancellation and
  a timeout (`woken`, `cancelled`, `expired`);
- `expire(now)` ends the waits whose deadline passed, and a wait with deadline
  zero never expires;
- `wakeTask(task)` wakes one specific task where it is, and leaves no remembered
  wake behind, because a targeted wake names a task and not an event.

Eleven tests cover it, including a 500-operation random sequence that checks
after every operation that the count, the links, the tail and the flags agree,
and that the list never becomes a cycle.

## 3. The mutex that did not exist

The audit's §C.5 is blunt: the kernel had a spinlock and a counting semaphore,
and a semaphore is not a mutex. `kernel/task/mutex.zig` adds the missing
primitive: an owner, a recursion counter with a hard limit of 255, a queue of
waiters, and a release that **transfers the ownership before the wake**.

That order is the whole point. With "wake, then release", a third task can take
the mutex between the two steps, and the woken waiter finds it held again. With
"transfer, then wake", the waiter is already the owner when its wake routine
runs, and the test asserts exactly that from inside the wake callback. Ten tests
cover the traffic: acquisition, recursion, contention, handoff, a task that does
not own the mutex trying to release it, a waiter that gives up, a wait that ends
by its deadline, the recursion limit, and the counters.

Neither the mutex nor the queue is called by the kernel yet. `scheduler.blockCurrent`
still builds the channel waiter of `ipc/channel.zig`, which keeps its own array
of waiters; moving it onto the queue is the next step and it needs a decision
this record does not make — how a timeout-aware wake writes its result into the
waiter before the queue wakes it.

## 4. What is still open, and why

| Item | Why it is open |
|---|---|
| The lock, per-CPU ownership | `ready_queue` and `current[]` are per CPU in shape and there is no lock; with no AP ever started (`startAps` refuses without the trampoline) there is no second processor to interleave with, and a lock no test can contend is a decoration |
| Idle task | With no ready task the interrupt returns to what it interrupted; `hlt` belongs with the idle loop and the lock |
| A caller for the mutex and the queue | `scheduler.blockCurrent` is the caller, and it needs the deadline-aware wake contract described in §3 |
| Reader/writer lock and condition variable | Both build on the same queue and both fit once the caller exists |
| FPU/SSE in the switch | Audit defect 8; changing `task.s` without a boot to test it is a blind change to every context switch |

## 5. Dead code deleted

- `kernel/task/runqueue.zig` — added as "per-CPU run queue interface (stub)"
  with `// shift not implemented in stub` in `dequeue`, imported by nothing. The
  scheduler's own `ready_queue` is the per-CPU queue that exists; a second,
  worse one only made two documents claim the module was "missing" while it sat
  in the tree. Deleted.
- `tests/wait_lifecycle_regression.zig` — five structural assertions, one of
  which was literally "no lost-wakeup mechanism because wait.zig is absent". The
  claim is now false, the file was reachable by no target or script, and it
  imported `../../task/scheduler.zig`, a path that does not resolve. Deleted; the
  list of unreachable files goes from seven to six.

## 6. Documentation updated with the code

- `README.md`, `docs/PROJECT_STATUS.md`, `docs/PROJECT_STATUS.json`: 781 tests,
  51 steps, 24 artifacts, the per-artifact table, `scheduler` from 60% to 62%
  (the policy split and the two primitives exist and are tested; nothing calls
  them and the scheduler still has no lock, which is why the move is two points),
  the open findings `K-02` (synchronisation, partially closed) and `K-16`
  (runqueue, closed), and the six unreachable files.
- `docs/architecture/execution-model.md`: the synchronisation row no longer says
  the primitives are absent; it says which ones exist, how many tests they have,
  and that they have no caller.
- `CHANGELOG.md`: an entry under `Unreleased` that names the commands and the
  result.
- [`2026-11-01-scheduler-tests.md`](2026-11-01-scheduler-tests.md): the artifact
  it calls `scheduler-tests` was renamed `task-tests` when the queue and the
  mutex joined it; the record carries the note instead of being rewritten.
