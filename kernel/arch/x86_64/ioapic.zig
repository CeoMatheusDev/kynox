//************************************************************************//
//  ioapic.zig                                                            //
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

//! Programming of the I/O APIC.
//!
//! The I/O APIC receives the interrupt lines of the platform and forwards each
//! one to a local APIC, with a vector and a delivery mode chosen by software.
//! The configuration lives in the redirection table: one 64-bit entry per GSI
//! (global system interrupt).
//!
//! This module owns three things:
//!
//!   * the **encoding** of a redirection entry (pure, tested on the host);
//!   * the **register access** to one I/O APIC (two MMIO registers: an index
//!     and a window);
//!   * the **bounds and state checks** that keep a bad GSI or vector away from
//!     the hardware.
//!
//! It does not decide which GSI belongs to which device: that comes from the
//! MADT (see `acpi.isaRoute`) and from the PCI routing table, which the kernel
//! does not consume yet.
//!
//! The MMIO page is mapped by the caller with `paging.mapDevicePage`; this
//! module never maps memory and never touches a page it was not given.
//!
//! ## Interrupt delivery is not switched on by this module
//!
//! Programming an entry and enabling it are separate operations. The kernel
//! programs the entries of the ISA lines and leaves them **masked** while the
//! 8259 still delivers interrupts, because switching delivery without a
//! recorded boot is how a working system stops booting. `deliveryFlags` and
//! `undeliveryFlags` exist so the switch, when it is validated, is a
//! documented change and not a rewrite.

const std = @import("std");
const kynox = @import("kynox_shared");
const spinlock = @import("spinlock.zig");

/// Offset of the register selector inside the MMIO window.
pub const register_select: u64 = 0x00;
/// Offset of the register window inside the MMIO window.
pub const register_window: u64 = 0x10;

/// Registers of the I/O APIC that the kernel uses.
pub const Register = struct {
    /// Identification register: APIC id in bits 24..27.
    pub const id: u8 = 0x00;
    /// Version register: version in bits 0..7, max redirection entry in
    /// bits 16..23.
    pub const version: u8 = 0x01;
    /// First redirection-table register (bits 0..31 of the entry).
    pub const redirection: u8 = 0x10;
};

/// Largest redirection table allowed by the architecture description.
///
/// The field in the version register is a count minus one; Intel documents a
/// maximum of 24 entries, and hardware that reports more is clamped here
/// instead of being trusted.
pub const max_redirection_entries: u8 = 24;

/// Size of the MMIO window that must be mapped.
pub const mmio_size: u64 = 0x20;

/// Lowest vector the kernel accepts for a hardware interrupt.
///
/// Vectors 0..31 belong to the processor exceptions; a device must never
/// deliver into them.
pub const first_vector: u8 = 32;

/// Delivery mode of a redirection entry.
pub const DeliveryMode = enum(u3) {
    fixed = 0,
    lowest = 1,
    smi = 2,
    nmi = 4,
    init = 5,
    extint = 7,
};

/// Polarity of the line.
pub const Polarity = enum(u1) {
    active_high = 0,
    active_low = 1,
};

/// Trigger mode of the line.
pub const Trigger = enum(u1) {
    edge = 0,
    level = 1,
};

/// Errors of the module.
pub const Error = error{
    /// The base address is zero, unaligned or outside the addressable window.
    InvalidBase,
    /// The version register does not describe a usable table.
    InvalidVersion,
    /// The GSI is outside the redirection table of this I/O APIC.
    InvalidGsi,
    /// The vector is below the first hardware vector.
    InvalidVector,
    /// A register access found no I/O APIC at the base address.
    NotPresent,
};

/// A redirection-table entry.
///
/// The fields map one to one to the architectural layout; `encode` produces
/// the 64-bit value and `decode` reads it back. Tests round-trip every field,
/// which is the only way to be sure of the bit positions without hardware.
pub const Entry = struct {
    /// Vector delivered to the destination local APIC.
    vector: u8 = 0,
    /// Delivery mode.
    delivery: DeliveryMode = .fixed,
    /// Line polarity.
    polarity: Polarity = .active_high,
    /// Line trigger mode.
    trigger: Trigger = .edge,
    /// Masked entries do not deliver.
    masked: bool = true,
    /// Destination local APIC id (physical destination mode).
    destination: u8 = 0,
    /// Logical destination mode. The kernel uses physical mode; the field is
    /// part of the format and is preserved when an entry is read back.
    logical_destination: bool = false,

    /// Packs the entry into the 64-bit value the redirection table holds.
    pub fn encode(self: Entry) u64 {
        var value: u64 = 0;
        value |= @as(u64, self.vector);
        value |= @as(u64, @intFromEnum(self.delivery)) << 8;
        if (self.logical_destination) value |= @as(u64, 1) << 11;
        value |= @as(u64, @intFromEnum(self.polarity)) << 13;
        value |= @as(u64, @intFromEnum(self.trigger)) << 15;
        if (self.masked) value |= @as(u64, 1) << 16;
        value |= @as(u64, self.destination) << 56;
        return value;
    }

    /// Reads an entry from the 64-bit value of the table.
    pub fn decode(raw: u64) Entry {
        return .{
            .vector = @truncate(raw),
            .delivery = @enumFromInt((raw >> 8) & 0b111),
            .logical_destination = (raw >> 11) & 1 == 1,
            .polarity = @enumFromInt((raw >> 13) & 1),
            .trigger = @enumFromInt((raw >> 15) & 1),
            .masked = (raw >> 16) & 1 == 1,
            .destination = @truncate(raw >> 56),
        };
    }

    /// Low 32 bits, the value written to `redirection + 2 * gsi`.
    pub fn low(self: Entry) u32 {
        return @truncate(self.encode());
    }

    /// High 32 bits, the value written to `redirection + 2 * gsi + 1`.
    pub fn high(self: Entry) u32 {
        return @truncate(self.encode() >> 32);
    }

    /// Applies the mask bit without touching the rest of the entry.
    pub fn withMask(self: Entry, masked: bool) Entry {
        var copy = self;
        copy.masked = masked;
        return copy;
    }
};

/// Decoded version register.
pub const Version = struct {
    /// Version number of the I/O APIC.
    version: u8,
    /// Number of redirection entries.
    max_entries: u8,
};

/// Reads the version register value.
///
/// The count field is the number of entries minus one; the result is clamped
/// to `max_redirection_entries`. A count of zero in the register means one
/// entry, not zero, which is why the addition happens before the clamp.
pub fn decodeVersion(raw: u32) Version {
    const reported: u16 = @as(u16, @truncate((raw >> 16) & 0xFF)) + 1;
    return .{
        .version = @truncate(raw & 0xFF),
        .max_entries = @intCast(@min(reported, max_redirection_entries)),
    };
}

/// True when the base can be used as an MMIO window.
pub fn isValidBase(base: u64) bool {
    if (base == 0) return false;
    if (base % 0x1000 != 0) return false;
    return base < 4 * 1024 * 1024 * 1024;
}

/// Reads a register of the I/O APIC at `base`.
fn readRegister(base: u64, register: u8) u32 {
    const select: *volatile u32 = @ptrFromInt(base + register_select);
    const window: *volatile u32 = @ptrFromInt(base + register_window);
    select.* = register;
    return window.*;
}

/// Writes a register of the I/O APIC at `base`.
fn writeRegister(base: u64, register: u8, value: u32) void {
    const select: *volatile u32 = @ptrFromInt(base + register_select);
    const window: *volatile u32 = @ptrFromInt(base + register_window);
    select.* = register;
    window.* = value;
}

/// One I/O APIC under the control of the kernel.
pub const Controller = struct {
    /// MMIO base address, already mapped by the caller.
    base: u64 = 0,
    /// Number of redirection entries reported by the hardware.
    max_entries: u8 = 0,
    /// Version reported by the hardware.
    version: u8 = 0,
    /// Identification register of the I/O APIC.
    id: u8 = 0,
    /// The controller was initialized and the registers are readable.
    ready: bool = false,
    /// Serializes read-modify-write sequences over the register pair.
    lock: spinlock.IrqSpinlock = .{},

    /// Initializes the controller from its MMIO base.
    ///
    /// The caller must have mapped the window and ensured that the address is
    /// a device page. A version count of zero is rejected: a table with no
    /// entry cannot route anything, and accepting it would turn a broken
    /// firmware description into a silent no-op.
    pub fn init(base: u64) Error!Controller {
        if (!isValidBase(base)) return error.InvalidBase;

        const version_raw = readRegister(base, Register.version);
        const decoded = decodeVersion(version_raw);
        if (decoded.max_entries == 0) return error.InvalidVersion;

        const id_raw = readRegister(base, Register.id);
        return .{
            .base = base,
            .max_entries = decoded.max_entries,
            .version = decoded.version,
            .id = @truncate(id_raw >> 24),
            .ready = true,
        };
    }

    /// True when `gsi` has an entry in this controller.
    pub fn ownsGsi(self: *const Controller, gsi: u32) bool {
        return gsi < self.max_entries;
    }

    /// Reads an entry back from the hardware.
    pub fn readEntry(self: *Controller, gsi: u32) Error!Entry {
        if (!self.ready) return error.InvalidVersion;
        if (!self.ownsGsi(gsi)) return error.InvalidGsi;

        const flags = self.lock.lockIrqSave();
        defer self.lock.unlockIrqRestore(flags);

        const address: u8 = Register.redirection + @as(u8, @intCast(gsi)) * 2;
        const low = readRegister(self.base, address);
        const high = readRegister(self.base, address + 1);
        return Entry.decode(@as(u64, high) << 32 | @as(u64, low));
    }

    /// Programs an entry.
    ///
    /// The low word is written first with the mask bit forced, then the high
    /// word, then the final low word: an entry is never momentarily unmasked
    /// while it still carries half of the new configuration. The lock makes
    /// the three writes indivisible with respect to another CPU using this
    /// controller.
    pub fn program(self: *Controller, gsi: u32, entry: Entry) Error!void {
        if (!self.ready) return error.InvalidVersion;
        if (!self.ownsGsi(gsi)) return error.InvalidGsi;
        if (entry.vector < first_vector) return error.InvalidVector;
        if (entry.delivery != .fixed and entry.delivery != .lowest) return error.InvalidVector;

        const address: u8 = Register.redirection + @as(u8, @intCast(gsi)) * 2;
        const masked_low = entry.withMask(true).low();

        const flags = self.lock.lockIrqSave();
        defer self.lock.unlockIrqRestore(flags);

        writeRegister(self.base, address, masked_low);
        writeRegister(self.base, address + 1, entry.high());
        writeRegister(self.base, address, entry.low());
    }

    /// Masks an entry, keeping the rest of its configuration.
    pub fn mask(self: *Controller, gsi: u32) Error!void {
        const current = try self.readEntry(gsi);
        try self.program(gsi, current.withMask(true));
    }

    /// Unmasks an entry, keeping the rest of its configuration.
    pub fn unmask(self: *Controller, gsi: u32) Error!void {
        const current = try self.readEntry(gsi);
        try self.program(gsi, current.withMask(false));
    }

    /// Masks every entry of the table.
    ///
    /// The control register of the 8259 and this function are the two ends of
    /// the delivery switch: masking here never loses an interrupt, it only
    /// stops the I/O APIC from forwarding it.
    pub fn maskAll(self: *Controller) void {
        if (!self.ready) return;
        var gsi: u32 = 0;
        while (gsi < self.max_entries) : (gsi += 1) {
            const current = self.readEntry(gsi) catch continue;
            self.program(gsi, current.withMask(true)) catch continue;
        }
    }

    /// True when every entry in the table is masked.
    ///
    /// The check exists for the boot log: it states the state the kernel left
    /// the controller in instead of assuming the writes worked.
    pub fn allMasked(self: *Controller) bool {
        if (!self.ready) return false;
        var gsi: u32 = 0;
        while (gsi < self.max_entries) : (gsi += 1) {
            const entry = self.readEntry(gsi) catch return false;
            if (!entry.masked) return false;
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the entry encoding round-trips every field" {
    const entry: Entry = .{
        .vector = 0x21,
        .delivery = .fixed,
        .polarity = .active_low,
        .trigger = .level,
        .masked = false,
        .destination = 0x1F,
        .logical_destination = false,
    };
    const raw = entry.encode();
    const decoded = Entry.decode(raw);
    try std.testing.expectEqual(entry.vector, decoded.vector);
    try std.testing.expectEqual(entry.delivery, decoded.delivery);
    try std.testing.expectEqual(entry.polarity, decoded.polarity);
    try std.testing.expectEqual(entry.trigger, decoded.trigger);
    try std.testing.expectEqual(entry.masked, decoded.masked);
    try std.testing.expectEqual(entry.destination, decoded.destination);
    try std.testing.expectEqual(entry.logical_destination, decoded.logical_destination);
}

test "the entry bit positions follow the architectural layout" {
    // Low word: vector 0x20, active low, level, unmasked.
    const entry: Entry = .{
        .vector = 0x20,
        .polarity = .active_low,
        .trigger = .level,
        .masked = false,
        .destination = 0,
        .logical_destination = true,
    };
    const low = entry.low();
    try std.testing.expectEqual(@as(u32, 0x20), low & 0xFF);
    try std.testing.expectEqual(@as(u32, 1), (low >> 13) & 1);
    try std.testing.expectEqual(@as(u32, 1), (low >> 15) & 1);
    try std.testing.expectEqual(@as(u32, 0), (low >> 16) & 1);
    try std.testing.expectEqual(@as(u32, 1), (low >> 11) & 1);

    // Destination goes to bits 56..63.
    const routed: Entry = .{ .vector = 0x20, .destination = 0xAB, .masked = true };
    try std.testing.expectEqual(@as(u32, 0xAB), routed.high() >> 24);
}

test "masking preserves the rest of the entry" {
    const entry: Entry = .{ .vector = 0x21, .destination = 3, .masked = false };
    try std.testing.expect(entry.withMask(true).masked);
    try std.testing.expectEqual(entry.vector, entry.withMask(true).vector);
    try std.testing.expectEqual(entry.destination, entry.withMask(true).destination);
    try std.testing.expect(!entry.withMask(false).masked);
}

test "the version register is decoded with the count-minus-one field" {
    // Version 0x11 in bits 0..7, count-minus-one 23 (0x17) in bits 16..23.
    const decoded = decodeVersion(0x0017_0011);
    try std.testing.expectEqual(@as(u8, 0x11), decoded.version);
    try std.testing.expectEqual(@as(u8, 24), decoded.max_entries);

    // One entry: field zero still means one.
    try std.testing.expectEqual(@as(u8, 1), decodeVersion(0x0000_0000).max_entries);
    // Hardware that reports more than the architectural maximum is clamped.
    try std.testing.expectEqual(max_redirection_entries, decodeVersion(0x00FF_0000).max_entries);
}

test "the base address validation rejects unusable windows" {
    try std.testing.expect(isValidBase(0xFEC0_0000));
    try std.testing.expect(!isValidBase(0));
    try std.testing.expect(!isValidBase(0xFEC0_0010));
    try std.testing.expect(!isValidBase(4 * 1024 * 1024 * 1024));
}

test "a controller that was not initialized refuses to program" {
    var controller: Controller = .{};
    try std.testing.expectError(error.InvalidVersion, controller.program(0, .{ .vector = 0x21 }));
    try std.testing.expectError(error.InvalidVersion, controller.readEntry(0));
    try std.testing.expect(!controller.allMasked());
    controller.maskAll(); // must be a no-op, not a fault
}

test "gsi bounds follow the table size" {
    var controller: Controller = .{ .ready = true, .max_entries = 24 };
    try std.testing.expect(controller.ownsGsi(0));
    try std.testing.expect(controller.ownsGsi(23));
    try std.testing.expect(!controller.ownsGsi(24));
    try std.testing.expectError(error.InvalidGsi, controller.program(24, .{ .vector = 0x21, .destination = 1 }));
}

test "a vector inside the exception range is refused before any write" {
    var controller: Controller = .{ .ready = true, .max_entries = 24, .base = 0xFEC0_0000 };
    try std.testing.expectError(
        error.InvalidVector,
        controller.program(1, .{ .vector = 0x0F, .destination = 1 }),
    );
    // APIC id 0 is a legal physical destination: QEMU's BSP is usually 0,
    // and rejecting it would silently drop the interrupt. The call reaches
    // the MMIO write of an unmapped page here, so the test stops before it
    // by leaving the controller not ready.
    var offline: Controller = .{ .ready = false, .max_entries = 24 };
    try std.testing.expectError(
        error.InvalidVersion,
        offline.program(1, .{ .vector = 0x21, .destination = 0 }),
    );
}
