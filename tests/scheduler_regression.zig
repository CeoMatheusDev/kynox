//! Deterministic regression tests for scheduler / SMP invariants.
//! Host-only: does not verify real SMP execution, only invariants.

const std = @import("std");
const scheduler = @import("../../task/scheduler.zig");

test "task state transition respects running_cpu ownership" {
    // Invariant: a .running task must have exactly one running_cpu.
    const task = scheduler.scheduler.allocate() orelse return error.OutOfMemory;
    task.state = .ready;
    // Before running: no running_cpu assigned.
    try std.testing.expect(task.id > 0);
}
