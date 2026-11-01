//************************************************************************//
//  vector_pool.zig                                                       //
//************************************************************************//
//                        This file is part of:                           //
//                              Kynox                                   //
//             https://github.com/CeoMatheusDev/Kynox                   //
//************************************************************************//
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 Kynox - All Rights Reserved.                      //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//

//! The device vectors, lent by the kernel instead of picked by the driver.
//!
//! The previous round gave the device range of the IDT an owner: every vector of
//! 68..254 has a stub, the registry refuses a second owner, and a vector that
//! arrives without one is counted instead of dispatched to a guess. What was
//! still missing is the step before that: a driver that wants a vector has to
//! *name* one. Two drivers that both name 70 find out at registration, on the
//! machine, in the order the drivers happen to run.
//!
//! This module is the allocator between the two. A driver asks for a block of N
//! vectors and gets a base; the pool is the one that knows which vectors are in
//! use, and the registry stays the one that knows who owns each vector.
//!
//! Three rules come from the hardware, not from taste:
//!
//!   * **N is a power of two.** The `Message Control` field of MSI is three
//!     bits holding log2(N), so a request of 3 cannot be expressed, and rounding
//!     up would tell the device it may use a vector the kernel never reserved.
//!     A request of 0 is a device that interrupts for nothing, or a caller bug.
//!   * **the base is a multiple of N.** The messages of a block of N occupy
//!     `base .. base+N-1`; a base that is not aligned would straddle two
//!     aligned blocks and the device would write vectors of the next block.
//!   * **the block fits below the spurious vector.** 255 is the vector of the
//!     spurious interrupt of the local APIC; a block that reached it would give
//!     a device a vector the controller has already spoken for.
//!
//! The range is 187 vectors — 68..254 — and 187 is not a power of two. It
//! therefore cannot host a block of 128: an aligned block of 128 would have to
//! start at 0 or at 128, and 128 + 128 = 256 is past 255. The largest block the
//! range accepts is **64**, and that number is computed at comptime from the two
//! constants of the registry below, so it moves with them instead of being a
//! fourth copy of the arithmetic.
//!
//! The two kinds of message want different shapes, and the pool gives one
//! function per shape instead of one function with a mode:
//!
//!   * **MSI** puts the vector in the message data, so a function that asks for
//!     four vectors gets `base`, `base+1`, `base+2`, `base+3` — one aligned
//!     block, and `reserve(4, name)` is that request;
//!   * **MSI-X** carries the vector in each table entry, so four entries are
//!     four independent vectors and nothing has to be adjacent or aligned.
//!     `reserve(1, name)` per entry is that request, and it is the same call
//!     with a different count, not a second allocator.
//!
//! Reserving and installing are two steps on purpose. A driver that has mapped
//! its registers but has not filled the table yet must not have a handler: an
//! interrupt that arrives in that window is counted as unhandled. It is a number
//! in the boot report, not a silent dispatch.

const std = @import("std");

const registry = @import("interrupt_registry.zig");

/// The first vector a device may be given.
pub const first_vector: u64 = registry.first_device_vector;

/// How many vectors the range holds: 68..254.
pub const capacity: u64 = registry.device_vector_count;

/// The vector of the spurious interrupt of the local APIC.
pub const spurious_vector: u64 = 255;

/// The last vector a block may reach.
pub const last_vector: u64 = first_vector + capacity - 1;

/// The largest block the range can host, computed from the range itself.
///
/// The search starts at 1 and stops at the first power of two whose aligned base
/// does not fit: it is the same arithmetic `plan` does, and a test asserts the
/// answer for this range is 64.
pub const max_block: u64 = blk: {
    var count: u64 = 1;
    var best: u64 = 1;
    while (count <= capacity) : (count *= 2) {
        const aligned = first_vector + ((count - first_vector % count) % count);
        if (aligned + count > last_vector + 1) break;
        best = count;
    }
    break :blk best;
};

/// Why a request was refused.
pub const Error = error{
    /// The request is zero or not a power of two.
    CountNotPowerOfTwo,
    /// The request is larger than the range can align and hold.
    CountTooLarge,
    /// No aligned block of that size is free.
    Exhausted,
    /// The grant does not describe a block this pool reserved.
    NotReserved,
    /// One vector of the block already has an owner.
    VectorBusy,
};

/// A block of vectors the pool has taken out of circulation.
pub const Grant = struct {
    /// The first vector of the block.
    base: u64,
    /// How many vectors the block holds.
    count: u64,
    /// Who asked, for the registry and the diagnostics.
    name: []const u8 = "",

    /// The first vector past the block.
    pub fn end(self: Grant) u64 {
        return self.base + self.count;
    }

    /// Whether `vector` belongs to the block.
    pub fn contains(self: Grant, vector: u64) bool {
        return vector >= self.base and vector < self.end();
    }
};

/// The blocks, indexed by the base vector minus `first_vector`.
///
/// A non-null entry is the length of the block that starts there; it is the
/// marker `release` checks, so a grant with a wrong base or a wrong count cannot
/// free somebody else's block.
var blocks: [capacity]?u64 = @splat(null);

/// Which vectors are out of circulation, indexed the same way.
var reserved: [capacity]bool = @splat(false);

fn slotOf(vector: u64) ?usize {
    if (vector < first_vector) return null;
    const index = vector - first_vector;
    if (index >= capacity) return null;
    return @intCast(index);
}

fn mark(base: u64, count: u64, value: bool) void {
    var offset: u64 = 0;
    while (offset < count) : (offset += 1) {
        const slot = slotOf(base + offset) orelse return;
        reserved[slot] = value;
    }
}

fn blockFree(base: u64, count: u64) bool {
    var offset: u64 = 0;
    while (offset < count) : (offset += 1) {
        const slot = slotOf(base + offset) orelse return false;
        if (reserved[slot]) return false;
        // A vector that the registry already gave to somebody else — a driver
        // that registered by hand, or a block this pool did not hand out — is
        // not free either. The two tables are asked, so neither can drift.
        if (registry.deviceName(base + offset) != null) return false;
    }
    return true;
}

/// The first base that an aligned block of `count` vectors would use.
///
/// The answer ignores occupancy: it is the arithmetic of the range, and the boot
/// report prints it so that an operator can see what a driver would be given
/// before any driver exists. Refuses what cannot be expressed at all.
pub fn plan(count: u64) Error!u64 {
    if (count == 0 or !std.math.isPowerOfTwo(count)) return error.CountNotPowerOfTwo;
    if (count > max_block) return error.CountTooLarge;

    const base = first_vector + ((count - first_vector % count) % count);
    if (base + count > last_vector + 1) return error.CountTooLarge;
    return base;
}

/// Takes a block of `count` vectors out of circulation and returns its base.
///
/// The block is reserved and not installed: no vector of it has a handler yet,
/// and an interrupt that arrives in that window is counted as unhandled. The
/// caller installs with `install` and gives the block back with `release`.
pub fn reserve(count: u64, name: []const u8) Error!Grant {
    const first_base = try plan(count);

    var base = first_base;
    while (base + count <= last_vector + 1) : (base += count) {
        if (!blockFree(base, count)) continue;

        const slot = slotOf(base) orelse return error.CountTooLarge;
        blocks[slot] = count;
        mark(base, count, true);
        return .{ .base = base, .count = count, .name = name };
    }
    return error.Exhausted;
}

/// Gives every vector of the block the same handler.
///
/// One handler for N vectors is the shape the hardware has: the handler receives
/// the vector that arrived, so a block of four is one function that reads its
/// argument, not four functions. The installation is all or nothing — a vector
/// that already has an owner means the whole block is given back, because half a
/// block is a device that interrupts on a vector nobody watches.
pub fn install(grant: Grant, handler: registry.Handler) Error!void {
    if (!owns(grant)) return error.NotReserved;

    var done: u64 = 0;
    errdefer {
        var index: u64 = 0;
        while (index < done) : (index += 1) _ = registry.unregisterDevice(grant.base + index);
    }

    while (done < grant.count) : (done += 1) {
        registry.registerDevice(grant.base + done, grant.name, handler) catch return error.VectorBusy;
    }
}

/// Whether the pool is the one that handed out this block.
fn owns(grant: Grant) bool {
    const slot = slotOf(grant.base) orelse return false;
    const count = blocks[slot] orelse return false;
    return count == grant.count;
}

/// Gives the block back, and its owners with it.
///
/// Returns `false` when the grant does not describe a block this pool reserved —
/// a stale grant, a wrong count, a vector that a driver registered by hand. A
/// release that cannot be checked is worse than no release: it would free a
/// vector that another device is using.
pub fn release(grant: Grant) bool {
    if (!owns(grant)) return false;

    var offset: u64 = 0;
    while (offset < grant.count) : (offset += 1) {
        _ = registry.unregisterDevice(grant.base + offset);
    }

    const slot = slotOf(grant.base) orelse return false;
    blocks[slot] = null;
    mark(grant.base, grant.count, false);
    return true;
}

/// How many vectors are out of circulation.
pub fn inUse() u64 {
    var count: u64 = 0;
    for (reserved) |taken| {
        if (taken) count += 1;
    }
    return count;
}

/// How many vectors a driver could still be given, one at a time.
pub fn freeCount() u64 {
    return capacity - inUse();
}

/// How many blocks are reserved. A block of four counts once.
pub fn blockCount() u64 {
    var count: u64 = 0;
    for (blocks) |block| {
        if (block != null) count += 1;
    }
    return count;
}

/// Whether a vector is out of circulation.
pub fn isReserved(vector: u64) bool {
    const slot = slotOf(vector) orelse return false;
    return reserved[slot];
}

/// The name of the grant that holds a vector, or null.
pub fn holderOf(vector: u64) ?[]const u8 {
    const slot = slotOf(vector) orelse return null;
    if (!reserved[slot]) return null;

    // Walk back to the base of the block: at most `max_block` steps, and the
    // walk stops at the first reserved vector whose predecessors are free.
    var base = vector;
    while (base > first_vector) : (base -= 1) {
        const previous = slotOf(base - 1) orelse break;
        if (!reserved[previous]) break;
    }

    const start = slotOf(base) orelse return null;
    const count = blocks[start] orelse return null;
    if (vector - base >= count) return null;
    return registry.deviceName(base) orelse "";
}

/// Clears both tables.
///
/// The pool and the registry are two views of one fact, and a test that cleared
/// one would leave the other describing a machine that no longer exists.
pub fn resetForTest() void {
    blocks = @splat(null);
    reserved = @splat(false);
    registry.resetForTest();
}

//--------------------------------------------------------------------------//
//  Tests                                                                   //
//--------------------------------------------------------------------------//

const testing = std.testing;

fn testHandler(vector: u64) bool {
    _ = vector;
    return false;
}

test "the block of a driver starts at 68 and every size is aligned" {
    resetForTest();
    defer resetForTest();

    // The first vector of the range is even, so it survives the alignment of
    // 1, 2, 4 and 8 is the first size that moves it.
    try testing.expectEqual(@as(u64, 68), try plan(1));
    try testing.expectEqual(@as(u64, 68), try plan(2));
    try testing.expectEqual(@as(u64, 68), try plan(4));
    try testing.expectEqual(@as(u64, 72), try plan(8));
    try testing.expectEqual(@as(u64, 80), try plan(16));
    try testing.expectEqual(@as(u64, 96), try plan(32));
    try testing.expectEqual(@as(u64, 128), try plan(64));

    // The property, not only the table: a base that a device cannot express as
    // the first of N aligned messages would straddle two blocks.
    var count: u64 = 1;
    while (count <= max_block) : (count *= 2) {
        const base = try plan(count);
        try testing.expectEqual(@as(u64, 0), base % count);
        try testing.expect(base >= first_vector);
        try testing.expect(base + count <= spurious_vector);
    }
}

test "187 is not a power of two: the largest block is 64" {
    resetForTest();
    defer resetForTest();

    try testing.expectEqual(@as(u64, 64), max_block);

    // A block of 128 would have to start at 0 or 128. 128 + 128 = 256 is past
    // the spurious vector, and 0 is an exception. The refusal names the reason
    // instead of returning a base the device cannot use.
    try testing.expectError(error.CountTooLarge, plan(128));
    try testing.expectError(error.CountTooLarge, plan(256));
    try testing.expectError(error.CountNotPowerOfTwo, plan(3));
    try testing.expectError(error.CountNotPowerOfTwo, plan(0));

    // A block of 64 fits exactly once: the aligned base is 128, and the block
    // covers 128..191. A second one would start at 192 and cover 192..255 —
    // 255 is the spurious vector, so that base is 64 vectors wide only if the
    // range had one more vector than it has.
    const first = try reserve(64, "first");
    try testing.expectEqual(@as(u64, 128), first.base);
    try testing.expectError(error.Exhausted, reserve(64, "second"));

    // Below it the range still accepts smaller blocks: 68..127 is 60 vectors,
    // and a block of 32 fits at 96.
    const smaller = try reserve(32, "smaller");
    try testing.expectEqual(@as(u64, 96), smaller.base);
}

test "a reserved block leaves the free count and comes back when released" {
    resetForTest();
    defer resetForTest();

    try testing.expectEqual(capacity, freeCount());
    try testing.expectEqual(@as(u64, 0), inUse());

    const block = try reserve(4, "virtio-blk");
    try testing.expectEqual(@as(u64, 68), block.base);
    try testing.expectEqual(@as(u64, 4), inUse());
    try testing.expectEqual(capacity - 4, freeCount());
    try testing.expectEqual(@as(u64, 1), blockCount());
    try testing.expect(isReserved(68));
    try testing.expect(isReserved(71));
    try testing.expect(!isReserved(72));

    // The next block of the same size starts after the first one.
    const next = try reserve(4, "virtio-net");
    try testing.expectEqual(@as(u64, 72), next.base);
    try testing.expectEqual(@as(u64, 8), inUse());

    try testing.expect(release(block));
    try testing.expectEqual(@as(u64, 4), inUse());
    try testing.expect(!isReserved(68));
    try testing.expectEqual(@as(u64, 1), blockCount());

    // Releasing the same grant twice is refused, not counted twice: a second
    // free would give the next driver a vector still in use.
    try testing.expect(!release(block));
    try testing.expectEqual(@as(u64, 4), inUse());

    try testing.expect(release(next));
    try testing.expectEqual(capacity, freeCount());
}

test "reserving gives no owner; installing does, and the gap is counted" {
    resetForTest();
    defer resetForTest();

    const block = try reserve(2, "virtio-blk");
    try testing.expect(registry.deviceName(block.base) == null);
    try testing.expect(registry.deviceName(block.base + 1) == null);

    // A message that arrives between the reservation and the installation finds
    // no owner: it is counted, and it is not dispatched to the driver that is
    // still setting up.
    try testing.expect(!registry.dispatchDevice(block.base));
    try testing.expectEqual(@as(u64, 1), registry.unhandledDeviceCount());

    try install(block, testHandler);
    try testing.expectEqual(@as(u64, 2), registry.registeredDeviceVectors());
    try testing.expectEqualStrings("virtio-blk", registry.deviceName(block.base).?);
    try testing.expectEqualStrings("virtio-blk", registry.deviceName(block.base + 1).?);
    try testing.expectEqualStrings("virtio-blk", holderOf(block.base + 1).?);

    // The handler of this block answers "do not preempt", and the dispatcher
    // returns that answer instead of inventing one — the counter is what shows
    // that the vector reached its owner.
    try testing.expect(!registry.dispatchDevice(block.base + 1));
    try testing.expectEqual(@as(u64, 1), registry.deviceInterruptCount(block.base + 1));
    try testing.expectEqual(@as(u64, 0), registry.deviceInterruptCount(block.base));
    try testing.expectEqual(@as(u64, 1), registry.unhandledDeviceCount());
}

test "installing is all or nothing when a vector already has an owner" {
    resetForTest();
    defer resetForTest();

    const block = try reserve(4, "late");
    // Somebody registered the second vector of the block by hand.
    try registry.registerDevice(block.base + 1, "manual", testHandler);

    try testing.expectError(error.VectorBusy, install(block, testHandler));

    // The vectors the installation reached were given back: the block is
    // reserved and ownerless, not half installed.
    try testing.expectEqual(@as(u64, 1), registry.registeredDeviceVectors());
    try testing.expect(registry.deviceName(block.base) == null);
    try testing.expect(registry.deviceName(block.base + 2) == null);
    try testing.expectEqual(@as(u64, 4), inUse());
}

test "a reserved vector is not handed to a second driver" {
    resetForTest();
    defer resetForTest();

    const first = try reserve(8, "first");
    const second = try reserve(8, "second");
    try testing.expectEqual(first.base + 8, second.base);

    // A block that overlaps either of them is not free, whatever its size.
    try testing.expect(!blockFree(first.base, 16));

    // A vector registered outside the pool blocks the block that contains it.
    try registry.registerDevice(200, "manual", testHandler);
    try testing.expect(!blockFree(192, 16));
    const far = try reserve(8, "far");
    // 84..87 are not an aligned block of eight, 88 is; the reserved 200 is far
    // above it and does not block this one.
    try testing.expectEqual(@as(u64, 88), far.base);
}

test "an MSI-X table takes one vector per entry, adjacent or not" {
    resetForTest();
    defer resetForTest();

    // MSI-X does not require a block: each entry carries its own message and
    // its own vector, so four entries are four reservations of one.
    var vectors: [4]u64 = undefined;
    for (&vectors) |*vector| {
        const grant = try reserve(1, "virtio-blk");
        vector.* = grant.base;
        try install(grant, testHandler);
    }
    try testing.expectEqual(@as(u64, 68), vectors[0]);
    try testing.expectEqual(@as(u64, 71), vectors[3]);

    // Four blocks of one, four owners — the registry gives each vector its own
    // counter, which is the reason a device with four queues wants MSI-X.
    try testing.expectEqual(@as(u64, 4), blockCount());
    try testing.expectEqual(@as(u64, 4), registry.registeredDeviceVectors());

    // And an MSI that asks for four contiguous vectors after that gets the next
    // aligned base, because 68..71 are taken one by one.
    const block = try reserve(4, "msi");
    try testing.expectEqual(@as(u64, 72), block.base);

    try testing.expect(release(block));
    for (vectors) |vector| {
        try testing.expect(release(.{ .base = vector, .count = 1 }));
    }
    try testing.expectEqual(@as(u64, 0), registry.registeredDeviceVectors());
    try testing.expectEqual(capacity, freeCount());
}

test "a grant with the wrong base or count frees nothing" {
    resetForTest();
    defer resetForTest();

    const block = try reserve(4, "virtio-blk");
    try testing.expectError(error.NotReserved, install(.{ .base = block.base + 1, .count = 4 }, testHandler));
    try testing.expectError(error.NotReserved, install(.{ .base = block.base, .count = 8 }, testHandler));

    try testing.expect(!release(.{ .base = block.base + 1, .count = 4 }));
    try testing.expect(!release(.{ .base = block.base, .count = 8 }));
    try testing.expectEqual(@as(u64, 4), inUse());

    // A vector outside the range is not a grant either.
    try testing.expect(!release(.{ .base = 0, .count = 1 }));
    try testing.expect(!release(.{ .base = spurious_vector, .count = 1 }));
}
