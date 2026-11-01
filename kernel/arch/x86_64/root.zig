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
pub const apic = @import("apic.zig");
pub const ioapic = @import("ioapic.zig");
pub const acpi = @import("acpi.zig");
pub const fpu = @import("fpu.zig");

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
    _ = @import("apic.zig");
    _ = @import("ioapic.zig");
    _ = @import("acpi.zig");
    _ = @import("pci.zig");
    _ = @import("virtio.zig");
    _ = @import("virtio_blk.zig");
    _ = @import("fpu.zig");
}
