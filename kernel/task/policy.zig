//************************************************************************//
//  policy.zig                                                            //
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

//! The policy of the scheduler, as pure functions.
//!
//! This module answers three questions and touches nothing: which task runs
//! next, whether the running task has spent its slice, and how much virtual
//! time a slice of a given weight is worth. It has no global state, no clock,
//! no counters and no hardware, which is what makes it testable on the host and
//! what lets `scheduler.zig` keep the queues, the lock (when there is one) and
//! the side effects to itself.
//!
//! The split is step 2 of K3 in
//! [`docs/roadmap/KERNEL_COMPLETION_ROADMAP.md`](../../docs/roadmap/KERNEL_COMPLETION_ROADMAP.md):
//! "split policy from mechanism: `policy.zig` is pure functions over queue
//! state (`pickNext`, `shouldPreempt`, `chargeBudget`) with no globals;
//! `scheduler.zig` owns the queues and the lock". The lock is still missing, and
//! this file does not pretend otherwise.

const std = @import("std");

/// The largest number of slots that the policy considers at once.
///
/// The value is the task pool of the scheduler (`scheduler.max_tasks`), which
/// checks it at compile time. It is a constant here so that the array that the
/// caller builds lives on the stack and never allocates: `pickNext` runs from
/// the timer interrupt, and the timer cannot allocate.
pub const max_entries = 32;

/// The unit weight of a task.
///
/// A task of weight 1024 earns one tick of virtual runtime per tick of
/// processor time; a task of weight 2048 earns half a tick, and therefore
/// receives twice the processor time for the same virtual runtime.
pub const unit_weight: u32 = 1024;

/// One slot of the run queue, as the policy sees it.
///
/// The policy does not know what a task is: it sees a virtual runtime and a
/// yes/no answer about eligibility. That is what keeps the choice a pure
/// function, and it is also why the same function can be tested with numbers
/// that no kernel object would produce.
pub const Entry = struct {
    /// The position of the slot in the queue of the scheduler.
    index: usize,
    /// The virtual runtime of the task of the slot.
    vruntime: i64,
    /// Whether the task may be chosen.
    ///
    /// A slot is not eligible when it is empty, when the task is not ready
    /// (it runs, it waits, or it ended), when it is the task that is running,
    /// or when the process of the task is leaving.
    eligible: bool,
};

/// Whether the running task has to leave the processor.
///
/// A quantum of zero means that the task is not subject to time slicing, and a
/// task that is not running is not preempted by its quantum at all: it has
/// already left, and turning it ready again would resurrect a task that is
/// waiting for a message.
pub fn shouldPreempt(state_is_running: bool, quantum: u16) bool {
    return state_is_running and quantum != 0;
}

/// The quantum that a task receives when it enters the processor.
///
/// The value is the slice of the task, and a slice of zero stays zero: a task
/// that is not time sliced must not become time sliced by the refill.
pub fn quantumFor(slice: u16) u16 {
    return slice;
}

/// The virtual runtime that a slice of a task of `weight` is worth.
///
/// The caller must not pass a weight of zero; the scheduler guards with the
/// same condition, and a weight of zero is a defect of the task and not a
/// policy question. The result is at least one, so that a task of a weight
/// above the slice still advances, and so that the deadline of a task is always
/// in its future.
pub fn budgetFor(slice: u16, weight: u32) i64 {
    std.debug.assert(weight != 0);
    const scaled: i64 = @divTrunc(@as(i64, @intCast(slice)) * @as(i64, unit_weight), @as(i64, @intCast(weight)));
    return @max(@as(i64, 1), scaled);
}

/// The deadline that a new task receives: its virtual runtime plus the value of
/// one slice.
///
/// The deadline is what makes the scheduler EEVDF rather than plain
/// EEVDF-shaped: a task that has passed its deadline is entitled to run before
/// a task that has not.
pub fn deadlineFor(vruntime: i64, slice: u16, weight: u32) i64 {
    return vruntime + budgetFor(slice, weight);
}

/// The slot that has to run next, or null when no slot is eligible.
///
/// The search starts **after** `after` and walks the entries in ring order, so
/// that two tasks of the same virtual runtime alternate instead of one of them
/// taking the processor forever. Among the eligible entries it chooses the
/// smallest virtual runtime; when two entries share the smallest virtual
/// runtime, the first one in ring order wins, which makes the choice
/// deterministic for a given queue.
///
/// `after` is the slot of the task that is leaving. It does not have to be
/// inside `entries`: the ring arithmetic takes the remainder, and a queue of
/// one entry therefore yields that entry even when the same task is running.
pub fn pickNext(entries: []const Entry, after: usize) ?usize {
    if (entries.len == 0) return null;

    const start = (after % entries.len + 1) % entries.len;

    var best: ?usize = null;
    var best_vruntime: i64 = std.math.maxInt(i64);

    var offset: usize = 0;
    while (offset < entries.len) : (offset += 1) {
        const index = (start + offset) % entries.len;
        const entry = entries[index];
        if (!entry.eligible) continue;
        if (best == null or entry.vruntime < best_vruntime) {
            best = index;
            best_vruntime = entry.vruntime;
        }
    }

    return best;
}

/// The smallest virtual runtime among the eligible entries.
///
/// A new task starts there instead of at zero, so that a task that enters a
/// busy system is not given the processor for an unbounded stretch: starting at
/// zero would make it the smallest runtime of the queue for as long as the
/// others took to catch up.
pub fn minVruntime(entries: []const Entry) ?i64 {
    var smallest: ?i64 = null;
    for (entries) |entry| {
        if (!entry.eligible) continue;
        if (smallest == null or entry.vruntime < smallest.?) smallest = entry.vruntime;
    }
    return smallest;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// An entry built for a test.
fn slotEntry(index: usize, vruntime: i64, eligible: bool) Entry {
    return .{ .index = index, .vruntime = vruntime, .eligible = eligible };
}

test "the quantum only preempts a task that is still running" {
    try testing.expect(shouldPreempt(true, 1));
    try testing.expect(shouldPreempt(true, 16));
    try testing.expect(!shouldPreempt(true, 0));
    try testing.expect(!shouldPreempt(false, 1));
    try testing.expect(!shouldPreempt(false, 0));
}

test "a task that is not time sliced stays that way after the refill" {
    try testing.expectEqual(@as(u16, 16), quantumFor(16));
    try testing.expectEqual(@as(u16, 1), quantumFor(1));
    try testing.expectEqual(@as(u16, 0), quantumFor(0));
}

test "a slice is worth one tick of virtual runtime per unit of weight" {
    // Ten ticks at the unit weight are ten ticks of virtual runtime.
    try testing.expectEqual(@as(i64, 10), budgetFor(10, unit_weight));
    // Twice the weight is half the virtual runtime for the same slice.
    try testing.expectEqual(@as(i64, 5), budgetFor(10, 2048));
    // Half the weight is twice the virtual runtime.
    try testing.expectEqual(@as(i64, 20), budgetFor(10, 512));
    // A weight far above the slice still advances, and never by zero.
    try testing.expectEqual(@as(i64, 1), budgetFor(1, 60000));
}

test "the deadline is always in the future of the virtual runtime" {
    const deadline = deadlineFor(0, 10, unit_weight);
    try testing.expectEqual(@as(i64, 10), deadline);

    const behind = deadlineFor(-40, 10, 2048);
    try testing.expect(behind > -40);

    const barely = deadlineFor(7, 1, 60000);
    try testing.expect(barely >= 8);
}

test "the next task is the eligible one with the smallest virtual runtime" {
    const entries = [_]Entry{
        slotEntry(0, 30, false), // running
        slotEntry(1, 20, true),
        slotEntry(2, 10, true),
        slotEntry(3, 15, false), // blocked
    };

    try testing.expectEqual(@as(?usize, 2), pickNext(&entries, 0));
}

test "an empty eligibility set has no next task" {
    const entries = [_]Entry{
        slotEntry(0, 1, false),
        slotEntry(1, 2, false),
    };
    try testing.expectEqual(@as(?usize, null), pickNext(&entries, 0));
    try testing.expectEqual(@as(?usize, null), pickNext(&[_]Entry{}, 0));
}

test "two tasks of the same runtime alternate in ring order" {
    const entries = [_]Entry{
        slotEntry(0, 5, true),
        slotEntry(1, 5, true),
    };

    // The task that leaves at slot 1 hands the processor to slot 0, and the
    // other way round: the tie is broken by the ring and not by the index.
    try testing.expectEqual(@as(?usize, 0), pickNext(&entries, 1));
    try testing.expectEqual(@as(?usize, 1), pickNext(&entries, 0));
}

test "the ring breaks the tie after the slot that is leaving" {
    // Three tasks of the same virtual runtime: the ring is the only thing that
    // decides, and it walks the queue in order from the slot of the task that
    // is leaving.
    const entries = [_]Entry{
        slotEntry(0, 5, true),
        slotEntry(1, 5, true),
        slotEntry(2, 5, true),
    };

    try testing.expectEqual(@as(?usize, 1), pickNext(&entries, 0));
    try testing.expectEqual(@as(?usize, 2), pickNext(&entries, 1));
    try testing.expectEqual(@as(?usize, 0), pickNext(&entries, 2));
}

test "the smallest runtime wins even when the ring starts after it" {
    const entries = [_]Entry{
        slotEntry(0, 1, true),
        slotEntry(1, 2, true),
        slotEntry(2, 3, true),
    };

    // The ring decides the order of the search and the tie, never the winner:
    // a task with the smallest runtime is chosen wherever it sits.
    try testing.expectEqual(@as(?usize, 0), pickNext(&entries, 2));
    try testing.expectEqual(@as(?usize, 0), pickNext(&entries, 0));
    try testing.expectEqual(@as(?usize, 0), pickNext(&entries, 1));
}

test "a slot outside the ring is taken modulo the queue" {
    const entries = [_]Entry{
        slotEntry(0, 4, true),
        slotEntry(1, 3, true),
    };

    // `after` is 32 with a queue of two: the ring starts at slot 1, and the
    // smallest runtime is there.
    try testing.expectEqual(@as(?usize, 1), pickNext(&entries, 32));
}

test "the chosen entry is the smallest of the eligible ones" {
    var prng = std.Random.DefaultPrng.init(0x6b796e6f78);
    const random = prng.random();

    var entries: [max_entries]Entry = undefined;

    var round: usize = 0;
    while (round < 200) : (round += 1) {
        for (&entries, 0..) |*current_entry, index| {
            current_entry.* = slotEntry(index, random.intRangeAtMost(i64, -1000, 1000), random.boolean());
        }

        const after = random.uintLessThan(usize, entries.len);
        const chosen = pickNext(&entries, after);

        // Reference answer, written the slow and obvious way: no ring, no
        // early exit, one pass over the eligible entries.
        var expected: ?usize = null;
        var expected_vruntime: i64 = 0;
        var offset: usize = 0;
        var first = true;
        while (offset < entries.len) : (offset += 1) {
            const index = (after % entries.len + 1 + offset) % entries.len;
            if (!entries[index].eligible) continue;
            if (first or entries[index].vruntime < expected_vruntime) {
                expected = index;
                expected_vruntime = entries[index].vruntime;
                first = false;
            }
        }

        try testing.expectEqual(expected, chosen);

        if (chosen) |index| {
            try testing.expect(entries[index].eligible);
            for (entries) |candidate| {
                if (!candidate.eligible) continue;
                try testing.expect(candidate.vruntime >= entries[index].vruntime);
            }
        }
    }
}

test "the smallest runtime of a queue is the one a new task inherits" {
    const entries = [_]Entry{
        slotEntry(0, 50, true),
        slotEntry(1, -20, false),
        slotEntry(2, 5, true),
    };
    try testing.expectEqual(@as(?i64, 5), minVruntime(&entries));

    const none = [_]Entry{slotEntry(0, 1, false)};
    try testing.expectEqual(@as(?i64, null), minVruntime(&none));
}
