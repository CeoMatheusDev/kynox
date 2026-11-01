//************************************************************************//
//  interrupt_registry.zig                                                //
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

//! The owners of the hardware interrupt lines.
//!
//! The dispatcher of the kernel used to be a `switch` on the vector number: the
//! first line was the clock and the second one was the keyboard, and a third
//! device had to edit the kernel to exist. The audit of 2026-10-31 records that
//! as defect 6 ("no interrupt registration API", classified `STUB`), because a
//! device model cannot be built on a table that only the kernel can extend.
//!
//! This module is the table. It is deliberately free of hardware: no port I/O,
//! no MMIO, no assembly, no import of the scheduler or of the system calls. The
//! IDT and the stubs stay in `interrupt.zig`, which asks this table who owns a
//! line; the kernel registers the owners at boot. The consequence is that the
//! dispatch is testable on the host, which the dispatcher was not.
//!
//! Rules of the contract:
//!
//!   * a line has exactly one owner, and a second registration is refused
//!     instead of silently replacing the first;
//!   * a line without an owner is counted and acknowledged, never dispatched to
//!     a guess, so a spurious interrupt is visible and cannot become a storm;
//!   * the counters are written only by the dispatcher, so the diagnostics
//!     cannot disagree with the dispatch.

const std = @import("std");

/// The first vector of the hardware interrupts.
///
/// The value is part of the programming of the 8259 (the interrupts are remapped
/// to 32) and appears in `interrupt.s`; the copy here exists so that the table
/// can validate a vector without importing the hardware module.
pub const first_hardware_vector: u64 = 32;

/// The number of lines that the stubs deliver.
pub const hardware_interrupt_count: u64 = 16;

/// A handler of one hardware interrupt line.
///
/// The handler runs with the interrupts disabled, on the kernel stack, and it
/// has to be short: acknowledge the device, record the event and say whether the
/// interrupted task has to be preempted. It may not block, allocate, wait for a
/// lock that a thread holds or format a log line.
///
/// The return value is the request of a context switch: `true` means that the
/// scheduler has to choose another task before the interrupt returns.
pub const Handler = *const fn (vector: u64) bool;

/// The errors of the registry.
pub const RegistrationError = error{
    /// The vector is not part of the hardware range that has a stub.
    VectorNotDeliverable,
    /// Another component already owns the line.
    AlreadyRegistered,
};

/// One registered line.
const Registration = struct {
    /// The handler, or null when the line has no owner.
    handler: ?Handler = null,
    /// The name of the owner, for the diagnostics.
    name: []const u8 = "",
    /// How many interrupts of the line were delivered to the handler.
    count: u64 = 0,
};

/// The registrations, indexed by the vector minus `first_hardware_vector`.
var registrations: [hardware_interrupt_count]Registration = @splat(.{});

/// Interrupts of the hardware range that arrived without an owner.
///
/// A line that fires without a handler is a wiring defect, and it has to be
/// visible instead of silently acknowledged.
var unhandled_interrupts: u64 = 0;

/// The slot of a hardware vector, or null when the vector has no stub.
fn slotOf(vector: u64) ?usize {
    if (vector < first_hardware_vector) return null;
    const index = vector - first_hardware_vector;
    if (index >= hardware_interrupt_count) return null;
    return @intCast(index);
}

/// Registers a handler for a hardware interrupt line.
///
/// A line has exactly one owner. Two functions that share a physical line (the
/// ISA case, where the 8259 cannot tell them apart) need a dispatcher of their
/// own on top of this API; the registry refuses the second registration instead
/// of leaving the result of a delivery dependent on the order of the calls.
pub fn register(vector: u64, name: []const u8, handler: Handler) RegistrationError!void {
    const slot = slotOf(vector) orelse return error.VectorNotDeliverable;
    if (registrations[slot].handler != null) return error.AlreadyRegistered;
    registrations[slot] = .{ .handler = handler, .name = name, .count = 0 };
}

/// Removes the handler of a line and returns whether there was one.
///
/// The counter of the line is kept: the diagnostics of a device that was removed
/// still have to show how many interrupts it delivered while it was there.
pub fn unregister(vector: u64) bool {
    const slot = slotOf(vector) orelse return false;
    if (registrations[slot].handler == null) return false;
    registrations[slot].handler = null;
    registrations[slot].name = "";
    return true;
}

/// The name of the owner of a line, or null when the line has no owner.
pub fn registeredName(vector: u64) ?[]const u8 {
    const slot = slotOf(vector) orelse return null;
    if (registrations[slot].handler == null) return null;
    return registrations[slot].name;
}

/// The number of interrupts that the handler of the line received.
pub fn interruptCount(vector: u64) u64 {
    const slot = slotOf(vector) orelse return 0;
    return registrations[slot].count;
}

/// The number of interrupts of the hardware range that had no owner.
pub fn unhandledCount() u64 {
    return unhandled_interrupts;
}

/// Delivers one hardware interrupt to its owner.
///
/// The function is the only place that increments the counters, so a handler
/// that forgets to count cannot make the diagnostics lie.
pub fn dispatch(vector: u64) bool {
    // A vector outside the range of the stubs is not a line of the platform;
    // the caller only dispatches the vectors that have an entry in the IDT, so
    // this path is the programming defect, not a spurious interrupt.
    const slot = slotOf(vector) orelse return false;

    const registration = &registrations[slot];
    const handler = registration.handler orelse {
        unhandled_interrupts += 1;
        return false;
    };

    registration.count += 1;
    return handler(vector);
}

/// Clears the registry. Host tests only.
fn resetForTest() void {
    registrations = @splat(.{});
    unhandled_interrupts = 0;
}

// ---------------------------------------------------------------------------
// The tests of the contract
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A handler that counts its calls and returns a fixed answer.
var test_handler_calls: u64 = 0;
var test_handler_answer: bool = false;

fn testHandler(vector: u64) bool {
    _ = vector;
    test_handler_calls += 1;
    return test_handler_answer;
}

test "a registered line dispatches to its owner and counts the interrupts" {
    resetForTest();
    defer resetForTest();

    try register(first_hardware_vector + 4, "test-device", testHandler);
    try testing.expectEqualStrings("test-device", registeredName(first_hardware_vector + 4).?);
    try testing.expectEqual(@as(u64, 0), interruptCount(first_hardware_vector + 4));

    test_handler_calls = 0;
    test_handler_answer = false;
    try testing.expect(!dispatch(first_hardware_vector + 4));
    try testing.expect(!dispatch(first_hardware_vector + 4));

    try testing.expectEqual(@as(u64, 2), test_handler_calls);
    try testing.expectEqual(@as(u64, 2), interruptCount(first_hardware_vector + 4));

    // The answer of the handler is the request of a context switch, and the
    // dispatcher returns it unchanged.
    test_handler_answer = true;
    try testing.expect(dispatch(first_hardware_vector + 4));
    try testing.expectEqual(@as(u64, 3), test_handler_calls);
}

test "two owners for one line are refused" {
    resetForTest();
    defer resetForTest();

    const line = first_hardware_vector + 2;
    try register(line, "first", testHandler);
    try testing.expectError(error.AlreadyRegistered, register(line, "second", testHandler));

    // The refusal does not replace the owner.
    try testing.expectEqualStrings("first", registeredName(line).?);
}

test "a vector without a stub is not registrable" {
    resetForTest();
    defer resetForTest();

    // The exceptions have no hardware stub to dispatch from, and the vector past
    // the last line has no entry in the table at all.
    try testing.expectError(
        error.VectorNotDeliverable,
        register(first_hardware_vector - 1, "exception", testHandler),
    );
    try testing.expectError(
        error.VectorNotDeliverable,
        register(first_hardware_vector + hardware_interrupt_count, "beyond", testHandler),
    );

    try testing.expect(registeredName(first_hardware_vector - 1) == null);
    try testing.expect(registeredName(0xFFFF) == null);
    try testing.expectEqual(@as(u64, 0), interruptCount(0xFFFF));
}

test "an unregistered line is counted as unhandled and is not a storm" {
    resetForTest();
    defer resetForTest();

    test_handler_calls = 0;

    try testing.expect(!dispatch(first_hardware_vector + 5));
    try testing.expectEqual(@as(u64, 1), unhandledCount());
    try testing.expectEqual(@as(u64, 0), test_handler_calls);

    // A vector outside the range of the stubs is not a line of the platform, and
    // it does not grow the counter of the lines.
    try testing.expect(!dispatch(0));
    try testing.expectEqual(@as(u64, 1), unhandledCount());
}

test "unregistering takes the line away and keeps the history" {
    resetForTest();
    defer resetForTest();

    const line = first_hardware_vector + 6;
    try register(line, "removable", testHandler);

    test_handler_calls = 0;
    test_handler_answer = false;
    _ = dispatch(line);
    try testing.expectEqual(@as(u64, 1), interruptCount(line));

    try testing.expect(unregister(line));
    try testing.expect(registeredName(line) == null);

    try testing.expect(!dispatch(line));
    try testing.expectEqual(@as(u64, 1), unhandledCount());
    try testing.expectEqual(@as(u64, 1), interruptCount(line));
    try testing.expectEqual(@as(u64, 1), test_handler_calls);

    // Unregistering twice is harmless.
    try testing.expect(!unregister(line));

    // The line can be given to another owner afterwards.
    try register(line, "next", testHandler);
    try testing.expectEqualStrings("next", registeredName(line).?);
    try testing.expectEqual(@as(u64, 0), interruptCount(line));
}

test "every line of the hardware range has its own slot" {
    resetForTest();
    defer resetForTest();

    // A table that shared a slot between two lines would deliver the interrupt
    // of one device to the handler of another.
    var index: u64 = 0;
    while (index < hardware_interrupt_count) : (index += 1) {
        try register(first_hardware_vector + index, "line", testHandler);
    }

    index = 0;
    while (index < hardware_interrupt_count) : (index += 1) {
        try testing.expectEqualStrings("line", registeredName(first_hardware_vector + index).?);
    }
}
