//************************************************************************//
//  syscall_abi.zig                                                       //
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

//! Single source of truth for the **native syscall ABI** (KX-ABI).
//!
//! The kernel (`kernel/arch/x86_64/syscall.zig`) and the SDK
//! (`sdk/src/syscall.zig`) both read the numbers, limits and error codes from
//! this module; neither keeps its own copy. Adding a call means editing this
//! file, the kernel dispatch, the SDK wrapper, `docs/specs/syscall-abi.md`
//! and `CHANGELOG.md` in a single change.
//!
//! The ABI revision in `version` is **not** the system version
//! (`version.zig`) and **not** a binary format version (handoff, KEX, KPK,
//! KNV). It changes only when the meaning of the contract changes; adding a
//! new call number does not require a new revision.
//!
//! Calling convention (`syscall` instruction):
//!
//!   * number in `RAX`, arguments in `RDI`, `RSI`, `RDX`, `R8`;
//!   * primary result in `RAX`, secondary result in `RDX`;
//!   * `RCX` (return address) and `R11` (flags) are clobbered by the
//!     instruction and restored before returning to user mode;
//!   * a negative `RAX` is an error: `RAX == -(error code)`;
//!   * the kernel runs the handler on the kernel stack of the calling task.

const std = @import("std");

/// Revision of this contract.
///
/// History: the tree previously carried three informal labels (9 in the SDK
/// README, 12 in the error catalog, 13 in the SDK constant) that disagreed
/// and were never enforced by the kernel. Revision 1 is the first contract
/// issued from a single source. It is **wire compatible** with the previous
/// tree: no number was renumbered, removed or repurposed, number 12 stays
/// reserved, and the error codes keep their values.
pub const version: u32 = 1;

/// Revision string used by diagnostics and documents.
pub const string = std.fmt.comptimePrint("v{d}", .{version});

/// The numbers of the calls.
pub const Number = struct {
    /// Answers with `ping_result`; proves the user -> kernel -> user path.
    pub const ping: u64 = 1;
    /// Writes a user buffer to the console. `RDI` = buffer, `RSI` = length,
    /// `RDX` = descriptor (only `Descriptor.console`).
    pub const write: u64 = 2;
    /// Copies a block between two user ranges. `RDI` = destination,
    /// `RSI` = source, `RDX` = length. Overlap safe.
    pub const memcpy: u64 = 3;
    /// Ends the calling task. `RDI` = exit code.
    pub const exit: u64 = 4;
    /// Sends a message to a channel. `RDI` = channel, `RSI` = receiving
    /// side, `RDX` = message kind, `R8` = value. The value travels in the
    /// fourth argument register because `syscall` overwrites `RCX`.
    pub const send: u64 = 5;
    /// Takes one message without blocking. `RDI` = channel, `RSI` = side.
    /// Result: message kind, value in `RDX`.
    pub const receive: u64 = 6;
    /// Copies a block from the caller's space into another process.
    /// `RDI` = process, `RSI` = destination, `RDX` = source, `R8` = length.
    pub const copy_to: u64 = 7;
    /// Takes one message and blocks the caller until one arrives.
    /// `RDI` = channel, `RSI` = side. Result: kind, value in `RDX`.
    pub const receive_blocking: u64 = 8;
    /// Grants a capability. `RDI` = process, `RSI` = kind, `RDX` = subject,
    /// `R8` = rights. The caller must hold the capability with `delegate`.
    pub const grant: u64 = 9;
    /// Revokes a capability. `RDI` = process, `RSI` = kind, `RDX` = subject.
    pub const revoke: u64 = 10;
    /// Waits at most `RDX` ticks for a message. Zero means no deadline.
    /// `RDI` = channel, `RSI` = side.
    pub const receive_timeout: u64 = 11;
    /// Opens a file. `RDI` = path address, `RSI` = path length (not NUL
    /// terminated), `RDX` = flags. Result: descriptor.
    pub const fs_open: u64 = 13;
    /// Closes a descriptor. `RDI` = descriptor.
    pub const fs_close: u64 = 14;
    /// Reads. `RDI` = descriptor, `RSI` = writable buffer, `RDX` = length.
    pub const fs_read: u64 = 15;
    /// Writes. `RDI` = descriptor, `RSI` = readable buffer, `RDX` = length.
    pub const fs_write: u64 = 16;
    /// Creates a file with mode 0644. `RDI` = path, `RSI` = length.
    pub const fs_create: u64 = 17;
    /// Creates a directory. `RDI` = path, `RSI` = length.
    pub const fs_mkdir: u64 = 18;
    /// Reads the display metadata into a user structure.
    /// `RDI` = address, `RSI` = length. Never exposes the framebuffer.
    pub const display_info: u64 = 19;
    /// Presents a rectangle of user pixels. `RDI` = request address,
    /// `RSI` = length. Requires the display capability with `write`.
    pub const present: u64 = 20;
    /// Takes one input event without blocking. `RDI` = address,
    /// `RSI` = length. Result: 1 when written, 0 when the queue is empty.
    pub const input_poll: u64 = 21;
    /// Shrinks an open regular file. `RDI` = descriptor, `RSI` = new size.
    pub const fs_truncate: u64 = 22;
    /// Blocks until an input event arrives or `RDX` ticks expire (zero
    /// means no deadline). `RDI` = address, `RSI` = length.
    pub const input_wait: u64 = 23;
};

/// Result of `ping`, a value the user can verify without syscall access.
pub const ping_result: u64 = 0x42;

/// Numbers that must not be reused.
///
/// 12 was skipped while the interface was being designed and is kept as a
/// hole so that a number never changes meaning.
pub const reserved_numbers = [_]u64{12};

/// Largest block that one call copies, in bytes.
pub const max_block_length: u64 = 64 * 1024;

/// Largest path accepted by a filesystem call, in bytes (UTF-8, not NUL
/// terminated).
pub const max_path_length: usize = 255;

/// Descriptor values that are not file descriptors.
pub const Descriptor = struct {
    /// The kernel console, accepted by `write`.
    pub const console: u64 = 1;
};

/// Privilege level of the caller, as the entry point reports it.
///
/// The value is the CPL of the caller: the `syscall` entry passes 3, and the
/// kernel invokes the handler directly with `Privilege.kernel` (0). The
/// numbering is fixed by the existing assembly stub, not by convention.
pub const Privilege = struct {
    /// The caller runs in the kernel (CPL 0).
    pub const kernel: u64 = 0;
    /// The caller runs in user mode (CPL 3).
    pub const user: u64 = 3;
};

/// Kinds of capability, as `grant` and `revoke` write them in `RSI`.
///
/// The values are part of the call contract, not of the kernel: a program
/// passes one of them, and the kernel maps it to its internal kind.
pub const CapabilityKind = struct {
    /// A channel of the IPC.
    pub const channel: u64 = 0;
    /// A process (used by `copy_to`).
    pub const process: u64 = 1;
    /// The display of the system.
    pub const display: u64 = 2;
    /// The input queue.
    pub const input: u64 = 3;
};

/// Rights of a capability, as `grant` writes them in `R8`.
///
/// A holder may have a subset of the rights the capability carries.
pub const Right = struct {
    /// Put a message in the subject.
    pub const send: u64 = 1 << 0;
    /// Take a message from the subject.
    pub const receive: u64 = 1 << 1;
    /// Give the capability to another process.
    pub const delegate: u64 = 1 << 2;
    /// Write into the address space named by the capability.
    pub const write: u64 = 1 << 3;
    /// Take one event from the input queue.
    pub const read: u64 = 1 << 4;
    /// Every right.
    pub const all: u64 = send | receive | delegate | write | read;
    /// The rights that allow using the subject without giving it away.
    pub const use: u64 = send | receive;
};

/// A call that fails answers with the negative value of one of these codes.
///
/// Existing values are never renumbered; new codes are appended.
pub const Error = struct {
    /// The number of the call does not exist.
    pub const unknown_call: u64 = 1;
    /// An address or length does not belong to a valid user range.
    pub const invalid_address: u64 = 2;
    /// The length is zero or larger than `max_block_length`, or shorter
    /// than the structure the call requires.
    pub const invalid_length: u64 = 3;
    /// The call is not allowed for the privilege level or descriptor.
    pub const not_allowed: u64 = 4;
    /// The queue of the channel is empty.
    pub const empty_queue: u64 = 5;
    /// The channel does not exist.
    pub const unknown_channel: u64 = 6;
    /// The queue of the channel is full.
    pub const full_queue: u64 = 7;
    /// The process does not exist.
    pub const unknown_process: u64 = 8;
    /// The wait is impossible: no other task could run.
    pub const wait_impossible: u64 = 9;
    /// The caller does not hold the capability the call needs.
    pub const not_authorized: u64 = 10;
    /// The kind of capability does not exist.
    pub const unknown_kind: u64 = 11;
    /// The rights are empty or do not apply to the kind.
    pub const invalid_rights: u64 = 12;
    /// The wait expired before the message arrived.
    pub const timeout: u64 = 13;
    /// The path does not name an existing file or directory.
    pub const no_such_file: u64 = 14;
    /// The filesystem has no free block or inode.
    pub const no_space: u64 = 15;
    /// The descriptor is not open.
    pub const bad_descriptor: u64 = 16;
    /// The table of open files is full.
    pub const too_many_open_files: u64 = 17;
    /// A file or directory with the same name already exists.
    pub const name_exists: u64 = 18;
    /// The path or the name is not valid.
    pub const invalid_name: u64 = 19;
    /// The file exceeds the limit of the filesystem.
    pub const file_too_large: u64 = 20;
    /// The filesystem refused the operation for another reason.
    pub const io_error: u64 = 21;
    /// The firmware did not provide a usable display.
    pub const no_display: u64 = 22;
    /// The presentation rectangle is empty or leaves the display.
    pub const invalid_geometry: u64 = 23;
    /// The pixel format is not supported.
    pub const invalid_format: u64 = 24;
    /// The kernel has no input queue for the user mode.
    pub const no_input: u64 = 25;
};

/// Encodes an error code as the value the kernel returns in `RAX`.
pub fn failure(code: u64) u64 {
    return -%code;
}

/// True when a result carries an error.
pub fn isError(status: u64) bool {
    return @as(i64, @bitCast(status)) < 0;
}

/// The error code of a result, or null when the result is a success value.
pub fn errorCode(status: u64) ?u64 {
    if (!isError(status)) return null;
    return 0 -% status;
}

/// Entry of the published table; used by diagnostics and by the consistency
/// tests, and a checklist for the specification document.
pub const Entry = struct {
    number: u64,
    name: []const u8,
};

/// Every call of this revision, in numeric order.
pub const table = [_]Entry{
    .{ .number = Number.ping, .name = "ping" },
    .{ .number = Number.write, .name = "write" },
    .{ .number = Number.memcpy, .name = "memcpy" },
    .{ .number = Number.exit, .name = "exit" },
    .{ .number = Number.send, .name = "send" },
    .{ .number = Number.receive, .name = "receive" },
    .{ .number = Number.copy_to, .name = "copy_to" },
    .{ .number = Number.receive_blocking, .name = "receive_blocking" },
    .{ .number = Number.grant, .name = "grant" },
    .{ .number = Number.revoke, .name = "revoke" },
    .{ .number = Number.receive_timeout, .name = "receive_timeout" },
    .{ .number = Number.fs_open, .name = "fs_open" },
    .{ .number = Number.fs_close, .name = "fs_close" },
    .{ .number = Number.fs_read, .name = "fs_read" },
    .{ .number = Number.fs_write, .name = "fs_write" },
    .{ .number = Number.fs_create, .name = "fs_create" },
    .{ .number = Number.fs_mkdir, .name = "fs_mkdir" },
    .{ .number = Number.display_info, .name = "display_info" },
    .{ .number = Number.present, .name = "present" },
    .{ .number = Number.input_poll, .name = "input_poll" },
    .{ .number = Number.fs_truncate, .name = "fs_truncate" },
    .{ .number = Number.input_wait, .name = "input_wait" },
};

/// Name of a call number, or null when the number is not published.
pub fn nameOf(number: u64) ?[]const u8 {
    for (table) |entry| {
        if (entry.number == number) return entry.name;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests of the contract itself
// ---------------------------------------------------------------------------

test "every declared number appears exactly once in the table" {
    // `std.meta.declarations` returns the declaration names; the list has to
    // be resolved at compile time before the loop.
    const declarations = comptime std.meta.declarations(Number);

    inline for (declarations) |declaration_name| {
        const value = @field(Number, declaration_name);
        var found: usize = 0;
        for (table) |entry| {
            if (entry.number == value) {
                found += 1;
                try std.testing.expectEqualStrings(declaration_name, entry.name);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), found);
    }
    try std.testing.expectEqual(declarations.len, table.len);
}

test "numbers are unique, positive and outside the reserved set" {
    for (table, 0..) |entry, index| {
        try std.testing.expect(entry.number >= 1);
        for (reserved_numbers) |reserved| {
            try std.testing.expect(entry.number != reserved);
        }
        for (table[index + 1 ..]) |later| {
            try std.testing.expect(entry.number != later.number);
        }
    }
    try std.testing.expectEqual(@as(u64, 12), reserved_numbers[0]);
    try std.testing.expect(nameOf(12) == null);
}

test "the table is ordered by number" {
    var previous: u64 = 0;
    for (table) |entry| {
        try std.testing.expect(entry.number > previous);
        previous = entry.number;
    }
}

test "ping answers with a value that is not an error" {
    try std.testing.expect(!isError(ping_result));
    try std.testing.expectEqual(@as(?u64, null), errorCode(ping_result));
}

test "error codes keep their published values" {
    try std.testing.expectEqual(@as(u64, 1), Error.unknown_call);
    try std.testing.expectEqual(@as(u64, 12), Error.invalid_rights);
    try std.testing.expectEqual(@as(u64, 13), Error.timeout);
    try std.testing.expectEqual(@as(u64, 25), Error.no_input);
}

test "failure, isError and errorCode are inverse operations" {
    const codes = [_]u64{ 1, 4, 13, 25 };
    for (codes) |code| {
        const wire = failure(code);
        try std.testing.expect(isError(wire));
        try std.testing.expectEqual(@as(?u64, code), errorCode(wire));
    }
    // The zero result of a successful call is not an error.
    try std.testing.expect(!isError(0));
    try std.testing.expectEqual(@as(?u64, null), errorCode(0));
}

test "capability kinds and rights are stable" {
    const kinds = [_]u64{
        CapabilityKind.channel,
        CapabilityKind.process,
        CapabilityKind.display,
        CapabilityKind.input,
    };
    for (kinds, 0..) |kind, index| {
        try std.testing.expectEqual(@as(u64, @intCast(index)), kind);
    }
    try std.testing.expectEqual(@as(u64, 0b11111), Right.all);
    try std.testing.expectEqual(Right.send | Right.receive, Right.use);
    try std.testing.expect(Right.use & Right.delegate == 0);
}

test "the privilege values match the entry stub" {
    // `syscall.s` pushes 3 in RSI and `kernel/main.zig` registers the self
    // test with Privilege.kernel; changing either value breaks the
    // discrimination between user and kernel callers.
    try std.testing.expectEqual(@as(u64, 0), Privilege.kernel);
    try std.testing.expectEqual(@as(u64, 3), Privilege.user);
}

test "the revision is independent from the system version" {
    try std.testing.expectEqual(@as(u32, 1), version);
    try std.testing.expectEqualStrings("v1", string);
}
