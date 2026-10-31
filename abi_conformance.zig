//************************************************************************//
//  abi_conformance.zig                                                   //
//************************************************************************//
//                        This file is part of:                           //
//                              Kynox                                   //
//             https://github.com/CeoMatheusDev/Kynox                 //
//************************************************************************//
// Copyright (C) 2026 Kynox - All Rights Reserved.                      //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//

//! Conformance tests of the native syscall ABI across the tree.
//!
//! The contract (`shared/syscall_abi.zig`) is imported by both the kernel and
//! the SDK, so their numbers cannot drift. What can still drift is the
//! **dispatch**: a call published in the table but not handled by the kernel
//! switch, a number handled but not published, a documented call that no
//! longer exists, or a reserved number that gained a meaning.
//!
//! These tests read the sources as text (the same technique the boot script
//! uses for serial markers) and compare them with the contract. They run on
//! the host as part of `zig build test`, so a divergence fails the build
//! instead of reaching a release.
//!
//! The file lives at the root of the repository because the module root has
//! to contain every embedded file; it is a test only artifact and is not
//! compiled into the kernel, the loader or any application.

const std = @import("std");
const abi = @import("kynox_syscall_abi");

const kernel_dispatch = @embedFile("kernel/arch/x86_64/syscall.zig");
const sdk_wrappers = @embedFile("sdk/src/root.zig");
const specification = @embedFile("docs/specs/syscall-abi.md");

/// A published call, resolved at compile time (`@field` needs a comptime
/// name, and the labels are read from text at run time).
const PublishedCall = struct { name: []const u8, number: u64 };

const published = blk: {
    const names = std.meta.declarations(abi.Number);
    var list: [names.len]PublishedCall = undefined;
    for (names, 0..) |name, index| {
        list[index] = .{ .name = name, .number = @field(abi.Number, name) };
    }
    break :blk list;
};

fn numberFor(name: []const u8) ?u64 {
    for (published) |call| {
        if (std.mem.eql(u8, call.name, name)) return call.number;
    }
    return null;
}

/// Collects the `Number.<name> =>` labels of the kernel dispatch switch.
fn collectKernelLabels(allocator: std.mem.Allocator) !std.StringHashMap(u64) {
    var labels = std.StringHashMap(u64).init(allocator);
    var iterator = std.mem.splitScalar(u8, kernel_dispatch, '\n');
    while (iterator.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const prefix = "Number.";
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        const rest = trimmed[prefix.len..];
        const arrow = std.mem.indexOf(u8, rest, "=>") orelse continue;
        const name = std.mem.trim(u8, rest[0..arrow], " \t");
        if (name.len == 0 or std.mem.indexOfAny(u8, name, " .(") != null) continue;
        const value = numberFor(name) orelse continue;
        try labels.put(name, value);
    }
    return labels;
}

test "every published call is dispatched by the kernel" {
    var labels = try collectKernelLabels(std.testing.allocator);
    defer labels.deinit();

    for (abi.table) |entry| {
        try std.testing.expect(labels.contains(entry.name));
        try std.testing.expectEqual(entry.number, labels.get(entry.name).?);
    }
}

test "the kernel dispatches no number that is not published" {
    var labels = try collectKernelLabels(std.testing.allocator);
    defer labels.deinit();

    var iterator = labels.iterator();
    while (iterator.next()) |entry| {
        const documented_name = abi.nameOf(entry.value_ptr.*) orelse {
            std.debug.print("kernel dispatches unpublished number {d} ({s})\n", .{
                entry.value_ptr.*,
                entry.key_ptr.*,
            });
            return error.UnpublishedNumber;
        };
        try std.testing.expectEqualStrings(entry.key_ptr.*, documented_name);
    }
    try std.testing.expectEqual(abi.table.len, labels.count());
}

test "the SDK does not hardcode a number the contract does not publish" {
    var iterator = std.mem.splitScalar(u8, sdk_wrappers, '\n');
    while (iterator.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "syscall.call(")) continue;
        const rest = trimmed["syscall.call(".len..];
        const space = std.mem.indexOfAny(u8, rest, ", ") orelse continue;
        const first = rest[0..space];
        if (std.fmt.parseInt(u64, first, 10)) |literal| {
            // A literal number in a wrapper must exist in the table.
            try std.testing.expect(abi.nameOf(literal) != null);
        } else |_| {}
    }
}

test "the specification documents every published call" {
    for (abi.table) |entry| {
        const row = try std.fmt.allocPrint(
            std.testing.allocator,
            "| {d} | `{s}` |",
            .{ entry.number, entry.name },
        );
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, specification, row) == null) {
            std.debug.print("missing row in docs/specs/syscall-abi.md: {s}\n", .{row});
            return error.MissingDocumentationRow;
        }
    }
}

test "the reserved numbers are documented and stay unassigned" {
    inline for (abi.reserved_numbers) |reserved| {
        try std.testing.expect(abi.nameOf(reserved) == null);
        const marker = comptime std.fmt.comptimePrint("| {d} | — |", .{reserved});
        try std.testing.expect(std.mem.indexOf(u8, specification, marker) != null);
    }
}

test "the specification documents every capability kind and right" {
    inline for (comptime std.meta.declarations(abi.CapabilityKind)) |name| {
        const marker = comptime std.fmt.comptimePrint("| `{s}` |", .{name});
        try std.testing.expect(std.mem.indexOf(u8, specification, marker) != null);
    }
    inline for (comptime std.meta.declarations(abi.Right)) |name| {
        const marker = comptime std.fmt.comptimePrint("| `{s}` |", .{name});
        try std.testing.expect(std.mem.indexOf(u8, specification, marker) != null);
    }
}

test "the specification states the revision of the contract" {
    const marker = try std.fmt.allocPrint(std.testing.allocator, "Revision **{d}**", .{abi.version});
    defer std.testing.allocator.free(marker);
    try std.testing.expect(std.mem.indexOf(u8, specification, marker) != null);
}
