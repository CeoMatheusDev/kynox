//************************************************************************//
//  root.zig                                                              //
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

//! Aggregated entry point of the kernel modules that the host can test.

//! Aggregated entry point of the host tests of the task subsystem: the policy of
//! the scheduler, the scheduler itself, the wait queue and the mutex.
//!
//! The scheduler chooses the next task from the policy that lives in
//! `task/scheduler.zig`, and that policy reaches into `arch/` (the segment of
//! the task, the tables of the pages), into `ipc/` (the waits of the channels)
//! and into `fs/` (the files of the process). A module root inside `task/`
//! would therefore sit below the files it imports, and Zig refuses it. This
//! root sits at the top of the kernel tree, next to `host_root.zig`, for the
//! same reason.
//!
//! What the file does **not** do: it does not run the kernel. The switch of the
//! context is assembly behind the four symbols below, the timer is a port
//! write, and no test calls either. The tests exercise the policy — the queue,
//! the choice, the accounting of the virtual runtime — which is the part that
//! can be wrong without a processor noticing.

const Context = @import("task/context.zig").Context;

pub const lock = @import("task/lock.zig");
pub const policy = @import("task/policy.zig");
pub const scheduler = @import("task/scheduler.zig");
pub const wait_queue = @import("task/wait.zig");
pub const mutex = @import("task/mutex.zig");

// The four symbols that `arch/x86_64/task.s` defines for the real switch. The
// host build has no assembly, so the test binary defines them here: the
// preparation of a switch stores the pointers and the identifier of the next
// space, and the test reads the decision. Nothing jumps through these values.
export var kynox_current_context: *Context = undefined;
export var kynox_next_context: *Context = undefined;
export var kynox_kernel_stack_pointer: u64 = 0;
export var kynox_next_cr3: u64 = 0;
// The two symbols of the switch accounting, and the flag that tells the entry of
// a call that the task was left waiting. `task.s` and the assembly of the
// syscall own them in the kernel; the tests only need them to exist.
export var kynox_switch_count: u64 = 0;
export var kynox_switch_total: u64 = 0;
export var kynox_switch_cycles: u64 = 0;
export var kynox_switch_minimum: u64 = 0;
export var kynox_syscall_blocked: u64 = 0;

// The instructions that load the tables (GDT and TR) have no register form: the
// externs of `segment.zig` are defined by `segment.s` in the kernel. The host
// build has no assembly, so the test binary defines them here. They are only
// reached through `segment.installForCpu`, which the tests do call (through the
// entry of an AP), and a stub that does nothing is the honest definition on a
// processor that has no global descriptor table to load.
export fn kynox_gdt_load_data(selector: u16) void {
    _ = selector;
}
export fn kynox_gdt_load_code(selector: u16) void {
    _ = selector;
}
export fn kynox_load_gdt(pointer: *align(8) const anyopaque) void {
    _ = pointer;
}
export fn kynox_load_tss(selector: u16) void {
    _ = selector;
}
export fn kynox_store_gdt(pointer: *align(8) anyopaque) void {
    _ = pointer;
}

// The unit tests live in the module, and this block is what brings them into
// the binary. Without it the artifact would be built with zero tests and would
// pass no matter what.
test {
    _ = @import("task/lock.zig");
    _ = @import("task/policy.zig");
    _ = @import("task/scheduler.zig");
    _ = @import("task/wait.zig");
    _ = @import("task/mutex.zig");
}
