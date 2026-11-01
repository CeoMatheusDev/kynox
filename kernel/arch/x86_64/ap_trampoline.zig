//************************************************************************//
//  ap_trampoline.zig                                                     //
//************************************************************************//
//                        This file is part of:                           //
//                              Kynox                                    //
//             https://github.com/CeoMatheusDev/Kynox                    //
//************************************************************************//
// Copyright (C) 2026 Kynox contributors.                                 //
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 Kynox - All Rights Reserved.                        //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//

//! The block of the AP trampoline: where it goes and what the BSP writes into
//! it.
//!
//! The body of the trampoline is assembly (`ap_trampoline.s`), and the reason
//! it needs a Zig module next to it is the part that is easy to get wrong and
//! impossible to observe without a second processor: **the fields the BSP
//! fills**. A wrong offset does not crash the BSP — it crashes the AP, in real
//! mode, with no console, and the boot only sees an AP that never answers.
//!
//! So the assembly exports one symbol per field, this module turns them into a
//! `Layout` (offsets relative to the start of the block), and the patch itself
//! is a pure function over a destination buffer. On the host it is driven with
//! a synthetic layout and a buffer; in the kernel with the real symbols and the
//! page below 1 MiB.
//!
//! ## Why below 1 MiB
//!
//! The startup IPI carries an **8-bit vector**, and the processor begins in
//! real mode at `vector * 4096`, with `CS = vector << 8`. A vector is therefore
//! a page in the first megabyte and nothing else: there is no way to start an
//! AP above `0x10_0000`.
//!
//! The kernel does not have to find room there: `physical.minimum_address` is
//! 1 MiB and `Manager.init` reserves everything below it, so the physical
//! manager never hands those pages out. The trampoline takes the page the
//! memory map still describes as usable RAM (the check is `memmap.isUsableRange`
//! at boot, not an assumption here).

const std = @import("std");

/// The vector of the startup IPI.
///
/// 0x08 is the conventional choice: the BIOS interrupt vectors and the BIOS
/// data area live in the first pages, and 0x08 keeps the block away from them
/// while staying far below the EBDA.
pub const vector: u8 = 0x08;

/// The page where the trampoline is published: `vector << 12`.
pub const base_address: u64 = @as(u64, vector) << 12;

/// The size of a page, and the largest block that fits in one.
pub const page_size: u64 = 4096;

/// The offsets of the fields that the BSP writes, relative to the start of the
/// block.
///
/// The values come from the symbols of `ap_trampoline.s` in the kernel, and
/// from a table in a host test. Everything the patch does is expressed through
/// this structure, so a test can assert the behaviour of the patch without the
/// assembly and a boot can assert the assembly without a second processor (the
/// layout is validated against the size of the block on every install).
pub const Layout = struct {
    /// The pseudo-descriptor of the temporary GDT: a 16-bit limit, then the
    /// 32-bit base that has to point at the copy of the table.
    gdt_descriptor: usize = 0,
    /// The far pointer of the jump into the 32-bit code: a 32-bit offset that
    /// has to point at the protected-mode entry of the copy.
    far32: usize = 0,
    /// The CR3 of the kernel, as a 32-bit physical address.
    cr3: usize = 0,
    /// The bits of `EFER` that the AP has to set before it loads the CR3 of the
    /// kernel: long mode, and the no-execute bit when the kernel uses it.
    efer: usize = 0,
    /// The top of the kernel stack of the AP.
    stack: usize = 0,
    /// The logical number of the CPU, passed to the kernel in RDI.
    cpu_id: usize = 0,
    /// The address of the entry point in the kernel (`kynox_ap_entry`).
    entry: usize = 0,
    /// The word that tells the AP that the copy is complete. It is written
    /// **last**, and cleared before the next AP is prepared.
    ready: usize = 0,
    /// The size of the block, which must fit in one page.
    size: usize = 0,
};

/// Why a block was refused.
pub const Error = error{
    /// The block does not fit in the destination.
    DestinationTooSmall,
    /// The source is not the block: its size is not the one of the layout.
    SourceSizeMismatch,
    /// A field of the layout falls outside the block.
    FieldOutside,
    /// A field is not aligned for its width, or the destination is not aligned
    /// for the widest one.
    Misaligned,
    /// The block is larger than a page, or its placement is not a page below
    /// 1 MiB.
    BadPlacement,
    /// A value does not fit in the field that holds it.
    ValueTooLarge,
    /// The block would reach into the extended BIOS data area that the firmware
    /// allocated below 1 MiB at run time.
    OverlapsEbda,
};

/// The fields that are the same for every AP.
pub const Common = struct {
    /// The physical base of the copy, which is what real mode computes from
    /// `CS` and what the descriptors of the temporary table are relative to.
    block_base: u64 = 0,
    /// The physical address of the kernel root table.
    cr3: u64 = 0,
    /// The bits of `EFER` the AP has to enable before it loads CR3.
    ///
    /// The trampoline sets long mode to get out of protected mode, and the
    /// kernel marks pages without execute permission, so the bit that makes
    /// that legal in a page-table entry (`NXE`) has to be on before the tables
    /// are loaded: with it clear, an entry with the bit set is a reserved bit,
    /// and the general protection fault happens inside the trampoline, where
    /// there is no IDT — a silent triple fault. The value comes from the BSP
    /// instead of being hard-coded, because a processor without the feature
    /// would fault on the write.
    efer: u32 = 0,
    /// Where the copy enters 32-bit code, as an absolute address.
    far32_target: u64 = 0,
    /// Where 64-bit code calls into the kernel.
    entry: u64 = 0,
};

/// The fields that change from one AP to the next.
pub const Armed = struct {
    /// The top of the kernel stack of this AP.
    stack_top: u64 = 0,
    /// The logical number of this CPU.
    cpu_id: u32 = 0,
};

/// Checks that a block fits in a page that a startup IPI can reach.
pub fn validatePlacement(address: u64, size: usize) Error!void {
    if (size == 0 or size > page_size) return error.BadPlacement;
    if (address % page_size != 0) return error.BadPlacement;
    if (address + size > 1024 * 1024) return error.BadPlacement;
    if (address >> 12 > 0xFF) return error.BadPlacement;
}

/// Checks that every field of the layout is inside the block, aligned for its
/// width and free of overflow.
pub fn validateLayout(layout: Layout) Error!void {
    if (layout.size == 0 or layout.size > page_size) return error.BadPlacement;

    // The widths are the ones of the fields in `ap_trampoline.s`, and the
    // alignment is what the processor needs for a plain (not `rep`) store.
    if (!inBlock(layout.size, layout.gdt_descriptor, 2, 2)) return error.FieldOutside;
    // The base of the pseudo-descriptor follows its 16-bit limit.
    if (!inBlock(layout.size, layout.gdt_descriptor + 2, 4, 2)) return error.FieldOutside;
    if (!inBlock(layout.size, layout.far32, 4, 4)) return error.FieldOutside;
    if (!inBlock(layout.size, layout.cr3, 4, 4)) return error.FieldOutside;
    if (!inBlock(layout.size, layout.efer, 4, 4)) return error.FieldOutside;
    if (!inBlock(layout.size, layout.stack, 8, 8)) return error.FieldOutside;
    if (!inBlock(layout.size, layout.cpu_id, 4, 4)) return error.FieldOutside;
    if (!inBlock(layout.size, layout.entry, 8, 8)) return error.FieldOutside;
    if (!inBlock(layout.size, layout.ready, 2, 2)) return error.FieldOutside;
}

/// A field fits when it ends inside the block and starts on a multiple of its
/// natural alignment.
fn inBlock(size: usize, offset: usize, width: usize, alignment: usize) bool {
    const end = offset + width;
    if (end < offset) return false;
    if (end > size) return false;
    return offset % alignment == 0;
}

/// Writes the same-for-every-AP fields into a destination that already holds a
/// copy of the block.
///
/// The word `ready` is cleared **first** and left cleared: the copy is complete
/// for the BSP, not for an AP. `arm` is what lets one AP run, and it is called
/// for one AP at a time because the block is shared by all of them.
pub fn install(dest: []u8, source: []const u8, layout: Layout, params: Common) Error!void {
    try validateLayout(layout);
    if (dest.len < layout.size) return error.DestinationTooSmall;
    if (source.len != layout.size) return error.SourceSizeMismatch;
    if (params.block_base > 0xFFFF_FFFF or params.far32_target > 0xFFFF_FFFF) {
        return error.ValueTooLarge;
    }
    if (params.cr3 > 0xFFFF_FFF0) return error.ValueTooLarge;

    @memcpy(dest[0..layout.size], source[0..layout.size]);

    // An AP that started from a previous copy would find `ready` set and jump
    // with whatever stack the previous AP had: clearing it is part of copying.
    writeU16(dest, layout.ready, 0);
    writeU32(dest, layout.gdt_descriptor + 2, @intCast(params.block_base));
    writeU32(dest, layout.far32, @intCast(params.far32_target));
    writeU32(dest, layout.cr3, @intCast(params.cr3));
    writeU32(dest, layout.efer, params.efer);
    writeU64(dest, layout.entry, params.entry);
}

/// Fills the fields of one AP and releases it.
///
/// The order matters and is the whole contract:
///
/// 1. `ready` = 0, so the AP that is about to start cannot read the stack and
///    the CPU number of the AP that started before it;
/// 2. the stack, the CPU number — the fields that differ per AP;
/// 3. `ready` = 1 as the **last** store, which is what tells the AP that
///    everything it reads has been written (the x86 keeps the order of stores
///    to the same memory type, and the trampoline polls the word with no
///    speculation of its own beyond that).
pub fn arm(dest: []u8, layout: Layout, params: Armed) Error!void {
    try validateLayout(layout);
    if (dest.len < layout.size) return error.DestinationTooSmall;

    writeU16(dest, layout.ready, 0);
    writeU64(dest, layout.stack, params.stack_top);
    writeU32(dest, layout.cpu_id, params.cpu_id);
    writeU16(dest, layout.ready, 1);
}

/// The layout of the block that is linked into the kernel.
///
/// Every offset is a difference of symbols of the same section, so the call
/// reads them and does not assume anything about the assembly: a field added to
/// `ap_trampoline.s` shows up here without an edit, and a field that falls
/// outside the block is refused by `validateLayout` instead of corrupting the
/// copy.
pub fn kernelLayout() Layout {
    const start = @intFromPtr(&kynox_ap_trampoline_start);
    return .{
        .gdt_descriptor = @intFromPtr(&kynox_ap_trampoline_gdt_descriptor) - start,
        .far32 = @intFromPtr(&kynox_ap_trampoline_far32) - start,
        .cr3 = @intFromPtr(&kynox_ap_trampoline_cr3) - start,
        .efer = @intFromPtr(&kynox_ap_trampoline_efer) - start,
        .stack = @intFromPtr(&kynox_ap_trampoline_stack) - start,
        .cpu_id = @intFromPtr(&kynox_ap_trampoline_cpu_id) - start,
        .entry = @intFromPtr(&kynox_ap_trampoline_entry) - start,
        .ready = @intFromPtr(&kynox_ap_trampoline_ready) - start,
        .size = @intCast(kynox_ap_trampoline_size),
    };
}

/// The distance from the start of the block to the 32-bit entry, which is the
/// target of the far jump.
pub fn protectedModeOffset() usize {
    return @intFromPtr(&kynox_ap_trampoline_protected_mode) -
        @intFromPtr(&kynox_ap_trampoline_start);
}

/// The address of the first byte of the block as it is linked in the kernel.
pub fn imageAddress() [*]const u8 {
    return @ptrFromInt(@intFromPtr(&kynox_ap_trampoline_start));
}

// The symbols of `ap_trampoline.s`. The size is a `.quad` that holds the
// difference between the end and the start of the block.
extern const kynox_ap_trampoline_start: u8;
extern const kynox_ap_trampoline_size: u64;
extern const kynox_ap_trampoline_gdt_descriptor: u8;
extern const kynox_ap_trampoline_far32: u8;
extern const kynox_ap_trampoline_cr3: u8;
extern const kynox_ap_trampoline_efer: u8;
extern const kynox_ap_trampoline_stack: u8;
extern const kynox_ap_trampoline_cpu_id: u8;
extern const kynox_ap_trampoline_entry: u8;
extern const kynox_ap_trampoline_ready: u8;
extern const kynox_ap_trampoline_protected_mode: u8;

/// Writes a 16-bit field at an offset, through a volatile store.
///
/// The stores of the trampoline are the one place of the kernel where the
/// order against the polling of another processor is the contract, so they are
/// volatile: the compiler may not merge, reorder or drop them.
/// The stores are typed `align(1)` on purpose: the alignment that matters is
/// the one `validateLayout` enforces, and the base of the pseudo-descriptor of
/// the GDT is a 32-bit field at a 2-byte offset (a 16-bit limit comes first).
/// A store that told the compiler "this is aligned" would be a lie the compiler
/// is allowed to profit from; the processor itself does not care on x86-64.
fn writeU16(dest: []u8, offset: usize, value: u16) void {
    const pointer: *align(1) volatile u16 = @ptrCast(&dest[offset]);
    pointer.* = value;
}

fn writeU32(dest: []u8, offset: usize, value: u32) void {
    const pointer: *align(1) volatile u32 = @ptrCast(&dest[offset]);
    pointer.* = value;
}

fn writeU64(dest: []u8, offset: usize, value: u64) void {
    const pointer: *align(1) volatile u64 = @ptrCast(&dest[offset]);
    pointer.* = value;
}

/// Reads a 16-bit field, for the tests and for the diagnostics.
fn readU16(dest: []const u8, offset: usize) u16 {
    return @as(*align(1) const u16, @ptrCast(&dest[offset])).*;
}

fn readU32(dest: []const u8, offset: usize) u32 {
    return @as(*align(1) const u32, @ptrCast(&dest[offset])).*;
}

fn readU64(dest: []const u8, offset: usize) u64 {
    return @as(*align(1) const u64, @ptrCast(&dest[offset])).*;
}

/// A layout of a host test: the offsets of a 96-byte block, aligned the way the
/// fields of the assembly are.
fn testLayout() Layout {
    return .{
        .gdt_descriptor = 32,
        .far32 = 40,
        .cr3 = 44,
        .efer = 52,
        .stack = 56,
        .cpu_id = 64,
        .entry = 72,
        .ready = 80,
        .size = 96,
    };
}

test "the vector of the startup IPI is the page where the block is published" {
    // The processor starts the AP at `vector * 4096`: the two constants cannot
    // drift apart, and the vector has to fit in the byte of the IPI.
    try std.testing.expectEqual(base_address, @as(u64, vector) << 12);
    try std.testing.expect(vector < 0x100);
    try std.testing.expect(base_address < 1024 * 1024);
}

test "a placement that a startup IPI cannot reach is refused" {
    try validatePlacement(base_address, 256);
    // Above 1 MiB there is no vector: the field of the IPI is eight bits.
    try std.testing.expectError(error.BadPlacement, validatePlacement(0x10_0000, 256));
    // Not on the boundary of a page.
    try std.testing.expectError(error.BadPlacement, validatePlacement(base_address + 8, 256));
    // Larger than the page the vector names.
    try std.testing.expectError(error.BadPlacement, validatePlacement(base_address, 4097));
    try std.testing.expectError(error.BadPlacement, validatePlacement(base_address, 0));
    // The last page that a vector can name.
    try validatePlacement(0xFF * 4096, 256);
}

test "the copy carries the fields of every AP but leaves the ready word cleared" {
    var source: [96]u8 = @splat(0xAA);
    var dest: [4096]u8 align(16) = @splat(0);
    const layout = testLayout();

    try install(dest[0..], source[0..], layout, .{
        .block_base = base_address,
        .cr3 = 0x20_0000,
        .efer = 0x900, // long mode and no-execute
        .far32_target = base_address + 0x40,
        .entry = 0xFFFF_8000_1234_0000,
    });

    // The block was copied byte for byte: everything outside the fields that
    // were patched still carries the bytes of the assembly.
    try std.testing.expectEqualSlices(u8, source[0..layout.gdt_descriptor], dest[0..layout.gdt_descriptor]);
    try std.testing.expectEqualSlices(
        u8,
        source[layout.ready + 2 .. layout.size],
        dest[layout.ready + 2 .. layout.size],
    );

    // The base of the temporary table is the copy, as a 32-bit value, and it
    // follows the 16-bit limit of the pseudo-descriptor.
    try std.testing.expectEqual(@as(u32, @intCast(base_address)), readU32(dest[0..], layout.gdt_descriptor + 2));
    try std.testing.expectEqual(@as(u32, @intCast(base_address + 0x40)), readU32(dest[0..], layout.far32));
    try std.testing.expectEqual(@as(u32, 0x20_0000), readU32(dest[0..], layout.cr3));

    // The bits of EFER that the AP has to set before it loads this CR3: long
    // mode, plus `NXE` when the BSP enabled it. Without `NXE` an entry of the
    // kernel tables that marks a page without execution is a reserved bit.
    try std.testing.expectEqual(@as(u32, 0x900), readU32(dest[0..], layout.efer));
    try std.testing.expectEqual(@as(u64, 0xFFFF_8000_1234_0000), readU64(dest[0..], layout.entry));

    // The copy is complete for the BSP, not for an AP: nothing runs until
    // `arm` says which AP this is.
    try std.testing.expectEqual(@as(u16, 0), readU16(dest[0..], layout.ready));
}

test "arming one AP writes its stack and its number, and releases it last" {
    var source: [96]u8 = @splat(0);
    var dest: [4096]u8 align(16) = @splat(0);
    const layout = testLayout();

    try install(dest[0..], source[0..], layout, .{
        .block_base = base_address,
        .cr3 = 0x20_0000,
        .far32_target = base_address,
        .entry = 0x1000,
    });

    try arm(dest[0..], layout, .{ .stack_top = 0x1_0000, .cpu_id = 1 });
    try std.testing.expectEqual(@as(u64, 0x1_0000), readU64(dest[0..], layout.stack));
    try std.testing.expectEqual(@as(u32, 1), readU32(dest[0..], layout.cpu_id));
    try std.testing.expectEqual(@as(u16, 1), readU16(dest[0..], layout.ready));

    // The next AP must not read the stack and the number of the previous one:
    // the word is cleared before the fields are rewritten.
    try arm(dest[0..], layout, .{ .stack_top = 0x2_0000, .cpu_id = 2 });
    try std.testing.expectEqual(@as(u64, 0x2_0000), readU64(dest[0..], layout.stack));
    try std.testing.expectEqual(@as(u32, 2), readU32(dest[0..], layout.cpu_id));
    try std.testing.expectEqual(@as(u16, 1), readU16(dest[0..], layout.ready));

    // Arming above the size of the destination is refused instead of writing
    // past it.
    try std.testing.expectError(error.DestinationTooSmall, arm(dest[0..8], layout, .{ .stack_top = 1, .cpu_id = 1 }));
}

test "a layout whose fields fall outside the block is refused" {
    var source: [96]u8 = @splat(0);
    var dest: [4096]u8 align(16) = @splat(0);
    const params: Common = .{ .block_base = base_address, .cr3 = 0x1000, .far32_target = base_address, .entry = 0x2000 };

    // A field that ends past the block.
    var layout = testLayout();
    layout.entry = 92; // 92 + 8 = 100 > 96
    try std.testing.expectError(error.FieldOutside, install(dest[0..], source[0..], layout, params));

    // A field that is not aligned for its width.
    layout = testLayout();
    layout.stack = 49;
    try std.testing.expectError(error.FieldOutside, install(dest[0..], source[0..], layout, params));

    // A block larger than the page the vector names.
    layout = testLayout();
    layout.size = 4097;
    try std.testing.expectError(error.BadPlacement, install(dest[0..], source[0..], layout, params));

    // The destination has to hold the block, and the source has to be it.
    layout = testLayout();
    try std.testing.expectError(error.DestinationTooSmall, install(dest[0..64], source[0..], layout, params));
    try std.testing.expectError(error.SourceSizeMismatch, install(dest[0..], source[0..64], layout, params));
}

test "the fields that the trampoline reads as 32 bits refuse a bigger value" {
    var source: [96]u8 = @splat(0);
    var dest: [4096]u8 align(16) = @splat(0);
    const layout = testLayout();

    // The temporary GDT, the far pointer and CR3 are 32-bit fields in the
    // assembly: a value above 4 GiB would be truncated without a word.
    try std.testing.expectError(error.ValueTooLarge, install(dest[0..], source[0..], layout, .{
        .block_base = 0x1_0000_0000,
        .cr3 = 0x1000,
        .far32_target = base_address,
        .entry = 0x1000,
    }));
    try std.testing.expectError(error.ValueTooLarge, install(dest[0..], source[0..], layout, .{
        .block_base = base_address,
        .cr3 = 0x1_0000_0000,
        .far32_target = base_address,
        .entry = 0x1000,
    }));
    try std.testing.expectError(error.ValueTooLarge, install(dest[0..], source[0..], layout, .{
        .block_base = base_address,
        .cr3 = 0x1000,
        .far32_target = 0x1_0000_0000,
        .entry = 0x1000,
    }));
}
