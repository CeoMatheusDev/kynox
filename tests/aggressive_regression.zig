//! Testes agressivos e severos (path tracing).
//! Verifica invariantes, ownership, double-free, underflow, overflow, isolamento.

const std = @import("std");
const testing = std.testing;

// === PMM ===
const physical = @import("../kernel/memory/physical.zig");

test "PMM: allocate/free/double-free safe" {
    var manager: physical.Manager = .{};
    manager.init(&[_]physical.handoff.MemoryDescriptor{
        .{ .memory_type = .reserved, .physical_start = 0, .page_count = 256 },
        .{ .memory_type = .conventional, .physical_start = 0x100000, .page_count = 64 },
    });

    const page_addr = manager.allocate() orelse unreachable;
    try testing.expect(manager.isUsed(page_addr));

    manager.free(page_addr);
    try testing.expect(!manager.isUsed(page_addr));

    // Double-free must be safe (no crash, no underflow)
    manager.free(page_addr);
    try testing.expect(!manager.isUsed(page_addr));
}

test "PMM: shared reference tracking" {
    var manager: physical.Manager = .{};
    manager.init(&[_]physical.handoff.MemoryDescriptor{
        .{ .memory_type = .reserved, .physical_start = 0, .page_count = 256 },
        .{ .memory_type = .conventional, .physical_start = 0x100000, .page_count = 64 },
    });

    const page_addr = manager.allocate() orelse unreachable;
    const page = @as(u32, @intCast(page_addr / physical.page_size));

    // Simulate shared reference
    manager.refcount[page] += 1;
    try testing.expect(manager.refcount[page] == 2);

    manager.free(page_addr); // decrement only
    try testing.expect(manager.isUsed(page_addr));
    try testing.expect(manager.refcount[page] == 1);

    manager.free(page_addr); // final release
    try testing.expect(!manager.isUsed(page_addr));
    try testing.expect(manager.refcount[page] == 0);
}

test "PMM: overflow protection" {
    var manager: physical.Manager = .{};
    manager.init(&[_]physical.handoff.MemoryDescriptor{
        .{ .memory_type = .reserved, .physical_start = 0, .page_count = 256 },
        .{ .memory_type = .conventional, .physical_start = 0x100000, .page_count = 64 },
    });

    // Free a page that was never allocated (should be safe)
    manager.free(0x200000);
    try testing.expect(!manager.isUsed(0x200000));

    // Free unaligned address (should be safe)
    manager.free(0x100001);
    try testing.expect(!manager.isUsed(0x100001));
}

// === Scheduler ===
const scheduler = @import("../kernel/task/scheduler.zig");

test "Scheduler: preempt disable/enable basic" {
    scheduler.preempt_disable();
    scheduler.preempt_enable();
    // No crash = pass
}

test "Scheduler: preempt nesting (call multiple times)" {
    scheduler.preempt_disable();
    scheduler.preempt_disable();
    scheduler.preempt_enable();
    scheduler.preempt_enable();
    // No crash = pass
}

// === Capabilities ===
const security = @import("../kernel/ai/security.zig");

test "Capabilities: revokeAllCapabilities zeros table" {
    var table: security.CapabilityTable = .{};
    table.entries[0] = 1;
    table.entries[1] = 2;
    table.count = 2;

    security.revokeAllCapabilities(&table);

    try testing.expect(table.entries[0] == 0);
    try testing.expect(table.entries[1] == 0);
    try testing.expect(table.count == 0);
}

test "Capabilities: double revocation safe" {
    var table: security.CapabilityTable = .{};
    table.entries[0] = 1;
    table.count = 1;

    security.revokeAllCapabilities(&table);
    security.revokeAllCapabilities(&table); // double revocation

    try testing.expect(table.entries[0] == 0);
    try testing.expect(table.count == 0);
}

// === FPU ===
const fpu = @import("../kernel/arch/x86_64/fpu.zig");

test "FPU: state size correct" {
    try testing.expect(fpu.state_size == 512);
    try testing.expect(@sizeOf(fpu.FPUState) == 512);
}

// === Memory: overflow protection ===
test "Memory: overflow in allocation size" {
    const wanted: usize = std.math.maxInt(usize);
    const aligned = std.math.add(usize, wanted, 4095) catch return;
    _ = aligned;
    // Should not crash
}

// === Process ===
const process = @import("../kernel/task/process.zig");

test "Process: create and free" {
    const p = process.createProcess(1, null);
    try testing.expect(p != null);
    if (p) |proc| {
        try testing.expect(proc.pid == 1);
        try testing.expect(proc.state == .not_started);
        process.freeProcess(proc);
        // After free, create again should succeed
        const p2 = process.createProcess(1, null);
        try testing.expect(p2 != null);
    }
}

test "Process: pool exhaustion" {
    // Fill all slots
    var ptrs: [8]?*process.Process = undefined;
    for (&ptrs) |*p| {
        p.* = process.createProcess(2, null);
    }
    // Next should be null
    const p9 = process.createProcess(3, null);
    try testing.expect(p9 == null);

    // Free one and retry
    if (ptrs[0]) |p0| process.freeProcess(p0);
    const p10 = process.createProcess(3, null);
    try testing.expect(p10 != null);
}
