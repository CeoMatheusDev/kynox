//************************************************************************//
//  syscall.zig                                                           //
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

//! Low level layer of the native syscall ABI (KX-ABI).
//!
//! The numbers, the limits and the error codes come from the normative
//! contract `shared/syscall_abi.zig`, which the kernel imports as well; this
//! file only adapts that contract to the user mode: the `syscall`
//! instruction, the decoding of the results and a typed error enum for the
//! applications.
//!
//! Calling convention (x86_64):
//!   RAX = number / result, RDI, RSI, RDX, R8 = arguments, RDX = secondary
//!   result of `receive*`. RCX and R11 are destroyed by the instruction.
//!
//! A negative status is an error: `status == -(error code)`.

const std = @import("std");
const abi = @import("kynox_syscall_abi");

/// Normative contract, re-exported for the callers of this module.
pub const contract = abi;

/// Revision of the ABI contract implemented by this SDK.
pub const abi_version: u32 = abi.version;

/// The published call numbers.
pub const Number = abi.Number;

/// The published limits and non descriptor values.
pub const max_block_length = abi.max_block_length;
pub const max_path_length = abi.max_path_length;
pub const Descriptor = abi.Descriptor;
pub const Privilege = abi.Privilege;

/// Error codes as a closed enum for the application code.
///
/// Every field takes its value from the contract, so the enum cannot drift
/// from the kernel; `knownError` maps an arbitrary code and returns null for
/// codes the contract does not define yet.
pub const Error = enum(u64) {
    unknown_call = abi.Error.unknown_call,
    invalid_address = abi.Error.invalid_address,
    invalid_length = abi.Error.invalid_length,
    not_allowed = abi.Error.not_allowed,
    empty_queue = abi.Error.empty_queue,
    unknown_channel = abi.Error.unknown_channel,
    full_queue = abi.Error.full_queue,
    unknown_process = abi.Error.unknown_process,
    wait_impossible = abi.Error.wait_impossible,
    not_authorized = abi.Error.not_authorized,
    unknown_kind = abi.Error.unknown_kind,
    invalid_rights = abi.Error.invalid_rights,
    timeout = abi.Error.timeout,
    no_such_file = abi.Error.no_such_file,
    no_space = abi.Error.no_space,
    bad_descriptor = abi.Error.bad_descriptor,
    too_many_open_files = abi.Error.too_many_open_files,
    name_exists = abi.Error.name_exists,
    invalid_name = abi.Error.invalid_name,
    file_too_large = abi.Error.file_too_large,
    io_error = abi.Error.io_error,
    no_display = abi.Error.no_display,
    invalid_geometry = abi.Error.invalid_geometry,
    invalid_format = abi.Error.invalid_format,
    no_input = abi.Error.no_input,
};

/// Maps an error code to the enum; unknown or future codes stay null.
pub fn knownError(status: u64) ?Error {
    const code = errorCode(status) orelse return null;
    inline for (comptime std.enums.values(Error)) |candidate| {
        if (@intFromEnum(candidate) == code) return candidate;
    }
    return null;
}

pub const Result = struct {
    status: u64,
    value: u64,
};

/// Executes one call. The secondary output (RDX) matters for `receive*`.
///
/// The function does not translate errors: the caller receives the exact
/// bits of the ABI and decodes them with `knownError`/`errorCode`.
pub inline fn call(number: u64, a: u64, b: u64, c: u64, d: u64) Result {
    var status: u64 = undefined;
    var value: u64 = undefined;
    asm volatile ("syscall"
    : [status] "={rax}" (status),
      [value] "={rdx}" (value),
    : [number] "{rax}" (number),
      [a] "{rdi}" (a),
      [b] "{rsi}" (b),
      [c] "{rdx}" (c),
      [d] "{r8}" (d),
    : .{ .rcx = true, .r11 = true, .memory = true });
    return .{ .status = status, .value = value };
}

/// True when the status carries an error.
pub fn isError(status: u64) bool {
    return abi.isError(status);
}

/// Error code of a status, or null when the status is a success value.
pub fn errorCode(status: u64) ?u64 {
    return abi.errorCode(status);
}

test "the SDK re-exports the contract without a private copy" {
    try std.testing.expectEqual(abi.version, abi_version);
    try std.testing.expectEqual(abi.max_block_length, max_block_length);
    try std.testing.expectEqual(abi.max_path_length, max_path_length);
    inline for (comptime std.meta.declarations(Number)) |declaration| {
        try std.testing.expectEqual(
            @field(abi.Number, declaration),
            @field(Number, declaration),
        );
    }
}

test "every error field equals the contract constant of the same name" {
    const names = comptime std.meta.declarations(abi.Error);
    inline for (comptime std.enums.values(Error)) |candidate| {
        const contract_value = @field(abi.Error, @tagName(candidate));
        try std.testing.expectEqual(contract_value, @intFromEnum(candidate));
        try std.testing.expectEqual(@as(usize, 1), countOf(names, @tagName(candidate)));
    }
}

test "the error enum covers the published codes and nothing else" {
    try std.testing.expectEqual(
        std.meta.declarations(abi.Error).len,
        std.enums.values(Error).len,
    );
}

fn countOf(names: []const []const u8, wanted: []const u8) usize {
    var total: usize = 0;
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) total += 1;
    }
    return total;
}

test "ABI call numbers are stable" {
    try std.testing.expectEqual(@as(u64, 1), Number.ping);
    try std.testing.expectEqual(@as(u64, 11), Number.receive_timeout);
    try std.testing.expectEqual(@as(u64, 13), Number.fs_open);
    try std.testing.expectEqual(@as(u64, 18), Number.fs_mkdir);
    try std.testing.expectEqual(@as(u64, 19), Number.display_info);
    try std.testing.expectEqual(@as(u64, 20), Number.present);
    try std.testing.expectEqual(@as(u64, 21), Number.input_poll);
    try std.testing.expectEqual(@as(u64, 22), Number.fs_truncate);
    try std.testing.expectEqual(@as(u64, 23), Number.input_wait);
    try std.testing.expectEqual(@as(u32, 1), abi_version);
    // Number 12 stays reserved: it has no name and no wrapper.
    try std.testing.expectEqual(@as(?[]const u8, null), abi.nameOf(12));
}

test "negative status decoding" {
    try std.testing.expect(!isError(0));
    try std.testing.expect(!isError(0x42));
    try std.testing.expectEqual(@as(?u64, 13), errorCode(0 -% @as(u64, 13)));
}

test "error catalog and unknown codes" {
    try std.testing.expectEqual(@as(?Error, .not_authorized), knownError(0 -% @as(u64, 10)));
    try std.testing.expectEqual(@as(?Error, .timeout), knownError(0 -% @as(u64, 13)));
    try std.testing.expectEqual(@as(?Error, .no_display), knownError(0 -% @as(u64, 22)));
    try std.testing.expectEqual(@as(?Error, .invalid_geometry), knownError(0 -% @as(u64, 23)));
    try std.testing.expectEqual(@as(?Error, .invalid_format), knownError(0 -% @as(u64, 24)));
    try std.testing.expectEqual(@as(?Error, .no_input), knownError(0 -% @as(u64, 25)));
    try std.testing.expectEqual(@as(?Error, null), knownError(0));
    try std.testing.expectEqual(@as(?Error, null), knownError(0 -% @as(u64, 99)));
}
