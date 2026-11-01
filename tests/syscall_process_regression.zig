//! K4.8 regression — syscall stubs.
const std = @import("std");
const syscall_proc = @import("../../task/syscall_process.zig");

test "syscall pointer validation rejects null" {
    try std.testing.expect(!syscall_proc.validateSyscallPointer(0));
}

test "syscall pointer validation accepts non-zero" {
    try std.testing.expect(syscall_proc.validateSyscallPointer(0x1000));
}
