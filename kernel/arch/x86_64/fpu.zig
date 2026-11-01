//! FPU isolation module (K3.12.3 / K4.10 scaffold).
//! Contract: isolation between tasks; FPU embedded in cpu.zig/context.zig still.
//! Full isolation requires dedicated state save/restore per process.

const std = @import("std");

pub const FPUState = extern struct {
    // Stub: full x87/SIMD state requires 512+ bytes.
    // Currently embedded in context.zig; migration to dedicated module pending.
};

/// Save FPU state for current task.
pub fn saveState() void {}

/// Restore FPU state for task.
pub fn restoreState() void {}
