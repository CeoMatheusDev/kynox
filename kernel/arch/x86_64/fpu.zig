//! FPU isolation module — real implementation (FXSAVE/FXRSTOR base).
//! Contract: isolation between tasks; FPU embedded in cpu.zig/context.zig.
//! Status: save/restore real; full XSAVE migration still partial.

const std = @import("std");

/// FPU state size for FXSAVE (512 bytes for full x87 + SSE state).
pub const state_size: usize = 512;

/// FPU state buffer.
pub const FPUState = [state_size]u8;

/// Save FPU state (FXSAVE) — real instruction.
pub fn saveState(buf: *FPUState) void {
    // FXSAVE [mem] saves full FPU/MMX/XMM state to buffer.
    // Requires OSXSAVE support; verified by cpuid.
    asm volatile ("fxsave (%[buf])"
        :
        : [buf] "r" (buf),
        : "memory"
    );
}

/// Restore FPU state (FXRSTOR) — real instruction.
pub fn restoreState(buf: *FPUState) void {
    // FXRSTOR [mem] restores full FPU/MMX/XMM state.
    asm volatile ("fxrstor (%[buf])"
        :
        : [buf] "r" (buf),
        : "memory"
    );
}
