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

//! Aggregated entry point of the architecture modules of the kernel.
//!
//! The modules are grouped so that the parts that do not depend on the
//! hardware can be compiled for the host, where their unit tests run.

pub const segment = @import("segment.zig");
pub const frame = @import("frame.zig");
pub const paging = @import("paging.zig");
pub const spinlock = @import("spinlock.zig");
pub const smp = @import("smp.zig");
pub const tlb = @import("tlb.zig");
pub const bda = @import("bda.zig");
pub const msi = @import("msi.zig");
pub const msix = @import("msix.zig");
pub const ap_trampoline = @import("ap_trampoline.zig");
pub const apic = @import("apic.zig");
pub const ioapic = @import("ioapic.zig");
pub const acpi = @import("acpi.zig");
pub const fpu = @import("fpu.zig");
pub const timer = @import("timer.zig");
pub const interrupt_registry = @import("interrupt_registry.zig");
pub const vector_pool = @import("vector_pool.zig");

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

// The unit tests of the modules live in the modules themselves, and this
// block is what brings them into the test binary.
//
// Without this reference, the test binary is built with **zero** tests,
// and it passes no matter what: a test that is green without running is
// not evidence of anything.
test {
    _ = @import("segment.zig");
    _ = @import("frame.zig");
    _ = @import("paging.zig");
    _ = @import("spinlock.zig");
    _ = @import("smp.zig");
    _ = @import("tlb.zig");
    _ = @import("bda.zig");
    _ = @import("msi.zig");
    _ = @import("msix.zig");
    _ = @import("ap_trampoline.zig");
    _ = @import("apic.zig");
    _ = @import("ioapic.zig");
    _ = @import("acpi.zig");
    _ = @import("pci.zig");
    _ = @import("virtio.zig");
    _ = @import("virtio_blk.zig");
    _ = @import("virtio_net.zig");
    _ = @import("fpu.zig");
    _ = @import("timer.zig");
    _ = @import("interrupt_registry.zig");
    _ = @import("vector_pool.zig");
}
