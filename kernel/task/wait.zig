//************************************************************************//
//  wait.zig                                                              //
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

//! A queue of tasks that wait for a condition.
//!
//! The module replaces the stub that carried this name until 2026-11-01. The
//! stub cast the pointer of a task to a `WaitRecord` and wrote `next` into the
//! task object itself, `dequeueWaiter` returned a field that nothing ever set,
//! and no test reached it. What is below is the queue that the roadmap asks for
//! in K3.6: the standard predicate loop, a deadline on every wait, and no lost
//! wakeup.
//!
//! What it is: an intrusive list of caller-owned nodes, FIFO, with a deadline
//! and with wakeup accounting. What it is not: a scheduler. The node names the
//! task and the routine that makes it ready; the queue never blocks anything
//! and never touches a context. `scheduler.zig` and the caller own that half,
//! which is why this file has no hardware dependency and is tested on the host.
//!
//! ## The lost wakeup, and how it is avoided here
//!
//! The classic defect is a wake that arrives between the predicate check and
//! the sleep: the waiter checks "is the queue empty?", finds it empty, and the
//! producer stores the message and wakes nobody, and then the waiter sleeps
//! forever. The caller cannot close the gap by itself, because the gap is
//! between two steps of the caller.
//!
//! The queue closes it with one counter: a wake that finds no waiter is
//! **remembered** in `pending_wakes`, and the next waiter that arrives consumes
//! it and is told so (`AddResult.already_woken`). The waiter then re-checks its
//! predicate and does not sleep. The rule for the caller is therefore:
//!
//! 1. check the predicate with the producer excluded;
//! 2. call `add`; if it answers `.already_woken`, the event may have happened:
//!    go back to step 1 instead of sleeping;
//! 3. if it answers `.queued`, sleep; the wake that arrives later takes the
//!    node out of the queue and calls `wake`.
//!
//! The mutex in `mutex.zig` does not use the remembered wake: it hands the
//! ownership over before it wakes the waiter, so a wake cannot arrive before
//! the wait.

const std = @import("std");

/// A task that waits in a queue.
///
/// The node belongs to the caller and never to the queue: the kernel puts one
/// in the task (or on the stack of the caller), so a wait never allocates, and
/// the timer path can wake a waiter without a heap.
pub const Node = struct {
    /// The task that waits, given back to `wake` untouched.
    task: *anyopaque,
    /// The routine that makes the task ready again.
    wake: *const fn (task: *anyopaque) void,
    /// The deadline of the wait, in ticks of the scheduler.
    ///
    /// Zero means that the wait has no deadline and only a wake or a removal
    /// ends it.
    deadline: u64 = 0,
    /// The next waiter, towards the tail.
    next: ?*Node = null,
    /// The previous waiter, towards the head.
    prev: ?*Node = null,
    /// Whether the node is in a queue right now.
    queued: bool = false,
    /// Whether a wake already reached this node.
    ///
    /// The flag outlives the wait: the caller can tell a wait that was woken
    /// from a wait that was removed or that expired.
    woken: bool = false,
    /// Whether the wait ended because its deadline passed.
    expired: bool = false,

    /// Prepares a node for a wait.
    pub fn init(task: *anyopaque, wake: *const fn (task: *anyopaque) void) Node {
        return .{ .task = task, .wake = wake };
    }
};

/// What `WaitQueue.add` did with a node.
pub const AddResult = enum {
    /// The node is in the queue, and the caller may sleep.
    queued,
    /// A wake arrived before the node did. The node is **not** in the queue and
    /// the caller has to re-check its predicate.
    already_woken,
    /// The node was already in a queue, and nothing changed. A task that waits
    /// for two things at once is a defect of the caller.
    already_queued,
};

/// A FIFO queue of waiters.
pub const WaitQueue = struct {
    /// The first waiter, which is the one a wake takes.
    head: ?*Node = null,
    /// The last waiter.
    tail: ?*Node = null,
    /// The number of waiters in the queue.
    count: u32 = 0,
    /// The wakes that arrived with no waiter to take them.
    pending_wakes: u32 = 0,
    /// The waits that ended with a wake.
    woken: u64 = 0,
    /// The waits that ended because their deadline passed.
    expired: u64 = 0,
    /// The waits that the caller removed.
    cancelled: u64 = 0,

    /// Puts a waiter at the end of the queue.
    pub fn add(self: *WaitQueue, node: *Node) AddResult {
        if (node.queued) return .already_queued;

        // The wake that arrived before the waiter: the waiter is told, and it
        // re-checks its predicate instead of sleeping.
        if (self.pending_wakes > 0) {
            self.pending_wakes -= 1;
            node.woken = true;
            return .already_woken;
        }

        node.next = null;
        node.prev = self.tail;
        node.queued = true;
        node.woken = false;
        node.expired = false;

        if (self.tail) |tail| {
            tail.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;
        self.count += 1;

        return .queued;
    }

    /// Takes a waiter out of the queue without waking it.
    ///
    /// The function returns true when the node was in this queue. It counts as
    /// a cancellation, which is what a caller does when it gave up on the wait
    /// by itself.
    pub fn remove(self: *WaitQueue, node: *Node) bool {
        if (!node.queued) return false;

        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.head = node.next;
        }

        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.tail = node.prev;
        }

        node.next = null;
        node.prev = null;
        node.queued = false;
        self.count -= 1;
        self.cancelled += 1;

        return true;
    }

    /// Takes the first waiter out of the queue and wakes it.
    ///
    /// The function returns the node it woke, or null when the queue was empty,
    /// in which case the wake is remembered for the next waiter.
    pub fn wakeOne(self: *WaitQueue) ?*Node {
        if (self.head == null) {
            if (self.pending_wakes != std.math.maxInt(u32)) self.pending_wakes += 1;
            return null;
        }
        return self.popAndWake();
    }

    /// Takes the first waiter out of the queue without waking it.
    ///
    /// The node leaves marked as woken and counted as such, and the caller owns
    /// the wake. The split exists for the direct handoff: the owner of a
    /// resource has to give it to the waiter **before** the waiter runs, and a
    /// wake that ran first would let the waiter find the resource still held.
    /// `popAndWake` is this function plus the wake.
    pub fn detachHead(self: *WaitQueue) ?*Node {
        const node = self.head orelse return null;

        self.head = node.next;
        if (self.head) |head| {
            head.prev = null;
        } else {
            self.tail = null;
        }

        node.next = null;
        node.prev = null;
        node.queued = false;
        node.woken = true;
        self.count -= 1;
        self.woken += 1;

        return node;
    }

    /// Takes the first waiter out of the queue and wakes it, without the
    /// memory of a wake that found nobody.
    pub fn popAndWake(self: *WaitQueue) ?*Node {
        const node = self.detachHead() orelse return null;
        node.wake(node.task);
        return node;
    }

    /// Wakes every waiter in the queue, and returns how many it woke.
    pub fn wakeAll(self: *WaitQueue) u32 {
        var woken: u32 = 0;
        while (self.popAndWake()) |_| woken += 1;
        return woken;
    }

    /// Wakes one specific task, wherever it is in the queue.
    ///
    /// The function returns false when the task was not waiting here. Unlike
    /// `wakeOne`, an absent task does not leave a remembered wake: a targeted
    /// wake names a task, and a task that is not waiting for this queue is not
    /// waiting for this queue a moment later either.
    pub fn wakeTask(self: *WaitQueue, task: *anyopaque) bool {
        var node = self.head;
        while (node) |current| {
            if (current.task != task) {
                node = current.next;
                continue;
            }

            // The removal is written out instead of calling `remove`, because
            // a targeted wake is not a cancellation and must not count as one.
            if (current.prev) |prev| {
                prev.next = current.next;
            } else {
                self.head = current.next;
            }
            if (current.next) |next| {
                next.prev = current.prev;
            } else {
                self.tail = current.prev;
            }
            current.next = null;
            current.prev = null;
            current.queued = false;
            current.woken = true;
            self.count -= 1;
            self.woken += 1;

            current.wake(current.task);
            return true;
        }

        return false;
    }

    /// Ends the waits whose deadline has passed.
    ///
    /// A wait without a deadline never expires. The woken waiter carries
    /// `expired = true`, so that the caller can tell a timeout from a wake.
    /// The function returns how many waits it ended.
    pub fn expire(self: *WaitQueue, now: u64) u32 {
        var expired_now: u32 = 0;

        var node = self.head;
        while (node) |current| {
            // The walk continues from the successor, which the removal does not
            // touch: it keeps its own link to the following node.
            node = current.next;

            if (current.deadline == 0) continue;
            if (now < current.deadline) continue;

            if (current.prev) |prev| {
                prev.next = current.next;
            } else {
                self.head = current.next;
            }
            if (current.next) |next| {
                next.prev = current.prev;
            } else {
                self.tail = current.prev;
            }
            current.next = null;
            current.prev = null;
            current.queued = false;
            current.woken = true;
            current.expired = true;
            self.count -= 1;
            self.woken += 1;
            self.expired += 1;
            expired_now += 1;

            current.wake(current.task);
        }

        return expired_now;
    }

    /// Whether the node is in this queue.
    pub fn contains(self: *const WaitQueue, node: *const Node) bool {
        var current = self.head;
        while (current) |entry| {
            if (entry == node) return true;
            current = entry.next;
        }
        return false;
    }

    /// The number of waiters.
    pub fn length(self: *const WaitQueue) u32 {
        return self.count;
    }

    /// Whether the queue holds no waiter.
    pub fn isEmpty(self: *const WaitQueue) bool {
        return self.count == 0;
    }

    /// Whether a wake is waiting for a waiter.
    pub fn hasPendingWake(self: *const WaitQueue) bool {
        return self.pending_wakes != 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A task that only counts the wakes it receives.
const FakeTask = struct {
    id: u32,
    wakes: u32 = 0,
};

fn wakeFake(task: *anyopaque) void {
    const fake: *FakeTask = @ptrCast(@alignCast(task));
    fake.wakes += 1;
}

fn nodeForTask(fake: *FakeTask) Node {
    return Node.init(fake, wakeFake);
}

test "the waiters are woken in the order they arrived" {
    var queue: WaitQueue = .{};
    var first: FakeTask = .{ .id = 1 };
    var second: FakeTask = .{ .id = 2 };
    var third: FakeTask = .{ .id = 3 };

    var first_node = nodeForTask(&first);
    var second_node = nodeForTask(&second);
    var third_node = nodeForTask(&third);

    try testing.expectEqual(AddResult.queued, queue.add(&first_node));
    try testing.expectEqual(AddResult.queued, queue.add(&second_node));
    try testing.expectEqual(AddResult.queued, queue.add(&third_node));
    try testing.expectEqual(@as(u32, 3), queue.length());

    try testing.expectEqual(&first_node, queue.wakeOne().?);
    try testing.expectEqual(@as(u32, 1), first.wakes);
    try testing.expectEqual(&second_node, queue.wakeOne().?);
    try testing.expectEqual(@as(u32, 1), second.wakes);
    try testing.expectEqual(&third_node, queue.wakeOne().?);
    try testing.expectEqual(@as(u32, 1), third.wakes);

    try testing.expect(queue.isEmpty());
    try testing.expect(!first_node.queued);
    try testing.expect(first_node.woken);
}

test "a waiter removed from the middle leaves the order of the rest intact" {
    var queue: WaitQueue = .{};
    var first: FakeTask = .{ .id = 1 };
    var second: FakeTask = .{ .id = 2 };
    var third: FakeTask = .{ .id = 3 };

    var first_node = nodeForTask(&first);
    var second_node = nodeForTask(&second);
    var third_node = nodeForTask(&third);

    _ = queue.add(&first_node);
    _ = queue.add(&second_node);
    _ = queue.add(&third_node);

    try testing.expect(queue.remove(&second_node));
    try testing.expectEqual(@as(u32, 2), queue.length());
    try testing.expectEqual(@as(u32, 1), queue.cancelled);
    try testing.expectEqual(@as(u32, 0), second.wakes);

    try testing.expectEqual(&first_node, queue.wakeOne().?);
    try testing.expectEqual(&third_node, queue.wakeOne().?);
    try testing.expect(queue.isEmpty());
}

test "removing a node that is not waiting changes nothing" {
    var queue: WaitQueue = .{};
    var fake: FakeTask = .{ .id = 1 };
    var node = nodeForTask(&fake);

    try testing.expect(!queue.remove(&node));
    try testing.expectEqual(@as(u32, 0), queue.length());
    try testing.expectEqual(@as(u32, 0), queue.cancelled);

    _ = queue.add(&node);
    try testing.expect(queue.remove(&node));
    // The second removal finds nothing: the node already left.
    try testing.expect(!queue.remove(&node));
    try testing.expectEqual(@as(u32, 1), queue.cancelled);
}

test "a node cannot wait in two queues at once" {
    var first_queue: WaitQueue = .{};
    var second_queue: WaitQueue = .{};
    var fake: FakeTask = .{ .id = 1 };
    var node = nodeForTask(&fake);

    try testing.expectEqual(AddResult.queued, first_queue.add(&node));
    try testing.expectEqual(AddResult.already_queued, first_queue.add(&node));
    try testing.expectEqual(AddResult.already_queued, second_queue.add(&node));

    try testing.expectEqual(@as(u32, 1), first_queue.length());
    try testing.expectEqual(@as(u32, 0), second_queue.length());
    try testing.expect(first_queue.contains(&node));
    try testing.expect(!second_queue.contains(&node));
}

test "a wake that arrives before the waiter is remembered, not lost" {
    var queue: WaitQueue = .{};
    var fake: FakeTask = .{ .id = 1 };
    var node = nodeForTask(&fake);

    // The producer runs first: the queue is empty and the wake is remembered.
    try testing.expectEqual(@as(?*Node, null), queue.wakeOne());
    try testing.expectEqual(@as(u32, 1), queue.pending_wakes);
    try testing.expect(queue.hasPendingWake());

    // The waiter arrives and is told, so it can re-check its predicate instead
    // of sleeping forever.
    try testing.expectEqual(AddResult.already_woken, queue.add(&node));
    try testing.expect(queue.isEmpty());
    try testing.expect(node.woken);
    try testing.expectEqual(@as(u32, 0), queue.pending_wakes);
    try testing.expectEqual(@as(u32, 0), fake.wakes);

    // The memory was consumed by one waiter only.
    try testing.expectEqual(AddResult.queued, queue.add(&node));
    try testing.expectEqual(@as(u32, 1), queue.length());
}

test "a detached waiter is woken by its caller, not by the queue" {
    var queue: WaitQueue = .{};
    var fake: FakeTask = .{ .id = 1 };
    var node = nodeForTask(&fake);

    _ = queue.add(&node);

    const detached = queue.detachHead().?;
    try testing.expectEqual(&node, detached);
    try testing.expect(!node.queued);
    try testing.expect(node.woken);
    try testing.expect(queue.isEmpty());
    try testing.expectEqual(@as(u64, 1), queue.woken);

    // The queue did not wake it: the caller owns the wake, and it decides the
    // order between the state and the signal.
    try testing.expectEqual(@as(u32, 0), fake.wakes);
    detached.wake(detached.task);
    try testing.expectEqual(@as(u32, 1), fake.wakes);
}

test "a wake for everybody empties the queue" {
    var queue: WaitQueue = .{};
    var fakes: [4]FakeTask = .{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 }, .{ .id = 4 } };
    var nodes: [4]Node = undefined;

    for (&fakes, &nodes) |*fake, *node| {
        node.* = nodeForTask(fake);
        try testing.expectEqual(AddResult.queued, queue.add(node));
    }

    try testing.expectEqual(@as(u32, 4), queue.wakeAll());
    try testing.expect(queue.isEmpty());
    try testing.expectEqual(@as(u32, 4), queue.woken);
    for (fakes) |fake| try testing.expectEqual(@as(u32, 1), fake.wakes);
}

test "a targeted wake takes exactly the task it names" {
    var queue: WaitQueue = .{};
    var first: FakeTask = .{ .id = 1 };
    var second: FakeTask = .{ .id = 2 };
    var third: FakeTask = .{ .id = 3 };
    var absent: FakeTask = .{ .id = 4 };

    var first_node = nodeForTask(&first);
    var second_node = nodeForTask(&second);
    var third_node = nodeForTask(&third);

    _ = queue.add(&first_node);
    _ = queue.add(&second_node);
    _ = queue.add(&third_node);

    try testing.expect(queue.wakeTask(&second));
    try testing.expectEqual(@as(u32, 1), second.wakes);
    try testing.expectEqual(@as(u32, 2), queue.length());
    try testing.expectEqual(@as(u32, 0), queue.cancelled);

    // A task that is not waiting here is not woken, and no wake is remembered
    // for it: a targeted wake names a task, not an event.
    try testing.expect(!queue.wakeTask(&absent));
    try testing.expectEqual(@as(u32, 0), queue.pending_wakes);

    try testing.expectEqual(&first_node, queue.wakeOne().?);
    try testing.expectEqual(&third_node, queue.wakeOne().?);
}

test "a deadline ends the waits that passed it and no other" {
    var queue: WaitQueue = .{};
    var forever: FakeTask = .{ .id = 1 };
    var soon: FakeTask = .{ .id = 2 };
    var later: FakeTask = .{ .id = 3 };

    var forever_node = nodeForTask(&forever);
    var soon_node = nodeForTask(&soon);
    var later_node = nodeForTask(&later);

    forever_node.deadline = 0;
    soon_node.deadline = 5;
    later_node.deadline = 10;

    _ = queue.add(&forever_node);
    _ = queue.add(&soon_node);
    _ = queue.add(&later_node);

    // The clock is before the first deadline: nothing expires.
    try testing.expectEqual(@as(u32, 0), queue.expire(4));
    try testing.expectEqual(@as(u32, 3), queue.length());

    // The first deadline passes: exactly one wait ends.
    try testing.expectEqual(@as(u32, 1), queue.expire(5));
    try testing.expectEqual(@as(u32, 1), soon.wakes);
    try testing.expect(soon_node.expired);
    try testing.expectEqual(@as(u32, 2), queue.length());

    // The wait without a deadline is still waiting after the clock passed it.
    try testing.expectEqual(@as(u32, 1), queue.expire(10));
    try testing.expectEqual(@as(u32, 1), later.wakes);
    try testing.expectEqual(@as(u32, 0), forever.wakes);
    try testing.expectEqual(@as(u32, 1), queue.length());
    try testing.expectEqual(@as(u64, 2), queue.expired);
}

test "the counters tell a wake from a cancellation and from a timeout" {
    var queue: WaitQueue = .{};
    var one: FakeTask = .{ .id = 1 };
    var two: FakeTask = .{ .id = 2 };
    var three: FakeTask = .{ .id = 3 };

    var one_node = nodeForTask(&one);
    var two_node = nodeForTask(&two);
    var three_node = nodeForTask(&three);

    _ = queue.add(&one_node);
    _ = queue.add(&two_node);
    _ = queue.add(&three_node);

    // The second waiter gives up by itself: that is a cancellation.
    try testing.expect(queue.remove(&two_node));
    try testing.expectEqual(@as(u32, 2), queue.length());

    // A producer wakes one waiter: that is a wake.
    try testing.expectEqual(&one_node, queue.wakeOne().?);

    // The third waiter is left to its deadline: that is a timeout.
    three_node.deadline = 1;
    try testing.expectEqual(@as(u32, 1), queue.expire(1));
    try testing.expect(three_node.expired);
    try testing.expectEqual(@as(u32, 0), queue.length());

    // A wake with nobody in the queue is remembered, and it is not counted as
    // a wake of a waiter.
    try testing.expectEqual(@as(?*Node, null), queue.wakeOne());
    try testing.expectEqual(@as(u32, 1), queue.pending_wakes);

    try testing.expectEqual(@as(u64, 2), queue.woken);
    try testing.expectEqual(@as(u64, 1), queue.cancelled);
    try testing.expectEqual(@as(u64, 1), queue.expired);

    // The task that cancelled was never woken, and the one that timed out was.
    try testing.expectEqual(@as(u32, 1), one.wakes);
    try testing.expectEqual(@as(u32, 0), two.wakes);
    try testing.expectEqual(@as(u32, 1), three.wakes);
}

test "the queue keeps its shape under random operations" {
    var prng = std.Random.DefaultPrng.init(0x7761697421);
    const random = prng.random();

    var queue: WaitQueue = .{};
    var fakes: [8]FakeTask = undefined;
    var nodes: [8]Node = undefined;
    var queued: [8]bool = @splat(false);

    for (&fakes, &nodes, 0..) |*fake, *node, index| {
        fake.* = .{ .id = @intCast(index) };
        node.* = nodeForTask(fake);
    }

    var round: usize = 0;
    while (round < 500) : (round += 1) {
        const index = random.uintLessThan(usize, nodes.len);

        switch (random.uintLessThan(u8, 3)) {
            0 => {
                const result = queue.add(&nodes[index]);
                if (queued[index]) {
                    try testing.expectEqual(AddResult.already_queued, result);
                } else switch (result) {
                    // A wake that found nobody is remembered, and the next
                    // waiter consumes it: that waiter does not sleep.
                    .queued => queued[index] = true,
                    .already_woken => {},
                    .already_queued => return error.NodeWasNotQueued,
                }
            },
            1 => {
                const removed = queue.remove(&nodes[index]);
                try testing.expectEqual(queued[index], removed);
                queued[index] = false;
            },
            else => {
                const woken = queue.wakeOne();
                if (woken) |node| {
                    // The node that was woken is one of ours, and it is the
                    // one that leaves the queue.
                    var position: usize = 0;
                    var found = false;
                    for (&nodes, 0..) |*candidate, candidate_index| {
                        if (candidate == node) {
                            position = candidate_index;
                            found = true;
                        }
                    }
                    try testing.expect(found);
                    queued[position] = false;
                }
            },
        }

        // The counter, the flags and the list agree after every operation.
        var walked: u32 = 0;
        var current = queue.head;
        var last: ?*Node = null;
        while (current) |node| {
            try testing.expect(node.queued);
            try testing.expectEqual(last, node.prev);
            last = node;
            walked += 1;
            if (walked > nodes.len) return error.CycleInQueue;
            current = node.next;
        }
        try testing.expectEqual(walked, queue.count);
        try testing.expectEqual(last, queue.tail);

        var entries: u32 = 0;
        for (queued) |value| {
            if (value) entries += 1;
        }
        try testing.expectEqual(entries, queue.count);
    }
}
