Audit K3.12.4 — Preemption, Wait Queues and Thread Lifecycle

Branch: audit/k3-12-4-wait-lifecycle
Merge target: main

Files in scope that EXIST:
- kernel/task/scheduler.zig (State enum: ready, running, blocked, terminated; task fields: id, context, stack, stack_canary, kernel_rsp, space, state, exit_code, schedules, priority, quantum, weight)
- kernel/arch/x86_64/timer.zig (tick_count, onTick, acknowledge, endOfInterrupt, initApicTimer with calibration loop)
- kernel/arch/x86_64/interrupt.zig (interrupt stubs, PUSH_REGISTERS / POP_REGISTERS, ALIGN_STACK)

Files in scope that DO NOT EXIST:
- kernel/task/thread.zig
- kernel/task/wait.zig
- kernel/task/runqueue.zig
- kernel/task/metrics.zig
- kernel/arch/x86_64/clock.zig
- kernel/arch/x86_64/irq.zig
- kernel/arch/x86_64/ipi.zig

Invariants from AGENTS.md / user request:
1. Preemption: timer tick exists, quantum field exists (scheduler.zig line 113), but no `preempt_disable` / `preempt_enable` found anywhere in tree. No `need_resched` mechanism found.
2. Wait queues: `.blocked` state declared, but `wait.zig` absent; no addWaiter / removeWaiter / wakeOne / wakeAll / cancel / timeout mechanism. Lost wakeups are structurally guaranteed possible.
3. Sleep: `timer.ticks()` provides monotonic tick count; no deadline / sleep insertion / wakeup-by-timer module (no `wait.zig`, no `sleep.zig`). `timer.zig` has no deadline structure.
4. Lifecycle: `Task` has `terminated` state, `exit_code`, but no `join`, `reap`, `recycle`, or stack-release logic verified in source. `thread.zig` missing means no thread handle generation / anti-ABA mechanism exists at source level.
5. Stack ownership: `Task.stack` exists; no verification that a terminated thread's stack is only freed after context switch completes.

Defects / gaps recorded (NOT fixed):
- No wait queue infrastructure: lost wakeup, duplicate wakeup, concurrent timeout/cancel all unverified.
- No preemption disable/enable pair: scheduling invariants cannot be guaranteed under nested interrupts.
- No sleep / deadline module: time-based blocking relies solely on timer ticks without a deadline structure.
- No thread lifecycle isolation module (`thread.zig`): lifecycle contracts are embedded in scheduler.zig only.
- No IPI / IRQ isolation modules (`irq.zig`, `ipi.zig`): interrupt routing and inter-processor scheduling unverified.
- No clock module (`clock.zig`): no conversion of timer ticks to wall time or overflow protection for deadlines.

Tests added:
- tests/wait_lifecycle_regression.zig (structural assertions only; no privileged execution; no QEMU execution performed).
- `zig build test`: PASS (host tests include new file).

Status file update: docs/PROJECT_STATUS.md updated with audit reference; no maturity change (only structural audit and regression test added).

K4: NOT started.
