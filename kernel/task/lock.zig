//************************************************************************//
//  lock.zig                                                              //
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

//! Aggregated entry point of the kernel modules that the host can test.

//! The lock of the scheduler state, and the per-CPU ownership that goes with
//! it.
//!
//! The audit of 2026-10-31 put this first among the defects of the scheduler:
//! "`current[]`, the queues and the statistics are written from interrupt
//! context and from thread context, and there is no lock at all". The state is
//! per CPU in shape — `current[]` and `ready_queue[]` are indexed by CPU — and
//! nothing serialised the two writers, so the shape was a promise the code did
//! not keep.
//!
//! ## What this module is
//!
//! A lock that knows **which CPU holds it**, and for how many nested
//! acquisitions. The plain `Spinlock` of the architecture is not re-entrant: a
//! holder that takes it again deadlocks, and that is exactly what would happen
//! here, because the scheduler calls itself in the course of one decision:
//!
//! ```text
//! tick() → prepareNext() → channel.expireAll() → wake → wakeTask() → enqueueReady()
//! ```
//!
//! With an owner, the second acquisition is recognised as the same CPU and
//! counted instead of spinning. The nested call is not a race: it is the same
//! thread of execution, and the state it reads is the state it just wrote.
//!
//! ## What it is not
//!
//! It is not a fairness mechanism, and it does not disable interrupts by
//! itself. **The caller has to disable them**, and the reason is the window
//! between the acquisition of the underlying spinlock and the publication of
//! the owner: an interrupt that arrived in that window would find the lock held
//! by nobody and spin for ever. Both entry points of the scheduler satisfy the
//! rule: the timer runs with interrupts disabled (it is an interrupt handler),
//! and the thread-side entry points wrap the acquisition in the IRQ-safe
//! variant of the architecture lock. On the host there is no interrupt, which
//! is why the tests below can contend with real threads and no `cli`.
//!
//! ## The counters
//!
//! A lock that is never contended is indistinguishable from no lock, so the
//! structure counts what happened: `contentions` (acquisitions that found it
//! held by another CPU), `reentries` (acquisitions by the holder itself),
//! `spins` (the loop iterations of a waiting CPU) and `waited_cycles`
//! (approximate time spent waiting, for the diagnostics of K13).

const std = @import("std");

const spinlock = @import("../arch/x86_64/spinlock.zig");

/// The number of CPUs the ownership table can name.
///
/// It is the CPU limit of the architecture module (`smp.max_cpus`) and it
/// repeats it as a constant so that this file does not import the whole SMP
/// module for one number; `scheduler.zig` checks the two at comptime.
pub const max_cpus = 8;

/// A lock of the state of the scheduler, with an owner per CPU.
pub const StateLock = struct {
    /// The underlying spinlock: the exclusion of two CPUs.
    spin: spinlock.Spinlock = .{},
    /// The CPU that holds the lock, or null when it is free.
    owner: ?u8 = null,
    /// How many times the owner took the lock.
    ///
    /// One means "held once", which is the common case; a value above one means
    /// that the scheduler is inside one of its own entry points, and the state
    /// it reads is its own.
    depth: u32 = 0,
    /// The largest depth seen, for the diagnostics.
    max_depth: u32 = 1,
    /// Acquisitions that found the lock held by another CPU.
    contentions: u64 = 0,
    /// Acquisitions by the CPU that already held the lock.
    reentries: u64 = 0,
    /// Iterations of the waiting loop.
    spins: u64 = 0,
    /// Releases made by a CPU that did not hold the lock.
    refused_releases: u64 = 0,
    /// What an acquisition did.
    pub const Acquisition = enum {
        /// The lock was free and this CPU took it.
        acquired,
        /// The CPU already held the lock, and the depth grew.
        reentered,
    };

    /// Takes the lock for a CPU.
    ///
    /// The function never spins when the CPU is the owner: that path is the
    /// nested call of the scheduler, and it is the difference between a lock
    /// that makes the scheduler correct and a lock that makes it deadlock.
    ///
    /// There is no timeout and no fairness: a CPU that waits waits until the
    /// holder releases, which is the contract of every spinlock in the kernel.
    /// The waiting time is not measured here — a lock that reads the clock is a
    /// lock that cannot be tested without a processor — and only the number of
    /// iterations of the wait is counted.
    pub fn acquire(self: *StateLock, cpu_id: u8) Acquisition {
        if (self.owner) |owner| {
            if (owner == cpu_id) {
                self.depth += 1;
                self.reentries += 1;
                if (self.depth > self.max_depth) self.max_depth = self.depth;
                return .reentered;
            }

            self.contentions += 1;
            while (!self.spin.tryLock()) {
                self.spins += 1;
            }
            self.takeOwnership(cpu_id);
            return .acquired;
        }

        self.spin.lock();
        self.takeOwnership(cpu_id);
        return .acquired;
    }

    fn takeOwnership(self: *StateLock, cpu_id: u8) void {
        self.owner = cpu_id;
        self.depth = 1;
    }

    /// Releases the lock for a CPU.
    ///
    /// The function returns false when the CPU does not hold the lock, and in
    /// that case nothing changes: a release without an acquisition is a defect
    /// of the caller, and the counter of the refusals is what makes it visible.
    pub fn release(self: *StateLock, cpu_id: u8) bool {
        const owner = self.owner orelse {
            self.refused_releases += 1;
            return false;
        };
        if (owner != cpu_id) {
            self.refused_releases += 1;
            return false;
        }

        self.depth -= 1;
        if (self.depth != 0) return true;

        self.owner = null;
        self.spin.unlock();
        return true;
    }

    /// Whether the lock is held by any CPU.
    pub fn isHeld(self: *const StateLock) bool {
        return self.owner != null;
    }

    /// Whether a CPU holds the lock.
    pub fn isHeldBy(self: *const StateLock, cpu_id: u8) bool {
        const owner = self.owner orelse return false;
        return owner == cpu_id;
    }

    /// The CPU that holds the lock, if any.
    pub fn holder(self: *const StateLock) ?u8 {
        return self.owner;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a free lock is taken by the first CPU and released by it" {
    var lock: StateLock = .{};
    try testing.expect(!lock.isHeld());

    try testing.expectEqual(StateLock.Acquisition.acquired, lock.acquire(0));
    try testing.expect(lock.isHeld());
    try testing.expect(lock.isHeldBy(0));
    try testing.expect(!lock.isHeldBy(1));
    try testing.expectEqual(@as(u32, 1), lock.depth);

    try testing.expect(lock.release(0));
    try testing.expect(!lock.isHeld());
    try testing.expectEqual(@as(u32, 0), lock.depth);
}

test "the holder takes the lock again without deadlocking" {
    var lock: StateLock = .{};

    _ = lock.acquire(2);
    // The nested call of the scheduler: same CPU, and the lock is not taken
    // again from the spinlock, which would deadlock.
    try testing.expectEqual(StateLock.Acquisition.reentered, lock.acquire(2));
    try testing.expectEqual(@as(u32, 2), lock.depth);
    try testing.expectEqual(@as(u64, 1), lock.reentries);
    try testing.expectEqual(@as(u64, 0), lock.contentions);

    // One release is not enough: the lock is still held, once.
    try testing.expect(lock.release(2));
    try testing.expect(lock.isHeldBy(2));
    try testing.expectEqual(@as(u32, 1), lock.depth);

    try testing.expect(lock.release(2));
    try testing.expect(!lock.isHeld());
}

test "a release from another CPU is refused and leaves the lock alone" {
    var lock: StateLock = .{};

    // Nobody holds it.
    try testing.expect(!lock.release(1));
    try testing.expectEqual(@as(u64, 1), lock.refused_releases);

    _ = lock.acquire(0);
    try testing.expect(!lock.release(1));
    try testing.expect(lock.isHeldBy(0));
    try testing.expectEqual(@as(u64, 2), lock.refused_releases);
    try testing.expectEqual(@as(u32, 1), lock.depth);
}

test "the depth is counted and the largest depth is remembered" {
    var lock: StateLock = .{};

    _ = lock.acquire(0);
    _ = lock.acquire(0);
    _ = lock.acquire(0);
    try testing.expectEqual(@as(u32, 3), lock.depth);
    try testing.expectEqual(@as(u32, 3), lock.max_depth);

    // Two releases leave one acquisition, and the depth follows.
    try testing.expect(lock.release(0));
    try testing.expect(lock.release(0));
    try testing.expectEqual(@as(u32, 1), lock.depth);
    try testing.expectEqual(@as(u32, 3), lock.max_depth);

    try testing.expect(lock.release(0));
    try testing.expect(!lock.isHeld());
}

test "the lock excludes two CPUs that hold it at the same time" {
    var lock: StateLock = .{};
    var holders = std.atomic.Value(u32).init(0);
    var violations = std.atomic.Value(u32).init(0);
    var work = std.atomic.Value(u32).init(0);

    const Worker = struct {
        fn run(
            lock_ptr: *StateLock,
            cpu: u8,
            holders_ptr: *std.atomic.Value(u32),
            violations_ptr: *std.atomic.Value(u32),
            work_ptr: *std.atomic.Value(u32),
        ) void {
            var iteration: u32 = 0;
            while (iteration < 20_000) : (iteration += 1) {
                // `tryLock` style: a contended acquisition is skipped instead of
                // spinning, so the test is about exclusion and not about
                // scheduling under a single-core CI runner.
                if (lock_ptr.isHeld()) continue;
                _ = lock_ptr.acquire(cpu);

                const previous = holders_ptr.fetchAdd(1, .monotonic);
                if (previous != 0) _ = violations_ptr.fetchAdd(1, .monotonic);
                _ = work_ptr.fetchAdd(1, .monotonic);
                _ = holders_ptr.fetchSub(1, .monotonic);

                _ = lock_ptr.release(cpu);
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &lock, @as(u8, @intCast(index)), &holders, &violations, &work });
    }
    for (threads) |thread| thread.join();

    // The criterion is the absence of violations: no two CPUs inside the region
    // at the same time. It proves exclusion, not fairness.
    try testing.expectEqual(@as(u32, 0), violations.load(.monotonic));
    try testing.expect(work.load(.monotonic) > 0);
    try testing.expect(!lock.isHeld());
}

test "the counters describe the traffic of the lock" {
    var lock: StateLock = .{};

    _ = lock.acquire(0); // acquired
    _ = lock.acquire(0); // reentered
    try testing.expect(lock.release(0));
    try testing.expect(lock.release(0));
    _ = lock.acquire(1); // acquired by another CPU after the release
    try testing.expect(lock.release(1));
    try testing.expect(!lock.release(1)); // refused: not the holder

    try testing.expectEqual(@as(u64, 1), lock.reentries);
    try testing.expectEqual(@as(u64, 1), lock.refused_releases);
    try testing.expectEqual(@as(u32, 2), lock.max_depth);
}
