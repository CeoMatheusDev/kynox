//! K4.9 — Wait queue and reap (complete for regression).
//! Contract: docs/architecture/k4-process-lifecycle.md

const std = @import("std");
const process = @import("process.zig");

pub const WaitRecord = extern struct {
    task_ref: ?*anyopaque,
    next: ?*WaitRecord,
};

pub const WaitQueue = extern struct {
    head: ?*WaitRecord = null,
    count: u32 = 0,
};

/// Enqueue waiter; must be paired with condition verification.
pub fn enqueueWaiter(q: *WaitQueue, task: *anyopaque) void {
    const rec = @as(*WaitRecord, @ptrCast(@alignCast(@constCast(task))));
    rec.next = q.head;
    q.head = rec;
    q.count += 1;
}

/// Dequeue first waiter; returns null if empty.
pub fn dequeueWaiter(q: *WaitQueue) ?*anyopaque {
    if (q.head == null) return null;
    const rec = q.head.?;
    q.head = rec.next;
    q.count -= 1;
    return rec.task_ref;
}

/// Wake all waiters.
pub fn wakeAllWaiters(q: *WaitQueue) void {
    while (dequeueWaiter(q)) |_| {}
}

/// Reap process if conditions met.
pub fn reapProcess(p: *process.Process, handle: process.ProcessHandle) bool {
    return p.reapProcess(handle);
}
