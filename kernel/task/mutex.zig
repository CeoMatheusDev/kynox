//************************************************************************//
//  mutex.zig                                                             //
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

//! A mutex that sleeps: ownership, recursion, and a direct handoff to the next
//! waiter.
//!
//! The kernel had a spinlock and a counting semaphore and nothing else (audit
//! §C.5), and a semaphore is not a mutex: it has no owner, so any task can
//! release it, it cannot be taken recursively, and a task that gives up while
//! it waits takes a wakeup that belonged to nobody. This module is the mutex of
//! K3.7 in the completion roadmap: an owner, a recursion count, a queue of
//! sleepers, and a release that hands the ownership to the next waiter
//! **before** it wakes it.
//!
//! What it is not: it does not block. `take` answers `busy`, and the caller
//! decides what to do with that; the blocking half is the scheduler, which owns
//! the state of the task. Keeping the mutex free of the scheduler is what makes
//! it testable on the host, and the contract of the pair is small enough to
//! state:
//!
//! ```text
//! while (true) {
//!     switch (mutex.take(task)) {
//!         .acquired, .recursive => break,           // the mutex is ours
//!         .busy => {
//!             _ = mutex.waitFor(&node);             // our node, our stack
//!             if (!scheduler.blockCurrentOn(&mutex.waiters)) {
//!                 _ = mutex.waiters.remove(&node);  // no one to switch to
//!                 return error.WouldBlock;
//!             }
//!         },
//!         .recursion_overflow => return error.TooManyLocks,
//!     }
//! }
//! ```
//!
//! The `waitFor` of the code above does not use the remembered wake of the wait
//! queue, and it must not: the ownership is transferred at release time, so a
//! wake that arrived before the waiter would name nobody. A waiter that was
//! already handed the ownership finds `.busy` false on the next `take`, because
//! the owner is the waiter itself.
//!
//! The blocking helper named above (`scheduler.blockCurrentOn`) does not exist
//! yet, and this file does not pretend that it does. Until it lands, the mutex
//! is a tested policy module with no caller in the kernel: the same status as
//! `policy.zig`, and the reason the synchronisation row of the status file does
//! not claim integration.

const std = @import("std");
const wait = @import("wait.zig");

/// The largest recursion depth of one task.
///
/// The limit is the point at which a recursive take is refused instead of
/// wrapping the counter: a task that takes the same mutex 255 times has a
/// defect, and an unbounded counter would hide it.
pub const max_recursion: u8 = 255;

/// A mutex with an owner.
pub const Mutex = struct {
    /// The task that holds the mutex, or null when nobody does.
    owner: ?*anyopaque = null,
    /// How many times the owner took the mutex.
    ///
    /// Zero exactly when `owner` is null; the two fields are never out of step.
    recursion: u8 = 0,
    /// The tasks that wait for the mutex.
    waiters: wait.WaitQueue = .{},
    /// The takes that succeeded, recursive ones included.
    acquisitions: u64 = 0,
    /// The releases that were accepted.
    releases: u64 = 0,
    /// The takes that found the mutex held by another task.
    contentions: u64 = 0,
    /// The releases that handed the mutex to a waiter.
    handoffs: u64 = 0,
    /// The calls that were refused: a release by a non-owner, a recursion
    /// overflow.
    refused: u64 = 0,

    /// What `take` did.
    pub const Take = enum {
        /// The mutex was free and the task is the owner now.
        acquired,
        /// The task already owned the mutex, and the recursion count grew.
        recursive,
        /// Another task owns the mutex; the caller has to wait.
        busy,
        /// The recursion limit was reached, and nothing changed.
        recursion_overflow,
    };

    /// What `release` did.
    pub const Release = enum {
        /// The mutex is free again.
        unlocked,
        /// The owner released one level of its recursion and still holds it.
        still_locked,
        /// The ownership moved to the next waiter, which was woken.
        handed_off,
        /// The caller does not own the mutex, and nothing changed.
        not_owner,
    };

    /// Takes the mutex, or reports why it cannot.
    pub fn take(self: *Mutex, task: *anyopaque) Take {
        if (self.owner) |owner| {
            if (owner == task) {
                if (self.recursion == max_recursion) {
                    self.refused += 1;
                    return .recursion_overflow;
                }
                self.recursion += 1;
                self.acquisitions += 1;
                return .recursive;
            }

            self.contentions += 1;
            return .busy;
        }

        self.owner = task;
        self.recursion = 1;
        self.acquisitions += 1;
        return .acquired;
    }

    /// Registers a node of a waiting task for the handoff.
    ///
    /// The queue is the one of the mutex, so the order of the handoff is the
    /// order in which the tasks gave up: a task that arrived first is served
    /// first. The result is the one of the wait queue, and an
    /// `.already_woken` answer means that the caller has to retry `take`
    /// instead of sleeping.
    pub fn waitFor(self: *Mutex, node: *wait.Node) wait.AddResult {
        return self.waiters.add(node);
    }

    /// Gives up the wait of a node, for a caller that timed out.
    ///
    /// The function returns true when the node was still waiting. It is the
    /// counterpart of `waitFor`, and it must run before the caller returns the
    /// error of a timeout: a node that stays in the queue is a handoff to a task
    /// that is not waiting any more.
    pub fn giveUp(self: *Mutex, node: *wait.Node) bool {
        return self.waiters.remove(node);
    }

    /// Releases the mutex, one recursion level at a time.
    pub fn release(self: *Mutex, task: *anyopaque) Release {
        const owner = self.owner orelse {
            self.refused += 1;
            return .not_owner;
        };
        if (owner != task) {
            self.refused += 1;
            return .not_owner;
        }

        self.releases += 1;

        if (self.recursion > 1) {
            self.recursion -= 1;
            return .still_locked;
        }

        // The ownership moves **before** the wake: a waiter that is woken
        // already owns the mutex, so no third task can take it in the interval,
        // and the waiter does not have to try again.
        if (self.waiters.detachHead()) |node| {
            self.owner = node.task;
            self.recursion = 1;
            self.handoffs += 1;
            node.wake(node.task);
            return .handed_off;
        }

        self.owner = null;
        self.recursion = 0;
        return .unlocked;
    }

    /// Whether the mutex is free.
    pub fn isFree(self: *const Mutex) bool {
        return self.owner == null;
    }

    /// Whether the task owns the mutex.
    pub fn isOwnedBy(self: *const Mutex, task: *anyopaque) bool {
        const owner = self.owner orelse return false;
        return owner == task;
    }

    /// The number of tasks that wait for the mutex.
    pub fn waiting(self: *const Mutex) u32 {
        return self.waiters.length();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The task of the tests: it counts its wakes and records whether the mutex was
/// already its own when the wake arrived.
const FakeTask = struct {
    id: u32,
    wakes: u32 = 0,
    owned_at_wake: bool = false,
    mutex: ?*Mutex = null,
};

fn wakeFake(task: *anyopaque) void {
    const fake: *FakeTask = @ptrCast(@alignCast(task));
    fake.wakes += 1;
    if (fake.mutex) |mutex| fake.owned_at_wake = mutex.isOwnedBy(fake);
}

fn nodeForTask(fake: *FakeTask) wait.Node {
    return wait.Node.init(fake, wakeFake);
}

fn taskOf(id: u32, mutex: *Mutex) FakeTask {
    return .{ .id = id, .mutex = mutex };
}

test "a free mutex is taken by the first task" {
    var mutex: Mutex = .{};
    var first = taskOf(1, &mutex);

    try testing.expect(mutex.isFree());
    try testing.expectEqual(Mutex.Take.acquired, mutex.take(&first));
    try testing.expect(!mutex.isFree());
    try testing.expect(mutex.isOwnedBy(&first));
    try testing.expectEqual(@as(u8, 1), mutex.recursion);
    try testing.expectEqual(@as(u64, 1), mutex.acquisitions);
}

test "a second task is told that the mutex is busy" {
    var mutex: Mutex = .{};
    var first = taskOf(1, &mutex);
    var second = taskOf(2, &mutex);

    _ = mutex.take(&first);
    try testing.expectEqual(Mutex.Take.busy, mutex.take(&second));
    try testing.expect(mutex.isOwnedBy(&first));
    try testing.expectEqual(@as(u64, 1), mutex.contentions);
    try testing.expectEqual(@as(u64, 1), mutex.acquisitions);
}

test "the owner takes the mutex again and the recursion count says so" {
    var mutex: Mutex = .{};
    var first = taskOf(1, &mutex);

    _ = mutex.take(&first);
    try testing.expectEqual(Mutex.Take.recursive, mutex.take(&first));
    try testing.expectEqual(@as(u8, 2), mutex.recursion);

    // One release is not enough: the mutex is still held.
    try testing.expectEqual(Mutex.Release.still_locked, mutex.release(&first));
    try testing.expectEqual(@as(u8, 1), mutex.recursion);
    try testing.expect(mutex.isOwnedBy(&first));

    try testing.expectEqual(Mutex.Release.unlocked, mutex.release(&first));
    try testing.expect(mutex.isFree());
    try testing.expectEqual(@as(u8, 0), mutex.recursion);
}

test "a task that does not own the mutex cannot release it" {
    var mutex: Mutex = .{};
    var first = taskOf(1, &mutex);
    var second = taskOf(2, &mutex);

    // Nobody owns it.
    try testing.expectEqual(Mutex.Release.not_owner, mutex.release(&second));
    try testing.expectEqual(@as(u64, 1), mutex.refused);

    _ = mutex.take(&first);
    try testing.expectEqual(Mutex.Release.not_owner, mutex.release(&second));
    try testing.expect(mutex.isOwnedBy(&first));
    try testing.expectEqual(@as(u64, 2), mutex.refused);
    try testing.expectEqual(@as(u64, 0), mutex.releases);
}

test "the release hands the mutex over before it wakes the waiter" {
    var mutex: Mutex = .{};
    var first = taskOf(1, &mutex);
    var second = taskOf(2, &mutex);

    var first_node = nodeForTask(&first);
    var second_node = nodeForTask(&second);
    _ = &first_node;

    _ = mutex.take(&first);
    try testing.expectEqual(Mutex.Take.busy, mutex.take(&second));
    try testing.expectEqual(wait.AddResult.queued, mutex.waitFor(&second_node));

    try testing.expectEqual(Mutex.Release.handed_off, mutex.release(&first));

    // The waiter already owns the mutex when its wake routine runs: no third
    // task can take it in the interval, and the waiter does not retry.
    try testing.expectEqual(@as(u32, 1), second.wakes);
    try testing.expect(second.owned_at_wake);
    try testing.expect(mutex.isOwnedBy(&second));
    try testing.expectEqual(@as(u8, 1), mutex.recursion);
    try testing.expectEqual(@as(u64, 1), mutex.handoffs);
    try testing.expectEqual(@as(u32, 0), mutex.waiting());
}

test "the waiters are served in the order they queued" {
    var mutex: Mutex = .{};
    var owner = taskOf(0, &mutex);
    var first = taskOf(1, &mutex);
    var second = taskOf(2, &mutex);
    var third = taskOf(3, &mutex);

    var first_node = nodeForTask(&first);
    var second_node = nodeForTask(&second);
    var third_node = nodeForTask(&third);

    _ = mutex.take(&owner);
    _ = mutex.waitFor(&first_node);
    _ = mutex.waitFor(&second_node);
    _ = mutex.waitFor(&third_node);
    try testing.expectEqual(@as(u32, 3), mutex.waiting());

    try testing.expectEqual(Mutex.Release.handed_off, mutex.release(&owner));
    try testing.expect(mutex.isOwnedBy(&first));

    try testing.expectEqual(Mutex.Release.handed_off, mutex.release(&first));
    try testing.expect(mutex.isOwnedBy(&second));

    try testing.expectEqual(Mutex.Release.handed_off, mutex.release(&second));
    try testing.expect(mutex.isOwnedBy(&third));

    try testing.expectEqual(Mutex.Release.unlocked, mutex.release(&third));
    try testing.expect(mutex.isFree());
    try testing.expectEqual(@as(u64, 3), mutex.handoffs);
}

test "a waiter that gave up is not handed the mutex" {
    var mutex: Mutex = .{};
    var owner = taskOf(0, &mutex);
    var quitter = taskOf(1, &mutex);
    var patient = taskOf(2, &mutex);

    var quitter_node = nodeForTask(&quitter);
    var patient_node = nodeForTask(&patient);

    _ = mutex.take(&owner);
    _ = mutex.waitFor(&quitter_node);
    _ = mutex.waitFor(&patient_node);

    // The quitter timed out and left the queue before the release.
    try testing.expect(mutex.giveUp(&quitter_node));
    try testing.expectEqual(@as(u32, 0), quitter.wakes);

    try testing.expectEqual(Mutex.Release.handed_off, mutex.release(&owner));
    try testing.expect(mutex.isOwnedBy(&patient));
    try testing.expectEqual(@as(u32, 0), quitter.wakes);
    try testing.expectEqual(@as(u32, 1), patient.wakes);
}

test "a wait that ends by its deadline leaves the queue for the caller" {
    var mutex: Mutex = .{};
    var owner = taskOf(0, &mutex);
    var unlucky = taskOf(1, &mutex);
    var patient = taskOf(2, &mutex);

    var unlucky_node = nodeForTask(&unlucky);
    var patient_node = nodeForTask(&patient);
    unlucky_node.deadline = 3;

    _ = mutex.take(&owner);
    _ = mutex.waitFor(&unlucky_node);
    _ = mutex.waitFor(&patient_node);

    // The timer expires the wait: the node leaves the queue and its task is
    // woken with the flag that says why.
    try testing.expectEqual(@as(u32, 1), mutex.waiters.expire(3));
    try testing.expect(unlucky_node.expired);
    try testing.expectEqual(@as(u32, 1), mutex.waiting());

    // The timeout is not a handoff: the owner still owns the mutex, and the
    // give-up of the caller is already done.
    try testing.expect(mutex.isOwnedBy(&owner));
    try testing.expect(!mutex.giveUp(&unlucky_node));

    // The release goes to the task that is still waiting.
    try testing.expectEqual(Mutex.Release.handed_off, mutex.release(&owner));
    try testing.expect(mutex.isOwnedBy(&patient));
}

test "a recursion above the limit is refused instead of wrapping" {
    var mutex: Mutex = .{};
    var first = taskOf(1, &mutex);

    _ = mutex.take(&first);
    mutex.recursion = max_recursion;

    try testing.expectEqual(Mutex.Take.recursion_overflow, mutex.take(&first));
    try testing.expectEqual(max_recursion, mutex.recursion);
    try testing.expectEqual(@as(u64, 1), mutex.refused);
}

test "the counters describe the traffic of the mutex" {
    var mutex: Mutex = .{};
    var first = taskOf(1, &mutex);
    var second = taskOf(2, &mutex);

    var second_node = nodeForTask(&second);

    _ = mutex.take(&first); // acquisition
    _ = mutex.take(&second); // contention
    _ = mutex.waitFor(&second_node);
    _ = mutex.release(&first); // handoff
    _ = mutex.release(&second); // unlock

    try testing.expectEqual(@as(u64, 1), mutex.acquisitions);
    try testing.expectEqual(@as(u64, 1), mutex.contentions);
    try testing.expectEqual(@as(u64, 2), mutex.releases);
    try testing.expectEqual(@as(u64, 1), mutex.handoffs);
    try testing.expectEqual(@as(u64, 0), mutex.refused);
    try testing.expect(mutex.isFree());
}
