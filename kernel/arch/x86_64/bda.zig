//************************************************************************//
//  bda.zig                                                               //
//************************************************************************//
//                        This file is part of:                           //
//                              Kynox                                   //
//             https://github.com/CeoMatheusDev/Kynox                   //
//************************************************************************//
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 Kynox - All Rights Reserved.                        //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//

//! The area of data that the firmware leaves at the bottom of the memory.
//!
//! The kernel copies a block of code below 1 MiB for the application processors
//! to start in (`ap_trampoline.zig`), and that region is not empty: from 0x400 to
//! 0x500 sits the BIOS data area, and somewhere above it the extended BIOS data
//! area (EBDA) that the firmware allocated for itself. The word at 0x40E is the
//! **segment** of the EBDA — a paragraph address, so the physical base is the
//! value shifted left by four — and zero means the firmware did not publish one.
//!
//! Overwriting the EBDA would corrupt data that the firmware still owns, and the
//! failure would show up much later and somewhere else. The kernel has the map
//! of usable RAM from the handoff, and that map is not enough: a page can be
//! described as usable RAM and still be the EBDA, because the firmware allocates
//! it at run time and the map was built before that.
//!
//! What this module can promise is limited on purpose. The EBDA has **no length
//! field**: the firmware allocates a kilobyte, and nothing says so. The rule the
//! kernel follows is therefore conservative — the block of the trampoline has to
//! end at or below the base of the EBDA — and the function says exactly that
//! instead of pretending to know where the EBDA ends.

const std = @import("std");

/// The physical address of the BIOS data area.
pub const bda_base: u64 = 0x400;

/// The offset, inside the BDA, of the segment of the EBDA.
pub const ebda_pointer_offset: usize = 0x0E;

/// The offset, inside the BDA, of the size of conventional memory in KiB.
pub const conventional_memory_offset: usize = 0x13;

/// The physical base of the EBDA from the word the firmware published.
///
/// The word is a segment: the physical address is `word << 4`. A zero word is
/// not an address — it is the firmware saying that it published nothing — and it
/// is reported as null so that a caller can tell "no EBDA" from "an EBDA at
/// zero", which would be a firmware defect.
pub fn ebdaFromWord(word: u16) ?u64 {
    if (word == 0) return null;
    return @as(u64, word) << 4;
}

/// The physical base of the EBDA from the bytes of the BDA.
///
/// `bytes` is the content of the area that starts at `bda_base`, and it has to
/// cover the pointer: a shorter slice is a caller error, not a machine without
/// an EBDA, and it is reported as an error instead of being guessed.
pub fn ebdaBase(bytes: []const u8) error{Short}!?u64 {
    if (bytes.len < ebda_pointer_offset + 2) return error.Short;
    const word = std.mem.readInt(u16, bytes[ebda_pointer_offset..][0..2], .little);
    return ebdaFromWord(word);
}

/// The conventional memory size in KiB, as the firmware reported it.
pub fn conventionalKiB(bytes: []const u8) error{Short}!u16 {
    if (bytes.len < conventional_memory_offset + 2) return error.Short;
    return std.mem.readInt(u16, bytes[conventional_memory_offset..][0..2], .little);
}

/// True when a block sits entirely below the EBDA.
///
/// Without an EBDA (null) there is nothing to avoid, and everything fits. The
/// comparison uses the end of the block, not its base: a block that starts below
/// the EBDA and ends inside it corrupts the same data as one that starts inside.
pub fn fitsBelowEbda(ebda: ?u64, address: u64, size: u64) bool {
    const base = ebda orelse return true;
    const end = std.math.add(u64, address, size) catch return false;
    return end <= base;
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

test "a zero pointer is a firmware that published no EBDA" {
    try std.testing.expectEqual(@as(?u64, null), ebdaFromWord(0));

    var bytes: [16]u8 = @splat(0);
    try std.testing.expectEqual(@as(?u64, null), try ebdaBase(&bytes));
}

test "the pointer is a segment, not an address" {
    // 0x9FC0 << 4 = 0x9FC00: the usual place, just below the 640 KiB line.
    try std.testing.expectEqual(@as(?u64, 0x9FC00), ebdaFromWord(0x9FC0));
    try std.testing.expectEqual(@as(?u64, 0x8000), ebdaFromWord(0x0800));
}

test "the EBDA is read from the word at 0x40E" {
    var bytes: [64]u8 = @splat(0);
    std.mem.writeInt(u16, bytes[ebda_pointer_offset..][0..2], 0x9FC0, .little);
    std.mem.writeInt(u16, bytes[conventional_memory_offset..][0..2], 639, .little);

    try std.testing.expectEqual(@as(?u64, 0x9FC00), try ebdaBase(&bytes));
    try std.testing.expectEqual(@as(u16, 639), try conventionalKiB(&bytes));

    // A slice that does not reach the pointer is an error, not "no EBDA".
    try std.testing.expectError(error.Short, ebdaBase(bytes[0..8]));
    try std.testing.expectError(error.Short, conventionalKiB(bytes[0..0x10]));
}

test "a block that ends below the EBDA fits, and one that ends inside it does not" {
    const page: u64 = 4096;

    // The usual machine: the trampoline page far below the EBDA.
    try std.testing.expect(fitsBelowEbda(0x9FC00, 0x8000, page));

    // A block that ends exactly at the base of the EBDA still fits: it does not
    // touch a byte of it.
    try std.testing.expect(fitsBelowEbda(0x9000, 0x8000, page));

    // One byte inside is a byte of the firmware overwritten.
    try std.testing.expect(!fitsBelowEbda(0x8FFF, 0x8000, page));

    // A block that starts below and ends inside is the same defect.
    try std.testing.expect(!fitsBelowEbda(0x8500, 0x8000, page));

    // Without an EBDA there is nothing to avoid.
    try std.testing.expect(fitsBelowEbda(null, 0x8000, page));
}

test "a block whose end does not fit in an address is refused" {
    try std.testing.expect(!fitsBelowEbda(0x9FC00, 0xFFFF_FFFF_FFFF_F000, 0x2000));
}
