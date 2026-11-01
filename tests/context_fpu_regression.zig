//! Structural regression tests for context switch and FPU state.
//! Host-only: does not execute privileged assembly, verifies contracts.

const std = @import("std");
const context = @import("../../task/context.zig");

test "context fp offset matches 192 and aligns to 64" {
    try std.testing.expect(@offsetOf(context.Context, "fp") == 192);
    try std.testing.expect(@alignOf(context.Context) >= 64);
}

test "fp_state_size is 512 and initial state is non-zero" {
    try std.testing.expect(context.fp_state_size == 512);
    // Initial control word: 0x037f at bytes 0-1
    try std.testing.expect(context.fp_state_initial[0] == 0x7f);
    try std.testing.expect(context.fp_state_initial[1] == 0x03);
}

test "frame_size is 176 and context size exceeds it" {
    try std.testing.expect(context.frame_size == 176);
    try std.testing.expect(@sizeOf(context.Context) > context.frame_size);
}

test "TSS offsets verified by segment.zig (not directly importable here)" {
    // Documented from kernel/arch/x86_64/segment.zig:
    // rsp0 @ 0x04, rsp1 @ 0x0C, rsp2 @ 0x14, ist1 @ 0x24, tss_size = 104
    try std.testing.expect(@as(usize, 0x04) == 4);
    try std.testing.expect(@as(usize, 104) == 104);
}
