# The state lock of the scheduler — 2026-11-01

- Status: **implementation record**. It states what the tree does now, with the
  commands that were executed and their results. It claims no runtime behaviour.
- Companion: [`2026-11-01-task-subsystem.md`](2026-11-01-task-subsystem.md) (the
  policy split, the wait queue and the mutex) and
  [`2026-10-31-kernel-core-audit.md`](2026-10-31-kernel-core-audit.md), whose
  defect 1 is the subject of this record.
- Scope: the lock of the scheduler state, the per-CPU ownership that goes with
  it, the generic blocking entry point that a mutex needs, and the test that
  drives the whole chain.
- Not in scope: a real SMP run (no AP has ever started), the idle task, and a
  user of the mutex in the kernel.

## 0. What was executed

| Command | Result |
|---|---|
| `zig build` | success — image written (`zig-out/bin/kynox.img`, 128 MiB, 32 731 clusters) |
| `zig build test --summary all` (fresh cache) | success — **52/52 steps, 800/800 tests**, 24 artifacts |
| `zig build docs-check` | success — every link resolves, every document classified |

`task-tests` reports **59**: 6 for the lock, 13 for the policy, 18 for the
scheduler, 11 for the wait queue, 10 for the mutex, 1 for the context. The total
moved from 788 to 800.

## 1. The defect, in the words of the audit

> `current[]`, the queues and the statistics are written from interrupt context
> and from thread context, and there is **no lock at all**. The state is per CPU
> in shape — `current[]` and `ready_queue[]` are indexed by CPU — and nothing
> serialised the two writers.

So the shape was a promise the code did not keep. The fix could not be a plain
spinlock, and the reason is in the scheduler itself:

```text
tick() → prepareNext() → channel.expireAll() → wake → wakeTask() → enqueueReady()
```

Every one of those calls writes the state, and a non-re-entrant lock taken at the
top would deadlock on the first nested acquisition — on the boot path, on the
first timer tick that expires a wait.

## 2. `kernel/task/lock.zig`: a lock that knows its CPU

| Field | Meaning |
|---|---|
| `spin` | the exclusion of two CPUs, the architecture spinlock (`@cmpxchgStrong`) |
| `owner` | the CPU that holds the lock, or none |
| `depth` | how many times the owner took it; above one means a nested call of the scheduler |
| `contentions` | acquisitions that found the lock held by **another** CPU |
| `reentries` | acquisitions made by the CPU that already held it |
| `spins` | iterations of the waiting loop |
| `refused_releases` | releases by a CPU that did not hold the lock |

`acquire(cpu_id)` returns `.reentered` without touching the spinlock when the CPU
is the owner, and `.acquired` after winning the spinlock otherwise. `release`
decrements the depth and only unlocks at zero; a release from a CPU that does not
hold the lock changes nothing and is counted.

**The interrupt rule is part of the contract and is written in the file**: the
window between winning the spinlock and publishing the owner is two instructions
long, and an interrupt inside it would find a lock held by nobody. Both entry
points satisfy the rule — the timer *is* an interrupt handler, and the
thread-side entry points take the lock on a path where the kernel has interrupts
disabled. On the host there is no interrupt, which is why the tests can contend
with real threads and no `cli`.

Six tests, one of which is a **four-thread contention test** on the host: every
thread takes the lock, checks that it is the only holder, and releases it. The
criterion is the absence of violations, not fairness.

## 3. The scheduler takes it everywhere

`Scheduler.state_lock` is the field, and every entry point that reads or writes
`tasks`, `current`, the ready queues or the statistics takes it and releases it
on the way out:

| Entry point | Why it is guarded |
|---|---|
| `tick` | moves the clock, expires waits, switches |
| `prepareNext` (called by the blocking paths) | chooses and switches |
| `spawn`, `spawnUser` | allocate a slot, read the queue for the inherited runtime |
| `blockCurrent`, `blockCurrentForInput` | mark the task blocked, switch |
| `killCurrent`, `terminateCurrent` | mark the task terminated, release its files |
| `wakeTask` | make a task ready and enqueue it |
| `enqueueReady`, `dequeueReady` | the queues themselves |
| `init` | the first state |

`statisticsOf` deliberately does **not** take the lock, and says so: it runs from
the serial diagnostics, where a reading taken while a tick changes a field is
worth more than a deadlock. It also republishes the four lock counters, and the
boot log gained a line for them:

```text
[KNK] sched lock: 0 contentions, 3 reentries, max depth 2, 0 refused releases
```

A contention of zero on a single-CPU boot is the expected reading. A **refused
release** is always a defect, because it means a path left the lock behind — and
that is exactly what the new test
"every entry point of the scheduler leaves the state lock free" asserts for
`tick`, `spawn`, `wakeTask` and `terminateCurrent`.

## 4. `blockCurrentOn`: the blocking primitive the mutex needed

`blockCurrent(timeout)` existed and knew only the channel. The mutex needs the
same mechanics over its own queue, so the generic form is now a public entry
point:

```zig
pub fn blockCurrentOn(self: *Scheduler, queue: *wait_queue.WaitQueue,
                      node: *wait_queue.Node, timeout: u64) bool
```

The order it guarantees:

1. the deadline (`timeout` ticks from now, or none) is written into the node
   **before** it can enter the queue;
2. the node is queued — or was already queued **by the caller**, which is what the
   mutex does, since the ownership is handed over at release time; a node that a
   wake already reached is refused and the caller re-checks its predicate;
3. the task is marked blocked and the switch is prepared;
4. if there is nobody to switch to, the task is marked running again, the node
   leaves the queue and the call returns false. A wait that cannot happen must
   not become a task that never wakes.

## 5. The end-to-end test

The last test of the scheduler suite drives the whole chain that the three
records of this day built:

```text
holder takes the mutex
waiter tries to take it            → busy
waiter registers in mutex.waiters
scheduler.blockCurrentOn(...)      → waiter blocked, holder runs
mutex.release(holder)              → ownership to the waiter, wake → wakeTask
scheduler                          → waiter ready and enqueued
waiter releases                    → mutex free
```

Every step is asserted, including that the state lock is free at the end. This is
the first time the mutex, the wait queue, the policy and the scheduler are
exercised **together**, and it is the shape a mutex user in the kernel will use.

## 6. What is still open, and why

| Item | Why it is open |
|---|---|
| A real contended boot | No AP has ever started (`startAps` refuses without a trampoline below 1 MiB), so no two processors ever take the lock at once in the kernel. The host test contends with threads; the kernel has a single writer per moment |
| A user of the mutex | No boot path takes the mutex yet; `blockCurrentOn` is what a user needs, and the end-to-end test is what proves it |
| The idle task | With no ready task the scheduler returns false and the interrupt returns to what it interrupted; `hlt` belongs with the idle loop and the AP bring-up |
| The state of a nested call is one copy | `depth` proves the nesting happened and counts it; it does not prove that the nested reader saw a consistent state. That is a property of the code paths, not of the lock |
| FPU/SSE in the switch | Audit defect 8; changing `task.s` without a boot to test it is a blind change to every context switch |

## 7. Documentation updated with the code

- `README.md`, `docs/PROJECT_STATUS.md` and `docs/PROJECT_STATUS.json`: 800
  tests, the `scheduler` row raised from 62% to 68% (the lock, the per-CPU
  ownership and the generic blocking primitive exist with host tests; the SMP
  validation and the idle task do not), the new finding `K-01` wording and the
  `tests_validation` counts.
- `docs/architecture/execution-model.md`: the synchronisation row no longer says
  "no lock".
- `docs/ai/context-pack.md`: the state of the tree, regenerated with the new
  numbers and the reduced list of open defects.
- `kernel/main.zig`: the boot report of the scheduler prints the four counters of
  the lock.
- `CHANGELOG.md`: an entry that names the commands and the result.
