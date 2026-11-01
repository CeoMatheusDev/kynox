# Execution model: tasks, threads, processes and scheduling

- Status: **planning document** describing the target model and the current
  state. Nothing here is claimed to be implemented.
- Date: 2026-10-31.
- Related: [`kernel-internals.md`](kernel-internals.md),
  [`memory-management.md`](memory-management.md),
  [`security-architecture.md`](security-architecture.md),
  [`../audits/2026-10-31-kernel-core-audit.md`](../audits/2026-10-31-kernel-core-audit.md) §C/§D,
  [`../roadmap/KERNEL_COMPLETION_ROADMAP.md`](../roadmap/KERNEL_COMPLETION_ROADMAP.md) stages K3–K6.

## 1. Current state, precisely

| Concept | Reality today |
|---|---|
| Task | `kernel/task/scheduler.zig`: 32 static slots, a state enum, a context pointer, a priority and a tick budget |
| Context switch | `arch/x86_64/task.s`: saves callee-saved GPRs and `rsp`; **does not save FPU/SSE state** (comment confirms) |
| Scheduler | EEVDF over the tasks of a CPU: a virtual runtime, a deadline and a weight per task, and a quantum drawn from the slice; **no lock, no idle task**; **12 host tests** over the policy (`kernel/task_root.zig`), none over the switch itself |
| Preemption | PIT tick → `scheduler.tick()` → `prepareNext()`; the switch happens on the timer path, at the end of the quantum of the running task, or as soon as the task blocks. A tick with slice left only moves the clock |
| Threads | a task *is* a thread; no thread group |
| Processes | no process object. Scheduling slots are used directly as "processes"; `fs` indexes by a process id that must be smaller than `max_processes = 8` |
| Lifecycle | `create`, `start`, `terminateCurrent`; **no join, no wait, no reap, no exit code**; `terminateCurrent` never frees the slot, so a boot that cycles 32 tasks is out of slots |
| Synchronisation | spinlock and a counting semaphore; **a mutex with ownership, recursion and a direct handoff** (`task/mutex.zig`, 10 host tests) and **a wait queue with a deadline and no lost wakeup** (`task/wait.zig`, 11 host tests) exist since 2026-11-01, **with no caller in the kernel yet**; still no reader/writer lock, no condition variable and no futex-like primitive |
| Timers | PIT and LAPIC tick both drive scheduling; no per-task sleep, no timeout list |
| SMP | `current[]` is per-CPU in shape but the CPU struct's `current_task` is never written; a single global TSS means ring 3 on an AP is impossible |

The audit's summary applies: the scheduler is a correct *mechanism* for the
single-CPU demonstration and an incorrect *system* for anything else. Its policy
is now covered by 12 host tests (`audits/2026-11-01-scheduler-tests.md`), and
writing them closed three preemption defects; the lock, the idle task and the
SMP stress test are still missing, which is why the roadmap keeps the policy
testable before it is extended.

## 2. Objects

```text
Process  ──owns──▶ AddressSpace, HandleTable, ProcessLimits, exit status
   │
   └──contains──▶ Thread(1..n) ──has──▶ KernelStack, SavedContext, State, Priority

Scheduler ──owns──▶ run queues (per priority, per CPU), idle task per CPU
```

- **Thread** is the schedulable entity: kernel stack, saved context, FPU state,
  state, priority, affinity mask, owning process.
- **Process** is the resource container: address space, handle table, limits,
  exit status, list of threads, parent, and reaping state.
- A kernel-only thread has a process-less owner (`kernel_owner`), used by deferred
  work and by drivers. It still has a thread object, so the scheduler has one
  rule for all schedulable things.

Why processes are added *after* the scheduler is cleaned up: the container's
correctness depends on the address-space destroy (K2) and on the lock discipline
(K4). Building the process object first would mean writing lifetime code against
a memory manager that leaks.

## 3. Thread lifecycle

```text
created → ready → running → (blocked | ready) → running → exited → (joined) → freed
                        ↘ suspended
```

Rules:

1. **Exit is not destruction.** The thread records its exit status and moves to
   `exited`; its kernel stack is freed when the last joiner or the reaper runs.
   This is what allows `terminateCurrent` to be called from the thread itself.
2. **The current thread never frees its own stack.** It switches away first; the
   reaper frees it in another context.
3. **Affinity is a mask.** Empty mask is an error at creation, not a thread that
   never runs.
4. **Priority is an integer with a documented range** and a documented meaning
   (higher = more urgent; a thread may only be preempted by a strictly higher
   priority or by budget expiry). Fixed priority, no aging, no nice value, until
   a measurement shows starvation.
5. **FPU state is part of the context**: `xsave`/`xrstor` with a per-CPU area, lazy
   or eager depending on a build option; the default is eager because it is
   simple, and the measurement that would justify lazy is in the stress test.

## 4. Scheduling policy

- **Run queues**: one per priority level per CPU, each a doubly linked list of
  threads. Round-robin within a level, budget measured in ticks.
- **Selection**: highest non-empty level; if the current thread's level is not the
  highest, or its budget expired, switch.
- **Idle**: per-CPU idle thread in the lowest level; it `hlt`s. This is what makes
  the kernel stop being a script (audit headline finding).
- **Load balancing**: not now. The first SMP milestone is "two APs run threads
  concurrently without corruption"; balancing is a later, separate stage with its
  own test.
- **Policy/mechanism split**: `policy.zig` is pure functions over queue state
  (`pickNext`, `shouldPreempt`, `chargeBudget`) and is host-tested;
  `scheduler.zig` owns the queues and the locks. This is the change that turns
  "0 tests" into a testable core.

## 5. Synchronisation primitives (ordered by need)

| Primitive | Needed by | Design notes |
|---|---|---|
| Spinlock (exists) | everything short | keep; add debug owner + contention counters |
| Semaphore (exists) | few users | keep, or replace by wait queues where it is used as a sleep |
| **Wait queue** | scheduling, drivers, IPC | list of threads + a spinlock; `wait` drops the external lock, blocks, re-checks the predicate on wake (no lost wake-ups) |
| Mutex | file system, drivers | owner thread, recursion count, waiters; **sleeps**, so it is illegal in an interrupt |
| Reader/writer lock | VFS, capability table | writer-preferring; readers are counted; no recursion |
| Futex-like | user space later | not in this initiative; requires the user-space runtime contract |

Rules:

1. **Interrupt context may only take a spinlock, and only with interrupts
   disabled for the duration.** A mutex or wait queue in an interrupt handler is a
   bug caught by an assertion in debug builds.
2. **Lock ordering is documented** in one table (`kernel/exec/locks.md`), and the
   ordering is asserted in debug builds by a per-CPU "held lock level" counter.
3. **A condition is re-checked after every wake.** No code assumes a wake implies
   the condition holds.
4. **Every blocked wait has a timeout argument**; `no timeout` must be spelled
   explicitly.

## 6. Time

- **One tick source** for scheduling: the LAPIC timer in periodic or TSC-deadline
  mode. The PIT remains as a fallback and as a calibration reference; having both
  drive `tick()` is a defect (the audit records it), fixed in stage K3.
- **Two clocks**: a monotonic clock (ticks or TSC, for timeouts) and a wall clock
  (from the RTC at boot, adjusted by an offset). Timeouts use the monotonic clock
  only.
- **Sleep** is a wait on a timer queue: `timer.sleep(ticks)` inserts a wakeup at
  `now + ticks` and blocks on a wait queue. Waking happens in the timer interrupt,
  which only moves threads to `ready` — it never switches.

## 7. User/kernel transitions

Five entry points, all through the same frame layout:

| Entry | Vector/instruction | Frame |
|---|---|---|
| Syscall | `syscall` | saved registers + window mapping |
| Exception | IDT 0–31 | CPU frame + error code |
| Device interrupt | IDT 32–255 | CPU frame |
| Page fault | IDT 14 | CPU frame + CR2 |
| Timer | IDT 32 (LAPIC) | CPU frame |

Rules:

1. **The frame layout is defined once** in `shared/syscall_abi.zig` and asserted
   at compile time; the assembly and the Zig handler disagreeing is a build error
   or a boot assertion, never a silent corruption.
2. **User pointers are validated once, then used.** Copy-in/copy-out happens
   entirely before any state change (the audit's TOCTOU finding: `copyUserPath`
   validates and copies, but later code re-reads the same buffer).
3. **The kernel never dereferences a user pointer directly**; all access goes
   through copy helpers that check the region and the length.
4. **Signal/wakeup delivery happens on return to user space**, not in the middle
   of a kernel operation.

## 8. Isolation and limits

- Per-process limits: threads, handles, virtual size, resident pages. Exceeding a
  limit is a clean error to the caller, not a kernel panic.
- The capability table (16 entries today) is per process in the target; the
  current global table with `max_held = 8` is a placeholder that the audit
  classifies as PARTIAL.
- A user thread can never run with kernel privilege: the only way back into the
  kernel is an entry point, and every entry point validates its arguments.

## 9. Tests

| Tier | What |
|---|---|
| Unit (host) | policy functions: pick order, budget charge, preemption decision, queue invariants |
| Unit (host) | lock implementations: try-lock behaviour, wait-queue lost-wakeup property, rwlock writer preference. The mutex and the wait queue have their tests; the rwlock does not exist |
| Integration (QEMU) | create N threads that increment a counter under a mutex; assert the exact count |
| Integration (QEMU) | thread exits and is joined; slot and stack accounting returns to baseline |
| Concurrency (QEMU, SMP) | run the counter test on 2+ APs with the same assertion |
| Stress (QEMU) | 10 000 create/exit cycles, no slot exhaustion, no leak per the accounting counters |
| Fault injection | allocation failure at each of N points during thread creation leaves no half-created thread |

## 10. Acceptance for the execution model

The model is complete when all of the following hold with recorded evidence:
threads and processes have lifetimes that are checked by tests; the scheduler is
preemptive, deadline-free at idle, and covered by policy unit tests plus a SMP
stress test; synchronisation primitives have documented ordering and no lost
wake-ups; timeouts are real time; and the FPU state survives a switch (proved by
a test that writes distinct values per thread and reads them back).
