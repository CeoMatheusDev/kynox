//! FPU isolation module — real implementation (FXSAVE/FXRSTOR + XSAVE when available).
//! Contract: isolation between tasks; FPU embedded in cpu.zig/context.zig.
//! Status: save/restore real; XSAVE detection + fallback; full XSAVE migration still partial.

const std = @import("std");
const cpu = @import("cpu.zig");

/// FPU state size for FXSAVE (512 bytes for full x87 + SSE state).
pub const fxsave_state_size: usize = 512;

/// FPU state buffer (FXSAVE size; XSAVE may require more, allocated separately).
pub const FPUState = [fxsave_state_size]u8;

/// Check if CPU supports XSAVE (CPUID leaf 1, ECX bit 26 = OSXSAVE).
pub fn supportsXsave() bool {
    const r = cpu.cpuid(1, 0);
    return (r[2] & (1 << 26)) != 0; // ECX bit 26 = OSXSAVE
}

/// Read XCR0 (requires XSAVE support).
pub fn readXcr0() u64 {
    var low: u32 = 0;
    var high: u32 = 0;
    asm volatile ("xgetbv"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : "{ecx}" (0),
    );
    return (@as(u64, high) << 32) | low;
}

/// Save FPU state (FXSAVE) — real instruction.
pub fn saveState(buf: *FPUState) void {
    // FXSAVE [mem] saves full FPU/MMX/XMM state to buffer.
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

/// XSAVE — real instruction (requires OSXSAVE support).
pub fn xsave(buf: []u8, mask: u64) void {
    if (!supportsXsave()) return;
    const low: u32 = @intCast(mask & 0xFFFFFFFF);
    const high: u32 = @intCast(mask >> 32);
    asm volatile ("xsave (%[buf])"
        :
        : [buf] "r" (buf.ptr),
          "{eax}" (low),
          "{edx}" (high),
        : "memory"
    );
}

/// XRSTOR — real instruction (requires OSXSAVE support).
pub fn xrstor(buf: []u8, mask: u64) void {
    if (!supportsXsave()) return;
    const low: u32 = @intCast(mask & 0xFFFFFFFF);
    const high: u32 = @intCast(mask >> 32);
    asm volatile ("xrstor (%[buf])"
        :
        : [buf] "r" (buf.ptr),
          "{eax}" (low),
          "{edx}" (high),
        : "memory"
    );
}
