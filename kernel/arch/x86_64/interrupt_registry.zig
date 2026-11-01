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
//!
//! The same contract covers the **device vectors** — the range above the ones
//! the kernel uses for itself, which a device names when it interrupts with a
//! message (MSI, MSI-X). They are not lines: nothing of the platform delivers
//! them, the device writes the vector into memory. What they share with a line
//! is the property that matters here: one owner, and an interrupt that arrives
//! without one has to be visible instead of silently dropped.

const std = @import("std");

/// The first vector of the hardware interrupts.
///
/// The value is part of the programming of the 8259 (the interrupts are remapped
/// to 32) and appears in `interrupt.s`; the copy here exists so that the table
/// can validate a vector without importing the hardware module.
pub const first_hardware_vector: u64 = 32;

/// The number of lines that the stubs deliver.
pub const hardware_interrupt_count: u64 = 16;

/// The first vector that a device may be given.
///
/// The number has to agree with the stubs of the device range in `interrupt.s`
/// and with the first vector that `msi.zig` hands to a device; the copy here
/// exists so that the table validates a vector without importing the hardware.
pub const first_device_vector: u64 = 68;

/// The number of device vectors that have a stub: 68..254.
///
/// 0xFF is excluded on purpose: it is the vector of the spurious interrupt of
/// the local APIC, and a device that names it would be asking the kernel to
/// treat a real message as a defect of the controller.
pub const device_vector_count: u64 = 187;

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

/// The errors of a device vector registration.
pub const DeviceRegistrationError = error{
    /// The vector is below the device range or is the spurious one.
    VectorNotDeliverable,
    /// Another component already owns the vector.
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

/// The owners of the device vectors, indexed by the vector minus
/// `first_device_vector`.
var device_registrations: [device_vector_count]Registration = @splat(.{});

/// Device interrupts that arrived without an owner.
var unhandled_device_interrupts: u64 = 0;

/// The slot of a device vector, or null when the vector is not deliverable.
fn deviceSlotOf(vector: u64) ?usize {
    if (vector < first_device_vector) return null;
    const index = vector - first_device_vector;
    if (index >= device_vector_count) return null;
    return @intCast(index);
}

/// Gives a device vector an owner.
///
/// The rules are the ones of a line, because the failure mode is the same: a
/// second registration would make the delivery depend on the order of the
/// calls, and a vector that fires without an owner is a wiring defect that the
/// kernel has to be able to see.
pub fn registerDevice(vector: u64, name: []const u8, handler: Handler) DeviceRegistrationError!void {
    const slot = deviceSlotOf(vector) orelse return error.VectorNotDeliverable;
    if (device_registrations[slot].handler != null) return error.AlreadyRegistered;
    device_registrations[slot] = .{ .handler = handler, .name = name, .count = 0 };
}

/// Removes the owner of a device vector and returns whether there was one.
pub fn unregisterDevice(vector: u64) bool {
    const slot = deviceSlotOf(vector) orelse return false;
    if (device_registrations[slot].handler == null) return false;
    device_registrations[slot].handler = null;
    device_registrations[slot].name = "";
    return true;
}

/// The owner of a device vector, or null when it has none.
pub fn deviceName(vector: u64) ?[]const u8 {
    const slot = deviceSlotOf(vector) orelse return null;
    if (device_registrations[slot].handler == null) return null;
    return device_registrations[slot].name;
}

/// How many interrupts a device vector delivered to its owner.
pub fn deviceInterruptCount(vector: u64) u64 {
    const slot = deviceSlotOf(vector) orelse return 0;
    return device_registrations[slot].count;
}

/// How many device vectors have an owner.
pub fn registeredDeviceVectors() u64 {
    var total: u64 = 0;
    for (device_registrations) |registration| {
        if (registration.handler != null) total += 1;
    }
    return total;
}

/// How many device interrupts arrived without an owner.
pub fn unhandledDeviceCount() u64 {
    return unhandled_device_interrupts;
}

/// True when the vector is one that a device may name.
pub fn isDeviceVector(vector: u64) bool {
    return deviceSlotOf(vector) != null;
}

/// Delivers one device interrupt to its owner.
///
/// A vector without an owner is counted and **not** dispatched to a guess: the
/// interrupt has already been acknowledged by the caller, because a device that
/// repeats a message nobody serves is a storm that hides every other line.
pub fn dispatchDevice(vector: u64) bool {
    const slot = deviceSlotOf(vector) orelse return false;

    const registration = &device_registrations[slot];
    const handler = registration.handler orelse {
        unhandled_device_interrupts += 1;
        return false;
    };

    registration.count += 1;
    return handler(vector);
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
pub fn resetForTest() void {
    registrations = @splat(.{});
    unhandled_interrupts = 0;
    device_registrations = @splat(.{});
    unhandled_device_interrupts = 0;
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

test "a device vector dispatches to its owner and counts the interrupts" {
    resetForTest();
    defer resetForTest();

    const vector = first_device_vector;
    try registerDevice(vector, "virtio-blk", testHandler);
    try testing.expectEqualStrings("virtio-blk", deviceName(vector).?);
    try testing.expectEqual(@as(u64, 1), registeredDeviceVectors());

    test_handler_calls = 0;
    test_handler_answer = false;
    try testing.expect(!dispatchDevice(vector));
    try testing.expectEqual(@as(u64, 1), deviceInterruptCount(vector));
    try testing.expectEqual(@as(u64, 1), test_handler_calls);

    // The handler decides whether the interrupted task has to be preempted, and
    // the dispatcher returns that answer instead of swallowing it.
    test_handler_answer = true;
    try testing.expect(dispatchDevice(vector));
    try testing.expectEqual(@as(u64, 2), deviceInterruptCount(vector));

    // Removing the owner keeps the counter: the device delivered that many
    // interrupts while it was there.
    try testing.expect(unregisterDevice(vector));
    try testing.expect(deviceName(vector) == null);
    try testing.expectEqual(@as(u64, 0), registeredDeviceVectors());
    try testing.expectEqual(@as(u64, 2), deviceInterruptCount(vector));
}

test "a vector without an owner is counted and never dispatched to a guess" {
    resetForTest();
    defer resetForTest();

    test_handler_calls = 0;
    const vector = first_device_vector + 7;
    try testing.expect(!dispatchDevice(vector));
    try testing.expectEqual(@as(u64, 1), unhandledDeviceCount());
    try testing.expectEqual(@as(u64, 0), test_handler_calls);
    try testing.expectEqual(@as(u64, 0), deviceInterruptCount(vector));

    // An owner that comes later does not inherit the count of the interrupts
    // that arrived before it existed.
    try registerDevice(vector, "late", testHandler);
    try testing.expectEqual(@as(u64, 0), deviceInterruptCount(vector));
    _ = dispatchDevice(vector);
    try testing.expectEqual(@as(u64, 1), deviceInterruptCount(vector));
    try testing.expectEqual(@as(u64, 1), unhandledDeviceCount());
}

test "a device may not take a vector of the kernel or the spurious one" {
    resetForTest();
    defer resetForTest();

    // Every vector below the device range belongs to the kernel: exceptions,
    // hardware lines, the timer, the reschedule, the shootdown and the halt.
    for ([_]u64{ 0, 8, 31, 32, 47, 48, 64, 65, 66, 67 }) |vector| {
        try testing.expectError(error.VectorNotDeliverable, registerDevice(vector, "x", testHandler));
        try testing.expect(!isDeviceVector(vector));
        try testing.expect(!dispatchDevice(vector));
    }

    // 0xFF is the spurious vector of the local APIC: a device that names it is
    // asking the kernel to treat a real message as a controller defect.
    try testing.expect(!isDeviceVector(255));
    try testing.expectError(error.VectorNotDeliverable, registerDevice(255, "x", testHandler));

    // The first and the last of the range are deliverable.
    try registerDevice(first_device_vector, "first", testHandler);
    try registerDevice(first_device_vector + device_vector_count - 1, "last", testHandler);
    try testing.expectEqual(@as(u64, 2), registeredDeviceVectors());
}

test "a second owner of a device vector is refused" {
    resetForTest();
    defer resetForTest();

    const vector = first_device_vector + 3;
    try registerDevice(vector, "first", testHandler);
    try testing.expectError(error.AlreadyRegistered, registerDevice(vector, "second", testHandler));
    try testing.expectEqualStrings("first", deviceName(vector).?);

    // After the owner leaves, the vector can be given to somebody else.
    try testing.expect(unregisterDevice(vector));
    try registerDevice(vector, "second", testHandler);
    try testing.expectEqualStrings("second", deviceName(vector).?);
    // Removing a vector that never had an owner is not an error either.
    try testing.expect(!unregisterDevice(vector + 1));
}

test "the device range and the hardware range are disjoint" {
    resetForTest();
    defer resetForTest();

    // A vector in the hardware range must be dispatched as a line and never as
    // a device message, whatever the order in which the dispatcher asks.
    const line = first_hardware_vector + 1;
    try testing.expect(isDeviceVector(line) == false);
    try register(line, "keyboard", testHandler);
    try registerDevice(first_device_vector, "device", testHandler);

    _ = dispatch(line);
    try testing.expectEqual(@as(u64, 1), interruptCount(line));
    try testing.expectEqual(@as(u64, 0), deviceInterruptCount(first_device_vector));

    _ = dispatchDevice(first_device_vector);
    try testing.expectEqual(@as(u64, 1), deviceInterruptCount(first_device_vector));
    try testing.expectEqual(@as(u64, 1), interruptCount(line));
}
