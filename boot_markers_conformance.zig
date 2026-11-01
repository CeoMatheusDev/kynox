//************************************************************************//
//  boot_markers_conformance.zig                                          //
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

//! Conformance between the serial console and the boot test.
//!
//! `tests/integration/boot-qemu.sh` asserts literal markers with
//! `require_marker "..."`. Those markers are a contract: if a banner, a probe
//! or a report changes its wording, the boot test stops matching and there is
//! no way to notice without running QEMU. This artifact embeds the script, the
//! loader and the kernel and proves that every literal marker is still printed
//! by one of the two sources.
//!
//! Patterns (`require_pattern`) are not checked here: they are regular
//! expressions, not literal lines.

const std = @import("std");

const script = @embedFile("tests/integration/boot-qemu.sh");
const loader = @embedFile("boot/uefi/main.zig");
const kernel = @embedFile("kernel/main.zig");

/// Every source that writes to the serial console or to the console syscall,
/// concatenated. A marker may be printed by the loader, by any kernel module
/// that owns a `printLine` call, or by a native program running under it.
///
/// The list is explicit because the language has no compile-time directory
/// walk. When a new module starts writing to the console, it must be added
/// here; otherwise its markers are checked by nothing.
const sources = loader ++ "\n" ++
    kernel ++ "\n" ++
    @embedFile("boot/uefi/knb/console.zig") ++ "\n" ++
    @embedFile("kernel/arch/x86_64/interrupt.zig") ++ "\n" ++
    @embedFile("kernel/drivers/kvdi/virtqueue_probe.zig") ++ "\n" ++
    @embedFile("kernel/arch/x86_64/paging.zig") ++ "\n" ++
    @embedFile("kernel/arch/x86_64/smp.zig") ++ "\n" ++
    @embedFile("kernel/arch/x86_64/syscall.zig") ++ "\n" ++
    @embedFile("kernel/arch/x86_64/timer.zig") ++ "\n" ++
    @embedFile("kernel/task/scheduler.zig") ++ "\n" ++
    @embedFile("kernel/native_image.zig") ++ "\n" ++
    @embedFile("user/hello.zig") ++ "\n" ++
    @embedFile("user/client.zig");

const prefix = "require_marker \"";

/// Text of the marker before the first value rendered at run time.
///
/// The script asserts what appears on the console; a marker such as
/// `[KNK] tasks: 9 created` corresponds to `[KNK] tasks: {d} created` in the
/// source, and `[KNK] syscall 1 from user` comes from
/// `[KNK] syscall {d} from {s}`. The function stops at the first digit or
/// `0x`-prefixed hexadecimal value, which is where the source stops being
/// literal.
///
/// Limitation, stated instead of hidden: a marker whose dynamic part is a
/// **string** (`{s}`, as in "from user") can only be checked up to the prefix.
/// Reconstructing the rendered string would require running the kernel, which
/// is exactly what this environment cannot do. The guard therefore catches the
/// class of regression it was written for — a banner or a report reworded —
/// and does not pretend to validate the values.
fn staticPrefix(marker: []const u8) []const u8 {
    var index: usize = 0;
    while (index < marker.len) {
        if (std.mem.startsWith(u8, marker[index..], "0x") and
            index + 2 < marker.len and std.ascii.isHex(marker[index + 2]))
        {
            return marker[0..index];
        }
        if (std.ascii.isDigit(marker[index])) return marker[0..index];
        index += 1;
    }
    return marker;
}

/// True when the literal part of the marker is still printed by a source.
fn printedBySources(marker: []const u8) bool {
    const prefix_text = staticPrefix(marker);
    if (prefix_text.len == 0) return true;
    return std.mem.indexOf(u8, sources, prefix_text) != null;
}

test "every literal serial marker of the boot test is still printed" {
    var checked: usize = 0;
    var position: usize = 0;
    while (std.mem.indexOfPos(u8, script, position, prefix)) |start| {
        const rest = script[start + prefix.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.MalformedScript;
        const marker = rest[0..end];
        position = start + prefix.len;

        if (!printedBySources(marker)) {
            std.debug.print("marker no longer printed: {s}\n", .{marker});
            return error.MarkerMissing;
        }
        checked += 1;
    }
    // The script has 84 literal markers today; the floor catches a parser that
    // silently stops matching (`require_marker` renamed, quotes changed).
    try std.testing.expect(checked >= 80);
}

test "the product identity marker is printed and names the generation" {
    // The line is part of the boot contract and also carries the public
    // identity; both requirements are checked together so a future edit
    // cannot satisfy one by dropping the other.
    try std.testing.expect(std.mem.indexOf(u8, kernel, "[KNK] Kynox Nucleus Kernel - {s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, kernel, "kynox_version.display") != null);
    try std.testing.expect(std.mem.indexOf(u8, loader, "kynox_version.display") != null);
}

test "no marker relies on a version string" {
    // A marker is a contract with the test; embedding a version in it would
    // make every release edit the boot test. The banners print the identity
    // through a format argument instead.
    try std.testing.expect(std.mem.indexOf(u8, script, "0.1.0") == null);
}
