//! PMM regression tests (Fase 3).

const std = @import("std");
const physical = @import("../kernel/memory/physical.zig");

const testing = std.testing;

test "allocate and free real" {
    var manager: physical.Manager = .{};
    // Initialize with minimal map (simulated by calling reserve/minimum)
    manager.init(&[_]physical.handoff.MemoryDescriptor{
        .{
            .memory_type = .reserved,
            .physical_start = 0,
            .page_count = 256,
        },
        .{
            .memory_type = .conventional,
            .physical_start = 0x100000,
            .page_count = 64,
        },
    });

    const page_addr = manager.allocate() orelse unreachable;
    try testing.expect(manager.isUsed(page_addr));
    try testing.expect(manager.refcount[@as(u32, @intCast(page_addr / physical.page_size))] == 1);

    manager.free(page_addr);
    try testing.expect(!manager.isUsed(page_addr));
    try testing.expect(manager.refcount[@as(u32, @intCast(page_addr / physical.page_size))] == 0);

    // Double-free must be safe (no crash, no underflow)
    manager.free(page_addr);
    try testing.expect(!manager.isUsed(page_addr));
}

/// Shared reference: allocate once, share via reference, only release after last.
/// Note: real shared mapping requires page table integration; this tests PMM reference tracking.
test "shared reference tracking" {
    var manager: physical.Manager = .{};
    manager.init(&[_]physical.handoff.MemoryDescriptor{
        .{
            .memory_type = .reserved,
            .physical_start = 0,
            .page_count = 256,
        },
        .{
            .memory_type = .conventional,
            .physical_start = 0x100000,
            .page_count = 64,
        },
    });

    const page_addr = manager.allocate() orelse unreachable;
    try testing.expect(manager.refcount[@as(u32, @intCast(page_addr / physical.page_size))] == 1);

    // Simulate shared reference increment (would be done by mapping code)
    manager.refcount[@as(u32, @intCast(page_addr / physical.page_size))] += 1;
    try testing.expect(manager.refcount[@as(u32, @intCast(page_addr / physical.page_size))] == 2);

    manager.free(page_addr); // Only decrement, not release
    try testing.expect(manager.isUsed(page_addr));
    try testing.expect(manager.refcount[@as(u32, @intCast(page_addr / physical.page_size))] == 1);

    manager.free(page_addr); // Final release
    try testing.expect(!manager.isUsed(page_addr));
    try testing.expect(manager.refcount[@as(u32, @intCast(page_addr / physical.page_size))] == 0);
}
