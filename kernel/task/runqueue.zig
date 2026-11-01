//! Per-CPU run queue interface (stub for K4.3 integration).
//! Full integration requires scheduler.zig to use enqueueReady/dequeueReady.

const std = @import("std");

pub const Queue = struct {
    tasks: [64] ?*anyopaque = .{null} ** 64,
    count: u8 = 0,
};

pub fn enqueue(q: *Queue, task: *anyopaque) void {
    if (q.count < 64) {
        q.tasks[q.count] = task;
        q.count += 1;
    }
}

pub fn dequeue(q: *Queue) ?*anyopaque {
    if (q.count == 0) return null;
    const t = q.tasks[0];
    // shift not implemented in stub
    q.count -= 1;
    return t;
}
