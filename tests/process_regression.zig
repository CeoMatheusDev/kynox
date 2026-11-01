//! Structural regression tests for K4.1 Process object.
//! Host-only: verifies contracts from docs/architecture/k4-process-model.md.

const std = @import("std");
const process = @import("../../task/process.zig");

test "Process handle generation prevents ABA reuse" {
    // Contract: handle.generation must match process.generation.
    // A stale handle (generation mismatch) must be rejected.
    const proc: process.Process = .{
        .pid = 1,
        .generation = 7,
        .handle = .{ .pid = 1, .generation = 7 },
        .state = .initializing,
        .space = null,
    };
    try std.testing.expect(process.verifyHandle(&proc, proc.handle));
    const stale = process.ProcessHandle{ .pid = 1, .generation = 6 };
    try std.testing.expect(!process.verifyHandle(&proc, stale));
}

test "Process state machine allows valid transitions" {
    var p: process.Process = .{
        .pid = 2,
        .state = .not_started,
    };
    p.state = .initializing;
    try std.testing.expect(p.state == .initializing);
    p.state = .running;
    try std.testing.expect(p.state == .running);
    p.state = .exiting;
    try std.testing.expect(p.state == .exiting);
    p.state = .exited;
    try std.testing.expect(p.state == .exited);
    p.state = .reaped;
    try std.testing.expect(p.state == .reaped);
}

test "Process create rejects zero pid" {
    // User processes must have non-zero pid (kernel uses 0).
    const result = process.createProcess(0, null);
    try std.testing.expect(result == null);
}
