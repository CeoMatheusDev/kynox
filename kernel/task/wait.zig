//! K4.9 — Wait queue and reap (minimal complete for regression).
//! Contract: docs/architecture/k4-process-lifecycle.md; needs full integration.

const std = @import("std");
const process = @import("process.zig");

pub const WaitEntry = extern struct {
    task: *anyopaque,
    next: ?*WaitEntry,
};

pub const WaitQueue = extern struct {
    head: ?*WaitEntry = null,
    tail: ?*WaitEntry = null,
    count: u32 = 0,
};

/// Add waiter to queue; must be paired with condition check.
pub fn addWaiter(q: *WaitQueue, task: *anyopaque) void {
    const entry = @as(*WaitEntry, @ptrCast(@alignCast(@constCast(task)))); // stub: real pool needed
    if (q.head == null) {
        q.head = entry;
        q.tail = entry;
    } else {
        q.tail.?.next = entry;
        q.tail = entry;
    }
    q.count += 1;
}

/// Wake one waiter; removes from queue.
pub fn wakeOne(q: *WaitQueue) ?*anyopaque {
    if (q.head == null) return null;
    const entry = q.head.?;
    q.head = entry.next;
    if (q.head == null) q.tail = null;
    q.count -= 1;
    return entry.task;
}

/// Wake all waiters; clears queue.
pub fn wakeAll(q: *WaitQueue) void {
    while (wakeOne(q)) |_| {}
}

/// Reap process if all conditions met.
pub fn reapProcess(p: *process.Process, handle: process.ProcessHandle) bool {
    return p.reapProcess(handle);
}
