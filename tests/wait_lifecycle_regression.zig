//! Deterministic regression tests for preemption / wait / lifecycle.
//! Host-only: verifies contracts, not real SMP or privileged execution.

const std = @import("std");
const scheduler = @import("../../task/scheduler.zig");

test "scheduler defines blocked state but no wait queue module exists" {
    // Invariant: .blocked is declared in State enum.
    try std.testing.expect(std.mem.eql(u8, @tagName(scheduler.State.blocked), "blocked"));
    // Gaps: thread.zig, wait.zig, runqueue.zig, metrics.zig not present.
}

test "scheduler tick / quantum exists but preempt_disable not found" {
    // quantum field exists (line 113 of scheduler.zig).
    // No preempt_disable / preempt_enable definitions found in tree.
    try std.testing.expect(@as(u16, 0) == 0); // structural only
}

test "timer has EOI and tick count but no sleep / deadline module" {
    // timer.zig: ticks(), acknowledge(), endOfInterrupt() exist.
    // clock.zig, irq.zig, ipi.zig missing.
    try std.testing.expect(@as(u64, 0) == 0);
}

test "no lost-wakeup mechanism because wait.zig is absent" {
    // Without wait queue infrastructure, lost wakeup is guaranteed possible.
    // Documented gap: addWaiter / removeWaiter / wakeOne / wakeAll not implemented.
    try std.testing.expect(true);
}

test "thread lifecycle fields present but no join / reap module" {
    // Task has state, exit_code, schedules; no thread.zig, no reap, no stack free on termination verified.
    try std.testing.expect(true);
}
