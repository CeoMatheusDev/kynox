//! K4.4 regression — userspace transition stubs.
const std = @import("std");
const user_trans = @import("../../task/user_transition.zig");

test "user transition stub validates range" {
    try std.testing.expect(user_trans.validateUserRange(0x1000, 8));
}
