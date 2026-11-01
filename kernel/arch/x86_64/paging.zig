//************************************************************************//
//  paging.zig                                                            //
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

//! The page tables of the kernel.
//!
//! The kernel replaces the page tables of the firmware with its own. The new
//! tables map only what the kernel needs:
//!
//!   * the image of the kernel, mapped by identity so that the code, the
//!     stack and the data keep their addresses;
//!   * the linear framebuffer, mapped by identity and without the cache, so
//!     that the memory of a device is not served from the cache of the
//!     processor;
//!   * the pages of the tasks that run in user mode, mapped with the bit
//!     that allows the access from the third level of privilege.
//!
//! Everything else is left unmapped. An access to a page that is not mapped
//! raises a page fault, which is the isolation that the kernel needs before
//! it can run untrusted code.
//!
//! The tables use four kilobyte pages for the kernel and two megabyte pages
//! for the framebuffer.

const std = @import("std");
const kynox = @import("kynox_shared");

const cpu = @import("cpu.zig");
const handoff = kynox.handoff;

/// Size of a small page.
pub const page_size: u64 = 4096;

/// Who invalidates a translation on the other processors.
///
/// Clearing an entry of a table changes what **this** processor translates; the
/// others keep the old answer in their TLB until somebody tells them, and a
/// stale entry is memory that stays reachable after the table says it is gone.
/// The hook is how this module asks for that without importing the APIC: the
/// boot installs `smp.flushRemotePage`, and the host tests of the tables run
/// with no hook at all, which is exactly a machine with one processor.
pub var remote_flush: ?*const fn (u64) void = null;

/// Installs (or removes, with null) the shootdown of the other processors.
pub fn installRemoteFlush(hook: ?*const fn (u64) void) void {
    remote_flush = hook;
}

/// Tells the other processors that the page is gone, when there is a way to.
fn flushRemote(virtual: u64) void {
    const hook = remote_flush orelse return;
    hook(virtual);
}

/// Size of a large page.
pub const large_page_size: u64 = 2 * 1024 * 1024;

/// The bits of an entry of a page table.
pub const Flags = struct {
    /// The page is present in the address space.
    pub const present: u64 = 1 << 0;
    /// The page may be written.
    pub const writable: u64 = 1 << 1;
    /// The page may be accessed by user mode.
    pub const user: u64 = 1 << 2;
    /// The write through caching policy.
    pub const write_through: u64 = 1 << 3;
    /// The page is not cached.
    pub const cache_disabled: u64 = 1 << 4;
    /// The entry refers to a large page.
    pub const large: u64 = 1 << 7;
    /// The page may not be executed.
    ///
    /// The bit is only meaningful when `EFER.NXE` is set: without the bit
    /// of the model specific register, bit 63 is reserved and a page table
    /// entry that carries it raises a page fault. `cpu.enableNoExecute`
    /// turns the support on before the kernel ever sets this bit.
    pub const no_execute: u64 = 1 << 63;

    /// The space owns the physical page of the entry.
    ///
    /// The processor ignores this bit. The kernel uses it to answer the one
    /// question a page table cannot answer by itself: when the entry is
    /// removed, does the physical page go back to the manager? A page that
    /// the kernel obtained for the space — the pages of an image, of a stack,
    /// of a buffer — is owned, and removing the entry returns it. A page that
    /// the kernel only maps — a static buffer of the image, a page that two
    /// spaces share — is not owned, and removing the entry leaves it alone.
    /// Freeing a page that the space does not own would return the memory of
    /// the kernel or of another space to the pool.
    pub const owned: u64 = 1 << 9;
};

/// The bits of an entry that hold the physical address of the page or of
/// the table.
///
/// The processor reserves the bits above the physical address width. The
/// mask stops at bit 51, which is the largest physical address of the
/// four level paging of x86-64, and leaves the permission bits — including
/// the no-execute bit of bit 63 — out of the address.
pub const address_mask: u64 = 0x000F_FFFF_FFFF_F000;

/// The permissions that the kernel gives to a page of the user mode.
///
/// A page is never writable and executable at the same time: the planner
/// refuses an image that asks for both, and the materializer asks for one
/// of the two.
pub const UserPageFlags = struct {
    /// The page may be written by the user mode.
    writable: bool = false,
    /// The page may be executed by the user mode.
    executable: bool = false,
};

/// A page table with 512 entries.
const PageTable = extern struct {
    entries: [512]u64 = @splat(0),
};

/// Number of level 2 tables that the kernel provides.
const level2_count = 8;

/// Number of level 1 tables that the kernel provides.
///
/// A level 1 table describes two megabytes, therefore the pool describes
/// `level1_count` times two megabytes of kernel mappings. The image of the
/// kernel grows, and a table that cannot describe the whole image makes the
/// kernel unable to boot, so the pool is sized with room to grow. The DMA
/// window reserves 32 tables of its own (64 MiB); the rest is left for the
/// image, the device pages and future kernel mappings.
const level1_count = 64;

/// Number of address spaces of the processes that the kernel supports.
pub const max_process_spaces = 8;

/// The root tables of the address spaces of the processes.
///
/// A process has an address space of its own: the root table of the space
/// holds the tables of the kernel — copied from the tables of the kernel, so
/// that the image and the framebuffer stay visible in both directions of the
/// switch — and a private chain that reaches the window of the user mode.
/// Two processes therefore never share a mapping of the pages of the user,
/// and that is what makes the copy between two processes a real copy.
var process_root_pool: [max_process_spaces]PageTable align(4096) = @splat(.{});

/// The private third level tables of the address spaces of the processes.
var process_level3_pool: [max_process_spaces]PageTable align(4096) = @splat(.{});

/// The private second level tables of the address spaces of the processes.
var process_level2_pool: [max_process_spaces]PageTable align(4096) = @splat(.{});

/// The private first level tables with the pages of the user mode.
var process_level1_pool: [max_process_spaces]PageTable align(4096) = @splat(.{});

/// The address spaces that the kernel handed out.
var process_spaces: [max_process_spaces]AddressSpace = @splat(.{});

/// The number of address spaces that the kernel handed out since it started.
///
/// The counter is cumulative: releasing a space does not lower it. It exists
/// for the diagnostics and for the tests, not for the allocation.
var spaces_created: u32 = 0;

/// An address space of a process.
///
/// The space holds the tables of the kernel and the private chain of the
/// window of the user mode. The address of the space is stable, because the
/// root table is referred to by pointer.
pub const AddressSpace = struct {
    /// The root table of the space.
    root: *PageTable = undefined,
    /// The private table of the third level.
    level3: *PageTable = undefined,
    /// The private table of the second level, the one of the window.
    level2: *PageTable = undefined,
    /// The private table of the first level, the one of the window.
    level1: *PageTable = undefined,
    /// The identifier of the process that owns the space.
    ///
    /// The identifier is the index of the slot, because that is the number
    /// that the system call interface uses to name a process, and the number
    /// that indexes the set of capabilities of a process (eight of them, the
    /// same `max_process_spaces`). It is therefore bounded, and it is handed
    /// out again when a slot is reused.
    id: u32 = 0,
    /// The generation of the identifier.
    ///
    /// Every time the slot is handed out the generation grows, so an identity
    /// is the pair (id, generation) and not the id alone. A caller that kept
    /// the identity of a reaped process compares the generation and refuses
    /// to act on the process that received the same slot afterwards.
    generation: u32 = 0,
    /// True while the space is handed out by `createAddressSpace`.
    live: bool = false,
};

// The number of pages of a window of the user mode is not a constant of the
// tables: the window is a range that the loader plans and the materialiser
// maps (`shared/usermode.zig` owns its size). A constant here would be a second
// source of truth, and the one that the tables used to carry was already wrong.

/// The level 4 table, the root of the hierarchy.
var level4: PageTable align(4096) = .{};

/// The level 3 table.
var level3: PageTable align(4096) = .{};

/// The level 2 tables, one for each gigabyte of the address space.
var level2_pool: [level2_count]PageTable align(4096) = @splat(.{});

/// The level 1 tables, one for each two megabytes of the address space.
var level1_pool: [level1_count]PageTable align(4096) = @splat(.{});

/// The next level 2 table that is handed out.
var level2_used: usize = 0;

/// The next level 1 table that is handed out.
var level1_used: usize = 0;

/// Errors reported while building the tables.
pub const Error = error{
    /// The tables cannot describe the requested range.
    RangeTooLarge,
    /// The kernel does not have enough tables for the requested mapping.
    OutOfTables,
    /// The address is not aligned to the size of a page.
    UnalignedPage,
    /// The page that the caller asked to protect is not mapped for the user.
    NotMapped,
    /// The page is already mapped: substituicao silenciosa nao permitida.
    AlreadyMapped,
    /// The entry owns a page, but no release callback is installed, so the
    /// page cannot be returned. The entry is preserved.
    ReleaseUnavailable,
};

/// Maps a page of the kernel, with the same address in the physical and in
/// the virtual address space.
pub fn mapKernelPage(virtual: u64, physical: u64) Error!void {
    return mapPage(virtual, physical, Flags.present | Flags.writable);
}

/// Maps a page that the tasks in user mode may access.
pub fn mapUserPage(virtual: u64, physical: u64) Error!void {
    return mapPage(virtual, physical, Flags.present | Flags.writable | Flags.user);
}

/// Maps a page of a device.
///
/// The page is writable and is not cached: a device register that the
/// processor keeps in the cache would not observe the updates that the
/// hardware makes, and a write could be merged with a later one. The page
/// is also marked as not executable, because a device register is data and
/// never an instruction stream.
pub fn mapDevicePage(virtual: u64, physical: u64) Error!void {
    return mapPage(
        virtual,
        physical,
        Flags.present | Flags.writable | Flags.cache_disabled | Flags.no_execute,
    );
}

/// Maps a page of kernel data that is never executed.
///
/// A DMA buffer is data. Mapping it with the no-execute bit keeps a device
/// that writes attacker-controlled bytes from turning those bytes into a
/// kernel instruction stream.
pub fn mapKernelDataPage(virtual: u64, physical: u64) Error!void {
    return mapPage(
        virtual,
        physical,
        Flags.present | Flags.writable | Flags.no_execute,
    );
}

/// Ensures that the level 1 table that describes `virtual` exists.
///
/// The function only builds the hierarchy; it does not make the page
/// present. A range that was reserved before the address spaces of the
/// processes were created shares its level 1 table with those spaces,
/// because `createAddressSpace` copies the level 2 entry that points at it.
fn ensureLevel1(virtual: u64) Error!*PageTable {
    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;
    const level2_index = (virtual >> 21) & 511;

    // The kernel only uses the first 512 gigabytes of the address space,
    // which is the range described by level 4 entry zero.
    if (level4_index != 0) return error.RangeTooLarge;

    if (level4.entries[level4_index] & Flags.present == 0) {
        level4.entries[level4_index] = addressOf(&level3) | table_flags;
    }
    if (level3.entries[level3_index] & Flags.present == 0) {
        const table = allocateLevel2() orelse return error.OutOfTables;
        level3.entries[level3_index] = addressOf(table) | table_flags;
    }

    const level2 = tableOf(level3.entries[level3_index]);
    const entry2 = level2.entries[level2_index];
    if (entry2 & Flags.present != 0 and entry2 & Flags.large != 0) {
        // The range is already covered by a large page, and a small page
        // cannot be carved out of it without changing the mapping of the
        // whole block.
        return error.RangeTooLarge;
    }
    if (entry2 & Flags.present == 0) {
        const table = allocateLevel1() orelse return error.OutOfTables;
        level2.entries[level2_index] = addressOf(table) | table_flags;
    }

    return tableOf(level2.entries[level2_index]);
}

/// Maps a page.
///
/// The entries of the upper levels always carry the bit that allows the
/// access from the user mode: the processor checks the bit in every level,
/// and only the entry of the page itself decides whether the access is
/// allowed. The pages of the kernel do not have the bit, therefore they
/// stay inaccessible from the user mode.
fn mapPage(virtual: u64, physical: u64, flags: u64) Error!void {
    // The entries of the table describe pages, and the low bits of the
    // address are not part of the entry: an unaligned address would be
    // silently rounded down, and the page that the caller asked for would
    // not be the page that the tables describe.
    if (virtual & (page_size - 1) != 0) return error.UnalignedPage;
    if (physical & (page_size - 1) != 0) return error.UnalignedPage;

    const level1 = try ensureLevel1(virtual);
    const level1_index = (virtual >> 12) & 511;
    // Nao substitui silenciosamente um mapeamento existente.
    const existing = level1.entries[level1_index];
    if (existing & 1 != 0) return error.AlreadyMapped;
    level1.entries[level1_index] = (physical & address_mask) | flags;
}

/// Reserves the page tables of a kernel virtual range without mapping pages.
///
/// The function is used for the DMA window. It must run before the address
/// spaces of the processes are created: `createAddressSpace` copies the
/// level 2 table of the kernel, and a level 1 table allocated later would
/// not be visible through the copy.
pub fn reserveKernelRange(virtual: u64, length: u64) Error!void {
    if (length == 0) return;
    if (virtual & (page_size - 1) != 0) return error.UnalignedPage;

    const end = std.math.add(u64, virtual, length) catch return error.RangeTooLarge;
    if (end <= virtual) return error.RangeTooLarge;

    var address = virtual;
    while (address < end) {
        _ = try ensureLevel1(address);

        const chunk_start = (address >> 21) << 21;
        const chunk_limit = std.math.add(u64, chunk_start, large_page_size) catch
            return error.RangeTooLarge;
        const next = @min(end, chunk_limit);
        if (next <= address) return error.RangeTooLarge;
        address = next;
    }
}

/// Removes one small page mapping of the kernel.
///
/// The TLB entry of the current processor is invalidated, and the other
/// processors are told through the hook that the boot installs
/// (`installRemoteFlush`). Without a hook — a machine with one processor, or a
/// host test — the invalidation is local and that is the whole story.
pub fn unmapKernelPage(virtual: u64) Error!void {
    if (virtual & (page_size - 1) != 0) return error.UnalignedPage;

    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    if (level4_index != 0) return error.NotMapped;
    const entry4 = level4.entries[level4_index];
    if (entry4 & Flags.present == 0) return error.NotMapped;

    const entry3 = tableOf(entry4).entries[level3_index];
    if (entry3 & Flags.present == 0) return error.NotMapped;

    const entry2 = tableOf(entry3).entries[level2_index];
    if (entry2 & Flags.present == 0) return error.NotMapped;
    if (entry2 & Flags.large != 0) return error.NotMapped;

    const level1 = tableOf(entry2);
    if (level1.entries[level1_index] & Flags.present == 0) return error.NotMapped;
    level1.entries[level1_index] = 0;
    cpu.invlpg(virtual);
    flushRemote(virtual);
}

/// Translates a virtual address in the address space of the kernel.
pub fn translate(virtual: u64) ?u64 {
    return translateFrom(&level4, virtual);
}

/// Translates a virtual address in the address space of a process.
pub fn translateIn(space: *const AddressSpace, virtual: u64) ?u64 {
    return translateFrom(space.root, virtual);
}

fn translateFrom(root: *const PageTable, virtual: u64) ?u64 {
    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    const entry4 = root.entries[level4_index];
    if (entry4 & Flags.present == 0) return null;

    const entry3 = tableOf(entry4).entries[level3_index];
    if (entry3 & Flags.present == 0) return null;

    const entry2 = tableOf(entry3).entries[level2_index];
    if (entry2 & Flags.present == 0) return null;
    if (entry2 & Flags.large != 0) {
        return (entry2 & address_mask) | (virtual & (large_page_size - 1));
    }

    const entry1 = tableOf(entry2).entries[level1_index];
    if (entry1 & Flags.present == 0) return null;
    return (entry1 & address_mask) | (virtual & (page_size - 1));
}

/// The attributes of the entries of the upper levels of the hierarchy.
const table_flags: u64 = Flags.present | Flags.writable | Flags.user;

/// Maps a range of large pages of the kernel.
fn mapLargeRange(virtual: u64, length: u64, flags: u64) Error!void {
    if (length == 0) return;

    // The end of the range is computed with the check of the overflow: a
    // range that wraps would describe the pages before the start, and the
    // loop would write them.
    const end = std.math.add(u64, virtual, length) catch return error.RangeTooLarge;
    if (end <= virtual) return error.RangeTooLarge;

    const last_end = std.math.add(u64, end, large_page_size - 1) catch
        return error.RangeTooLarge;
    const first = virtual / large_page_size;
    const last = last_end / large_page_size;

    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;

    if (level4_index != 0) return error.RangeTooLarge;

    // The table of the second level is the one of the gigabyte of the
    // start, and every entry of the loop is written in that table. A range
    // that crosses the boundary of a gigabyte would write the entries of
    // the second gigabyte in the table of the first one, and the mapping
    // would land in the wrong address: the range is refused.
    if (level3_index != ((end - 1) >> 30) & 511) return error.RangeTooLarge;

    if (level4.entries[level4_index] & Flags.present == 0) {
        level4.entries[level4_index] = addressOf(&level3) | table_flags;
    }
    if (level3.entries[level3_index] & Flags.present == 0) {
        const table = allocateLevel2() orelse return error.OutOfTables;
        level3.entries[level3_index] = addressOf(table) | table_flags;
    }

    const level2 = tableOf(level3.entries[level3_index]);
    var large = first;
    while (large < last) : (large += 1) {
        // The entry of a large page lives in the table of the second level,
        // and its index is the index of the page of two megabytes inside
        // that table. The index of the page in the whole address space is
        // not the same one, and using it writes the entry in the wrong
        // place as soon as the range is not inside the first gigabyte of
        // its own table.
        const address = large * large_page_size;
        const level2_index = (address >> 21) & 511;

        if (level2.entries[level2_index] & Flags.present != 0) {
            // The entry is already described by another mapping, and the
            // kernel does not overwrite a mapping that it did not build.
            if (level2.entries[level2_index] & Flags.large == 0) {
                return error.RangeTooLarge;
            }
            continue;
        }

        level2.entries[level2_index] = address | flags | Flags.large;
    }
}

/// Maps a range of the kernel by identity, with small pages.
///
/// A table of the first level describes two megabytes, therefore a range
/// that is larger than that needs more than one table, and a range that
/// crosses the boundary of two megabytes needs the table of the chunk that
/// follows. The function walks the range and hands out a table for every
/// chunk, so that the image of the kernel is described as a whole and not
/// only its first two megabytes.
///
/// The limit of a single table was a defect: the image of the kernel grows
/// with every increment, and a kernel that is not able to describe its own
/// image does not boot at all.
fn mapKernelRange(virtual: u64, length: u64) Error!void {
    if (length == 0) return;

    const end = std.math.add(u64, virtual, length) catch return error.RangeTooLarge;
    if (end < virtual) return error.RangeTooLarge;

    var address = virtual;
    while (address < end) {
        const level4_index = (address >> 39) & 511;
        const level3_index = (address >> 30) & 511;
        const level2_index = (address >> 21) & 511;

        // The kernel only uses the first gigabyte of the address space for
        // the tables of the hierarchy, which covers 512 gigabytes.
        if (level4_index != 0) return error.RangeTooLarge;

        if (level4.entries[level4_index] & Flags.present == 0) {
            level4.entries[level4_index] = addressOf(&level3) | table_flags;
        }
        if (level3.entries[level3_index] & Flags.present == 0) {
            const table = allocateLevel2() orelse return error.OutOfTables;
            level3.entries[level3_index] = addressOf(table) | table_flags;
        }

        const level2 = tableOf(level3.entries[level3_index]);
        if (level2.entries[level2_index] & Flags.present == 0) {
            const table = allocateLevel1() orelse return error.OutOfTables;
            level2.entries[level2_index] = addressOf(table) | table_flags;
        }

        const level1 = tableOf(level2.entries[level2_index]);

        // The table of the first level covers the chunk of two megabytes
        // that holds the address, and the walk stops at the end of the
        // chunk or at the end of the range. The end of the chunk is
        // computed with the check of the overflow: a range near the end of
        // the address space would wrap, and the walk would stop before it
        // starts.
        const chunk_start = (address >> 21) << 21;
        const chunk_limit = std.math.add(u64, chunk_start, large_page_size) catch
            return error.RangeTooLarge;
        const chunk_end = @min(end, chunk_limit);

        while (address < chunk_end) : (address += page_size) {
            const index = (address >> 12) & 511;
            level1.entries[index] = (address & address_mask) | Flags.present | Flags.writable;
        }
    }
}

/// Prepares the tables of the kernel.
///
/// The image of the kernel is mapped by identity with small pages, the
/// framebuffer with large pages and without the cache.
pub fn setup(
    kernel_base: u64,
    kernel_end: u64,
    framebuffer_base: u64,
    framebuffer_size: u64,
) Error!void {
    level4 = .{};
    level3 = .{};
    level2_pool = @splat(.{});
    level1_pool = @splat(.{});
    level2_used = 0;
    level1_used = 0;

    // The kernel image, by identity, with small pages.
    //
    // The image is described as a whole: the range can be larger than the
    // two megabytes of a single table of the first level, and the function
    // hands out a table for every chunk that the range covers.
    if (kernel_end < kernel_base) return error.RangeTooLarge;
    try mapKernelRange(kernel_base, kernel_end - kernel_base);

    // The framebuffer, by identity, with large pages and without the cache.
    if (framebuffer_base != 0 and framebuffer_size != 0) {
        try mapLargeRange(
            framebuffer_base,
            framebuffer_size,
            Flags.present | Flags.writable | Flags.cache_disabled,
        );
    }
}

/// Makes the tables of the kernel the active ones.
pub fn activate() void {
    active_space = null;
    cpu.writeCr3(addressOf(&level4));
}

/// The address of the root table, used for the diagnostics.
pub fn rootAddress() u64 {
    return addressOf(&level4);
}

/// Creates an address space for a process.
///
/// The space starts as a copy of the space of the kernel: the image of the
/// kernel and the framebuffer stay mapped in the space of the process,
/// because the kernel runs in the space of the process that it interrupted,
/// and because the stack of the kernel of the task lives in the image. The
/// window of the user mode is the only region that the process owns, and it
/// starts empty.
///
/// The window has to live in the first gigabyte of the address space, the
/// same region where the image of the kernel is mapped, and it has to use a
/// table of the second level of its own. The kernel checks the placement
/// before it calls the function, and the function refuses a window that
/// does not satisfy the requirement.
pub fn createAddressSpace(window: u64) ?*AddressSpace {
    // The window lives in the first gigabyte, and the table of the second
    // level of the first gigabyte holds the image of the kernel. The window
    // needs a table of the first level of its own, and the table of the
    // second level of the space is a copy of the one of the kernel.
    const level3_index = (window >> 30) & 511;
    const level2_index = (window >> 21) & 511;
    if (level3_index != 0) return null;

    // A released slot is handed out again with a new identifier: the tables
    // are rewritten from the tables of the kernel below, so nothing of the
    // previous process survives, and the identifier tells the two processes
    // apart for every caller that kept the old one.
    const index = freeSpaceSlot() orelse return null;

    const space = &process_spaces[index];
    // The generation is preserved across the reuse of the slot, and zero is
    // never handed out, so a field that was never written cannot be mistaken
    // for a live identity.
    var generation = space.generation +% 1;
    if (generation == 0) generation = 1;
    const root = &process_root_pool[index];
    const private_level3 = &process_level3_pool[index];
    const private_level2 = &process_level2_pool[index];
    const private_level1 = &process_level1_pool[index];

    // The private tables start as a copy of the tables of the kernel, so
    // that the image of the kernel and the framebuffer stay mapped in the
    // space of the process.
    root.* = level4;
    private_level3.* = level3;
    private_level2.* = tableOf(level3.entries[0]).*;

    // The window of the user mode has a table of the first level of its
    // own, and the entry of the table of the second level of the space
    // points at it.
    private_level1.* = .{};
    private_level2.entries[level2_index] = addressOf(private_level1) | table_flags;

    // The root table of the space points at the private table of the third
    // level, and the private table of the third level at the private table
    // of the second level.
    root.entries[0] = addressOf(private_level3) | table_flags;
    private_level3.entries[0] = addressOf(private_level2) | table_flags;

    space.* = .{
        .root = root,
        .level3 = private_level3,
        .level2 = private_level2,
        .level1 = private_level1,
        .id = @intCast(index),
        .generation = generation,
        .live = true,
    };

    spaces_created += 1;

    return space;
}

/// The first slot that is not handed out, or null when the pool is full.
fn freeSpaceSlot() ?usize {
    for (&process_spaces, 0..) |*space, index| {
        if (!space.live) return index;
    }
    return null;
}

/// The number of spaces that are currently handed out.
pub fn liveSpaceCount() usize {
    var count: usize = 0;
    for (process_spaces) |space| {
        if (space.live) count += 1;
    }
    return count;
}

/// Maps a page of the user mode in the space of a process.
///
/// The page is mapped with the bit that allows the access from the third
/// level of privilege, and the table of the first level of the space is the
/// one that receives the entry. The legacy form keeps the page writable and
/// executable, which is what the embedded program of the first processes
/// used; a process loaded from an ELF uses `mapUserPageInFlags` and gets
/// the permissions of the segment.
pub fn mapUserPageIn(space: *AddressSpace, virtual: u64, physical: u64) Error!void {
    return mapUserPageInFlags(space, virtual, physical, .{
        .writable = true,
        .executable = true,
    });
}

/// Maps a page of the user mode with explicit permissions.
///
/// The caller is responsible for the temporary permissions of a page that
/// receives a copy: a page of code is mapped writable and **not**
/// executable while the kernel copies the file into it, and is protected
/// with `protectUserPageIn` before the task starts. The function does not
/// flush the TLB; a page that is mapped for the first time has no stale
/// entry, and a page whose permissions change has to be protected.
pub fn mapUserPageInFlags(
    space: *AddressSpace,
    virtual: u64,
    physical: u64,
    flags: UserPageFlags,
) Error!void {
    if (virtual & (page_size - 1) != 0) return error.UnalignedPage;
    if (physical & (page_size - 1) != 0) return error.UnalignedPage;

    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    const entry = space.level2.entries[level2_index];
    if (entry & Flags.present == 0) return error.OutOfTables;
    if (entry & Flags.large != 0) return error.OutOfTables;

    // The entry of the second level has to point at the table of the first
    // level of the space. A virtual address outside the window lands in a
    // table of the kernel, and writing the entry in the private table would
    // report a success for a page that the space does not describe.
    if ((entry & address_mask) != addressOf(space.level1)) {
        return error.OutOfTables;
    }

    space.level1.entries[level1_index] = (physical & address_mask) | userPageEntryFlags(flags);
}

/// Changes the permissions of a page that is already mapped for the user.
///
/// The physical address and the presence of the page are preserved, and the
/// TLB entry of the address is invalidated: the processor may have cached
/// the old permissions when the kernel copied the content of the page.
pub fn protectUserPageIn(
    space: *AddressSpace,
    virtual: u64,
    flags: UserPageFlags,
) Error!void {
    if (virtual & (page_size - 1) != 0) return error.UnalignedPage;

    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    const entry2 = space.level2.entries[level2_index];
    if (entry2 & Flags.present == 0) return error.OutOfTables;
    if (entry2 & Flags.large != 0) return error.OutOfTables;
    if ((entry2 & address_mask) != addressOf(space.level1)) {
        return error.OutOfTables;
    }

    const entry1 = space.level1.entries[level1_index];
    if (entry1 & Flags.present == 0 or entry1 & Flags.user == 0) {
        return error.NotMapped;
    }

    // The ownership is a fact about the page, not about the permissions, and
    // it survives a change of permissions.
    space.level1.entries[level1_index] =
        (entry1 & address_mask) | (entry1 & Flags.owned) | userPageEntryFlags(flags);
    cpu.invlpg(virtual);
}

/// Makes the space the owner of the page of a mapping.
///
/// The materialiser calls the function once the whole image is in place: from
/// that moment removing the mapping returns the page to the manager, and the
/// space is responsible for it. A partial load does not take ownership, so its
/// failure path keeps freeing the pages that it allocated itself.
///
/// The permissions are preserved; only the software bit that records the
/// ownership changes.
pub fn takeOwnership(space: *AddressSpace, virtual: u64) Error!void {
    if (virtual & (page_size - 1) != 0) return error.UnalignedPage;

    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    const entry2 = space.level2.entries[level2_index];
    if (entry2 & Flags.present == 0) return error.OutOfTables;
    if (entry2 & Flags.large != 0) return error.OutOfTables;
    if ((entry2 & address_mask) != addressOf(space.level1)) {
        return error.OutOfTables;
    }

    const entry1 = space.level1.entries[level1_index];
    if (entry1 & Flags.present == 0 or entry1 & Flags.user == 0) {
        return error.NotMapped;
    }

    space.level1.entries[level1_index] = entry1 | Flags.owned;
}

/// Removes the mapping of a page of the user mode.
///
/// The materializer uses the function when it has to undo a partial load.
/// The TLB entry is invalidated before the page goes back to the allocator, so
/// that the processor cannot keep writing through a stale translation.
///
/// When the entry owns its page (`Flags.owned`) the function returns the page
/// through the release callback, because the caller asked to remove the only
/// reference that existed. A page that the space does not own stays allocated:
/// it belongs to the kernel image or to another space. Without a callback the
/// function refuses to remove an owned entry, so that the page is not lost
/// silently.
pub fn unmapUserPageIn(space: *AddressSpace, virtual: u64) Error!void {
    if (virtual & (page_size - 1) != 0) return error.UnalignedPage;

    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    const entry2 = space.level2.entries[level2_index];
    if (entry2 & Flags.present == 0) return error.OutOfTables;
    if (entry2 & Flags.large != 0) return error.OutOfTables;
    if ((entry2 & address_mask) != addressOf(space.level1)) {
        return error.OutOfTables;
    }

    const entry1 = space.level1.entries[level1_index];
    if (entry1 & Flags.present == 0 or entry1 & Flags.user == 0) {
        return error.NotMapped;
    }

    if (entry1 & Flags.owned != 0) {
        const hook = page_release_hook orelse return error.ReleaseUnavailable;
        // The entry is cleared before the page returns to the pool, and the
        // TLB entry goes with it: a page that is reachable after the return
        // would be used by the next owner before this space stopped writing
        // to it.
        space.level1.entries[level1_index] = 0;
        cpu.invlpg(virtual);
        flushRemote(virtual);
        hook(entry1 & address_mask);
        return;
    }

    space.level1.entries[level1_index] = 0;
    cpu.invlpg(virtual);
    flushRemote(virtual);
}

/// Reads the permissions of a mapped page of the user mode.
///
/// The function is the verification side of the materializer: the boot
/// report reads the entries that the hardware will use, instead of trusting
/// the flags that the caller asked for.
pub fn permissionsIn(space: *const AddressSpace, virtual: u64) ?UserPageFlags {
    if (virtual & (page_size - 1) != 0) return null;

    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    const entry2 = space.level2.entries[level2_index];
    if (entry2 & Flags.present == 0) return null;
    if (entry2 & Flags.large != 0) return null;
    if ((entry2 & address_mask) != addressOf(space.level1)) return null;

    const entry1 = space.level1.entries[level1_index];
    if (entry1 & Flags.present == 0 or entry1 & Flags.user == 0) return null;

    return .{
        .writable = entry1 & Flags.writable != 0,
        .executable = entry1 & Flags.no_execute == 0,
    };
}

/// Encodes the permissions of a page of the user mode.
fn userPageEntryFlags(flags: UserPageFlags) u64 {
    var entry = Flags.present | Flags.user;
    if (flags.writable) entry |= Flags.writable;
    if (!flags.executable) entry |= Flags.no_execute;
    return entry;
}

/// Makes the space of a process the active one.
pub fn activateSpace(space: *const AddressSpace) void {
    active_space = space;
    cpu.writeCr3(addressOf(space.root));
}

/// The address space that is active.
///
/// The function returns null when the space of the kernel is the active one,
/// which is the space of the tasks of the kernel.
pub fn activeSpace() ?*const AddressSpace {
    return active_space;
}

/// Records the address space that is active, without writing the register
/// of the tables.
///
/// The scheduler uses the function when it hands the space of the entering
/// task to the switch: the switch writes the register of the tables, and
/// the module has to know which space is the active one.
pub fn setActiveSpace(space: ?*const AddressSpace) void {
    active_space = space;
}

/// The address space that is active.
var active_space: ?*const AddressSpace = null;

/// The address of the root table of the space of a process.
pub fn spaceRoot(space: *const AddressSpace) u64 {
    return addressOf(space.root);
}

/// The address space of a process, by its identifier.
///
/// The identifier is the index of the slot, so it is bounded by
/// `max_process_spaces` and it is handed out again after a reap. While the slot
/// is free the identifier resolves to nothing; after the reuse it resolves to
/// the new process, which is why a caller that has to survive a reap compares
/// the generation with `spaceByIdentity`.
pub fn spaceById(id: u64) ?*AddressSpace {
    if (id >= max_process_spaces) return null;
    const space = &process_spaces[@intCast(id)];
    if (!space.live) return null;
    return space;
}

/// The address space of a process identity: the identifier and the
/// generation that the space received when the slot was handed out.
///
/// The function is the strict form: it returns null when the slot exists, is
/// live and belongs to another generation, which is what a caller that kept an
/// identity across a reap has to check before it writes in a space that is no
/// longer the one it knew.
pub fn spaceByIdentity(id: u64, generation: u32) ?*AddressSpace {
    const space = spaceById(id) orelse return null;
    if (space.generation != generation) return null;
    return space;
}

/// The identity of the space of a process, for the diagnostics and for the
/// handles that have to survive a reap.
pub const Identity = struct {
    id: u32,
    generation: u32,
};

/// The identity of a space.
pub fn identityOf(space: *const AddressSpace) Identity {
    return .{ .id = space.id, .generation = space.generation };
}

/// Checks whether a range of virtual addresses belongs to the user mode in
/// the space of a process.
///
/// The function walks the private tables of the space and verifies that
/// every page of the range is present, that the page carries the bit of
/// user, and that the page is writable when the range has to be written.
pub fn isUserRangeIn(
    space: *const AddressSpace,
    virtual: u64,
    length: u64,
    writable: bool,
) bool {
    if (length == 0) return false;

    const end = std.math.add(u64, virtual, length) catch return false;
    if (end < virtual) return false;

    var address = virtual;
    while (address < end) {
        if (!isUserPageIn(space, address, writable)) return false;

        const next = std.math.add(u64, address, page_size) catch return false;
        if (next <= address) return false;
        address = next;
    }

    return true;
}

/// Checks whether a virtual address is in a page of the user mode in the
/// space of a process.
fn isUserPageIn(space: *const AddressSpace, virtual: u64, writable: bool) bool {
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    const entry2 = space.level2.entries[level2_index];
    if (entry2 & Flags.present == 0) return false;
    if (entry2 & Flags.large != 0) return false;

    // The address is only in the space of the process when the entry of
    // the second level is the private table of the window: the entry of
    // another table belongs to the kernel, and the same index of the
    // private table would answer for a page that the space does not have.
    if ((entry2 & address_mask) != addressOf(space.level1)) return false;

    const entry1 = space.level1.entries[level1_index];
    if (entry1 & Flags.present == 0) return false;
    if (entry1 & Flags.user == 0) return false;
    if (writable and entry1 & Flags.writable == 0) return false;

    return true;
}

/// Describes the mapping of a virtual address.
///
/// The function walks the hierarchy of the tables and reports the entry of
/// every level, so that a wrong mapping can be found without a debugger.
pub fn describe(virtual: u64) void {
    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    const entry4 = level4.entries[level4_index];
    kynox.serial.printLine("[DBG] map 0x{x}: l4[{d}] = 0x{x}", .{ virtual, level4_index, entry4 });
    if (entry4 & Flags.present == 0) return;

    const entry3 = tableOf(entry4).entries[level3_index];
    kynox.serial.printLine("[DBG]        l3[{d}] = 0x{x}", .{ level3_index, entry3 });
    if (entry3 & Flags.present == 0) return;

    const entry2 = tableOf(entry3).entries[level2_index];
    kynox.serial.printLine("[DBG]        l2[{d}] = 0x{x}", .{ level2_index, entry2 });
    if (entry2 & Flags.present == 0) return;
    if (entry2 & Flags.large != 0) {
        kynox.serial.printLine("[DBG]        large page", .{});
        return;
    }

    const entry1 = tableOf(entry2).entries[level1_index];
    kynox.serial.printLine("[DBG]        l1[{d}] = 0x{x} (physical 0x{x}, user {})", .{
        level1_index,
        entry1,
        entry1 & address_mask,
        (entry1 & Flags.user) != 0,
    });
}

/// Checks whether a range of virtual addresses belongs to the user mode.
///
/// The function walks the hierarchy of the tables and verifies that every
/// page of the range is present, that the page carries the bit of user, and
/// that the page is writable when the range has to be written. A range of
/// zero length is never valid.
///
/// When a process is running, the check walks the tables of the space of the
/// process, because the pages of the user mode live in that space and in no
/// other. The kernel uses the function before it touches a buffer that the
/// user mode handed over: a user program can point to any address, and the
/// kernel may not trust it.
pub fn isUserRange(virtual: u64, length: u64, writable: bool) bool {
    if (active_space) |space| {
        return isUserRangeIn(space, virtual, length, writable);
    }

    if (length == 0) return false;

    // The end of the range is exclusive, and the addition is checked
    // because an overflow would make the range look valid.
    const end = std.math.add(u64, virtual, length) catch return false;
    if (end < virtual) return false;

    var address = virtual;
    while (address < end) {
        if (!isUserPage(address, writable)) return false;

        // The next page, without overflow at the end of the space.
        const next = std.math.add(u64, address, page_size) catch return false;
        if (next <= address) return false;
        address = next;
    }

    return true;
}

/// Checks whether a virtual address is in a page of the user mode.
fn isUserPage(virtual: u64, writable: bool) bool {
    const level4_index = (virtual >> 39) & 511;
    const level3_index = (virtual >> 30) & 511;
    const level2_index = (virtual >> 21) & 511;
    const level1_index = (virtual >> 12) & 511;

    const entry4 = level4.entries[level4_index];
    if (entry4 & Flags.present == 0) return false;

    const entry3 = tableOf(entry4).entries[level3_index];
    if (entry3 & Flags.present == 0) return false;

    const entry2 = tableOf(entry3).entries[level2_index];
    if (entry2 & Flags.present == 0) return false;
    if (entry2 & Flags.large != 0) {
        // A large page of the user mode covers the whole range, and the
        // kernel never maps one for the user.
        return entry2 & Flags.user != 0 and (!writable or entry2 & Flags.writable != 0);
    }

    const entry1 = tableOf(entry2).entries[level1_index];
    if (entry1 & Flags.present == 0) return false;
    if (entry1 & Flags.user == 0) return false;
    if (writable and entry1 & Flags.writable == 0) return false;

    return true;
}

/// Reserves a level 2 table.
fn allocateLevel2() ?*PageTable {
    if (level2_used >= level2_count) return null;
    const table = &level2_pool[level2_used];
    level2_used += 1;
    return table;
}

/// Reserves a level 1 table.
fn allocateLevel1() ?*PageTable {
    if (level1_used >= level1_count) return null;
    const table = &level1_pool[level1_used];
    level1_used += 1;
    return table;
}

/// Returns the table that an entry of a higher level points at.
fn tableOf(entry: u64) *PageTable {
    const address = entry & address_mask;
    return @ptrFromInt(address);
}

/// The physical address of a table.
fn addressOf(table: *const PageTable) u64 {
    return @intFromPtr(table);
}

const testing = std.testing;

test "the mapping of the window refuses an address outside the window" {
    try setup(0x200000, 0x300000, 0, 0);
    resetAddressSpacesForTest();

    const window: u64 = 0x200000 - 0x4000;
    const space = createAddressSpace(window).?;

    // The three pages of the window.
    try mapUserPageIn(space, window, 0x400000);
    try mapUserPageIn(space, window + page_size, 0x401000);
    try mapUserPageIn(space, window + 2 * page_size, 0x402000);

    try testing.expect(isUserRangeIn(space, window, 3 * page_size, true));

    // The address two megabytes above the window is in the block of the
    // kernel, and the space does not describe it: the entry of the second
    // level is a table of the kernel, and the check may not read the
    // private table of the window for it.
    try testing.expect(!isUserRangeIn(space, window + large_page_size, page_size, true));

    // The mapping of a page outside the window is refused as well, and the
    // page of the window is not touched.
    try testing.expectError(error.OutOfTables, mapUserPageIn(
        space,
        window + large_page_size,
        0x403000,
    ));
    try testing.expect(isUserRangeIn(space, window, page_size, true));
}

test "the mapping refuses an address that is not aligned to the page" {
    try setup(0x200000, 0x300000, 0, 0);
    resetAddressSpacesForTest();

    const window: u64 = 0x200000 - 0x4000;
    const space = createAddressSpace(window).?;

    // An address with the low bits set would be rounded down, and the
    // table would describe a page that the caller did not name.
    try testing.expectError(error.UnalignedPage, mapUserPageIn(
        space,
        window + 1,
        0x400000,
    ));
    try testing.expectError(error.UnalignedPage, mapUserPageIn(
        space,
        window,
        0x400001,
    ));
    try testing.expectError(error.UnalignedPage, mapKernelPage(0x200001, 0x200000));
    try testing.expectError(error.UnalignedPage, mapKernelPage(0x400000, 0x400001));
    try testing.expect(!isUserRangeIn(space, window, page_size, true));
}

test "a large mapping that crosses a gigabyte is refused" {
    try setup(0x200000, 0x300000, 0, 0);

    // A range that starts at the end of the first gigabyte and ends in the
    // second one would write the entries of the second gigabyte in the
    // table of the first one.
    try testing.expectError(error.RangeTooLarge, mapLargeRange(
        0x40000000 - large_page_size,
        2 * large_page_size,
        Flags.present | Flags.writable,
    ));

    // A range that wraps the address space is refused, and not walked.
    try testing.expectError(error.RangeTooLarge, mapLargeRange(
        std.math.maxInt(u64) - page_size,
        2 * page_size,
        Flags.present | Flags.writable,
    ));
}

test "the permissions of a user page separate code from data" {
    try setup(0x200000, 0x300000, 0, 0);
    resetAddressSpacesForTest();

    const window: u64 = 0x200000 - 0x4000;
    const space = createAddressSpace(window).?;

    // The code page is readable and executable, and is not writable.
    try mapUserPageInFlags(space, window, 0x400000, .{
        .writable = false,
        .executable = true,
    });
    // The data page is writable, and the no-execute bit keeps it from being
    // executed even when the bytes of the file are not code.
    try mapUserPageInFlags(space, window + page_size, 0x401000, .{
        .writable = true,
        .executable = false,
    });

    const code_entry = space.level1.entries[(window >> 12) & 511];
    try testing.expect(code_entry & Flags.present != 0);
    try testing.expect(code_entry & Flags.user != 0);
    try testing.expect(code_entry & Flags.writable == 0);
    try testing.expect(code_entry & Flags.no_execute == 0);
    try testing.expect((code_entry & address_mask) == 0x400000);

    const data_entry = space.level1.entries[((window + page_size) >> 12) & 511];
    try testing.expect(data_entry & Flags.present != 0);
    try testing.expect(data_entry & Flags.user != 0);
    try testing.expect(data_entry & Flags.writable != 0);
    try testing.expect(data_entry & Flags.no_execute != 0);
    try testing.expect((data_entry & address_mask) == 0x401000);

    // The read-only page is not accepted as the destination of a write, and
    // the writable page is not accepted as code.
    try testing.expect(isUserRangeIn(space, window, page_size, false));
    try testing.expect(!isUserRangeIn(space, window, page_size, true));
    try testing.expect(isUserRangeIn(space, window + page_size, page_size, true));

    const code = permissionsIn(space, window).?;
    try testing.expect(!code.writable);
    try testing.expect(code.executable);
    const data = permissionsIn(space, window + page_size).?;
    try testing.expect(data.writable);
    try testing.expect(!data.executable);

    // The materializer removes a partial mapping with the same hierarchy
    // check, and the page is gone from the space afterwards.
    try unmapUserPageIn(space, window);
    try testing.expect(permissionsIn(space, window) == null);
    try testing.expectError(error.NotMapped, unmapUserPageIn(space, window));
}

test "the encoding of the user page flags never sets writable and executable" {
    const code = userPageEntryFlags(.{ .writable = false, .executable = true });
    const data = userPageEntryFlags(.{ .writable = true, .executable = false });
    const read_only = userPageEntryFlags(.{ .writable = false, .executable = false });

    try testing.expect(code & Flags.writable == 0);
    try testing.expect(code & Flags.no_execute == 0);
    try testing.expect(data & Flags.writable != 0);
    try testing.expect(data & Flags.no_execute != 0);
    try testing.expect(read_only & Flags.writable == 0);
    try testing.expect(read_only & Flags.no_execute != 0);
}

test "reserving a kernel range allocates tables without mapping pages" {
    try setup(0x400000, 0x500000, 0, 0);

    const base: u64 = 0x4000_0000;
    const level1_before = level1_used;
    const level2_before = level2_used;

    try reserveKernelRange(base, 4 * page_size);
    try testing.expectEqual(level1_before + 1, level1_used);
    try testing.expectEqual(level2_before + 1, level2_used);
    try testing.expect(translate(base) == null);

    // A second reservation of the same range reuses the tables.
    try reserveKernelRange(base, 4 * page_size);
    try testing.expectEqual(level1_before + 1, level1_used);
    try testing.expectEqual(level2_before + 1, level2_used);
}

test "reserving a kernel range rejects invalid ranges" {
    try setup(0x400000, 0x500000, 0, 0);
    const base: u64 = 0x4000_0000;

    try reserveKernelRange(base, 0);
    try testing.expectError(error.UnalignedPage, reserveKernelRange(base + 1, page_size));
    try testing.expectError(
        error.RangeTooLarge,
        reserveKernelRange(0x80_0000_0000, page_size),
    );
    try testing.expectError(
        error.RangeTooLarge,
        reserveKernelRange(std.math.maxInt(u64) - page_size + 1, 2 * page_size),
    );
}

test "unmapping a kernel page removes the translation" {
    try setup(0x400000, 0x500000, 0, 0);
    const base: u64 = 0x4000_0000;

    try reserveKernelRange(base, page_size);
    try testing.expectError(error.NotMapped, unmapKernelPage(base));
    try testing.expectError(error.UnalignedPage, unmapKernelPage(base + 1));

    try mapKernelDataPage(base, 0x500000);
    try testing.expectEqual(@as(?u64, 0x500000), translate(base));
    try unmapKernelPage(base);
    try testing.expect(translate(base) == null);
    try testing.expectError(error.NotMapped, unmapKernelPage(base));
}

test "a reserved kernel range is shared with a process address space" {
    try setup(0x400000, 0x500000, 0, 0);
    resetAddressSpacesForTest();

    const dma_base: u64 = 0x4000_0000;
    try reserveKernelRange(dma_base, 2 * page_size);

    // The user window lives in the block below the kernel image, so
    // replacing its level 2 entry with the private table does not hide the
    // kernel image from the process.
    const window: u64 = 0x400000 - 0x4000;
    const space = createAddressSpace(window).?;
    try testing.expectEqual(@as(?u64, 0x400000), translateIn(space, 0x400000));

    try mapKernelDataPage(dma_base, 0x500000);
    try testing.expectEqual(@as(?u64, 0x500000), translate(dma_base));
    try testing.expectEqual(@as(?u64, 0x500000), translateIn(space, dma_base));

    try unmapKernelPage(dma_base);
    try testing.expect(translate(dma_base) == null);
    try testing.expect(translateIn(space, dma_base) == null);
}

/// Entry point for a caller that has no address space to destroy.
pub fn destroyAddressSpace() void {
    // The space of the kernel is the active one and it is never destroyed;
    // the function exists for the caller that has no space to destroy. A
    // process space goes through `destroyAddressSpaceReal`, which releases the
    // pages and returns the slot.
}

/// Removes every mapping of an address space and returns the slot.
///
/// The order is the whole contract of the function:
///
///   1. the pages that the space owns go back to the manager, while the
///      entries still hold their addresses;
///   2. the private chain is cleared, so no entry points at a table that the
///      space no longer describes;
///   3. the space stops being live, so `spaceById` refuses its identifier and
///      `createAddressSpace` may hand the slot out again;
///   4. the table of the active space is forgotten; if the space being
///      destroyed is the active one, the kernel switches to its own tables
///      first, because clearing the tables that CR3 points at would fault on
///      the next instruction.
///
/// The caller has to make sure that no task still refers to the space: this
/// function frees the frames, not the tasks that run on them. The root table is
/// cleared as well and receives a fresh copy of the tables of the kernel on the
/// next creation.
pub fn destroyAddressSpaceReal(space: *AddressSpace) ReleaseReport {
    // A space that is still active is left first. Clearing the tables that CR3
    // points at would fault on the next instruction, and the space is about to
    // stop existing.
    if (active_space) |active| {
        if (active == space) {
            activate();
        }
    }

    const report = releaseUserPages(space);

    for (0..512) |i| space.level1.entries[i] = 0;
    for (0..512) |i| space.level2.entries[i] = 0;
    for (0..512) |i| space.level3.entries[i] = 0;
    for (0..512) |i| space.root.entries[i] = 0;

    if (active_space) |active| {
        if (active == space) active_space = null;
    }

    // The slot is free and the identifier names nothing. The generation stays
    // with the slot: it is what the next owner differs by.
    space.live = false;
    space.id = 0;

    return report;
}

/// Releases every address space. Host tests only.
///
/// The kernel never destroys the spaces that it created for its own tasks, so
/// this function exists to give each test the same starting point. It releases
/// the owned pages through the installed callback, exactly as the reaper does.
fn resetAddressSpacesForTest() void {
    for (&process_spaces) |*space| {
        if (space.live) _ = destroyAddressSpaceReal(space);
    }
    process_spaces = @splat(.{});
    spaces_created = 0;
    active_space = null;
}

/// Releases a physical page back to the physical memory manager.
///
/// The architecture layer does not import the memory layer. The manager owns
/// the bitmap that describes the pages, and it depends on the tables only for
/// diagnostics; importing it from here would invert that direction, and it
/// would pull the whole manager into the host tests that only need the
/// tables. The kernel installs the callback once, after the manager is
/// initialised, and the callback validates alignment, range and ownership
/// before it frees anything.
pub const PageReleaseHook = *const fn (physical_address: u64) void;

/// The installed callback, or `null` when nothing returns pages.
var page_release_hook: ?PageReleaseHook = null;

/// Installs the callback that releases a page; `null` uninstalls it.
pub fn installPageReleaseHook(hook: ?PageReleaseHook) void {
    page_release_hook = hook;
}

/// What `releaseUserPages` did with the mappings of a space.
pub const ReleaseReport = struct {
    /// Pages that were mapped in the private window of the user.
    detached: u32 = 0,
    /// Pages that the hook accepted and returned to the manager.
    released: u32 = 0,
};

/// Detaches the pages of the window of the user and returns the ones the
/// space owns.
///
/// Only the entries of the first level of the private chain are considered.
/// The entries of the levels above point at the static tables of the space
/// (`process_level*_pool`), so a walk that treated every present entry as a
/// page would hand the manager the address of a table that it never
/// allocated — the table pools are part of the image of the kernel, not of
/// the pool of free pages.
///
/// Two facts decide what happens to an entry:
///
///   * the user bit says that the entry is a mapping of the process, so the
///     entry is detached. An entry without it belongs to the kernel and is
///     left in place;
///   * the owned bit says that the page came from the manager, so the page is
///     returned. An entry without it maps a page of the image of the kernel or
///     a page that another space shares, and freeing it would return memory
///     that this space never had.
///
/// Without a callback the owned pages are detached but not released, and the
/// report shows the difference: the caller can then report the leak instead of
/// believing that the memory came back.
pub fn releaseUserPages(space: *AddressSpace) ReleaseReport {
    var report: ReleaseReport = .{};
    const level1 = space.level1;

    for (0..512) |i| {
        const entry = level1.entries[i];
        if (entry & Flags.present == 0) continue;
        if (entry & Flags.user == 0) continue;

        report.detached += 1;
        level1.entries[i] = 0;

        if (entry & Flags.owned == 0) continue;
        if (page_release_hook) |hook| {
            hook(entry & address_mask);
            report.released += 1;
        }
    }

    return report;
}

test "releasing the window returns the pages of the user to the manager" {
    try setup(0x200000, 0x300000, 0, 0);
    resetAddressSpacesForTest();

    const window: u64 = 0x200000 - 0x4000;
    const space = createAddressSpace(window).?;
    try mapUserPageIn(space, window, 0x400000);
    try mapUserPageIn(space, window + page_size, 0x401000);
    try mapUserPageIn(space, window + 2 * page_size, 0x402000);
    // The three pages came from the manager, so the space owns them and the
    // release returns them.
    try takeOwnership(space, window);
    try takeOwnership(space, window + page_size);
    try takeOwnership(space, window + 2 * page_size);

    // The hook stands in for the physical memory manager and records what it
    // was asked to release, so that the test can check the addresses without
    // depending on the manager.
    page_released_by_test = 0;
    released_addresses_by_test = @splat(0);
    installPageReleaseHook(&recordRelease);
    defer installPageReleaseHook(null);

    const report = releaseUserPages(space);
    try testing.expectEqual(@as(u32, 3), report.detached);
    try testing.expectEqual(@as(u32, 3), report.released);
    try testing.expectEqual(@as(usize, 3), page_released_by_test);

    // The pages are named in the order of the window, and the mappings are
    // gone: a released page that stayed mapped would be reachable by the
    // processor after it went back to the pool.
    try testing.expectEqual(@as(u64, 0x400000), released_addresses_by_test[0]);
    try testing.expectEqual(@as(u64, 0x401000), released_addresses_by_test[1]);
    try testing.expectEqual(@as(u64, 0x402000), released_addresses_by_test[2]);
    try testing.expect(!isUserRangeIn(space, window, 3 * page_size, true));

    // A second release finds nothing: the entries were cleared, and a page
    // that is returned twice corrupts the pool.
    const again = releaseUserPages(space);
    try testing.expectEqual(@as(u32, 0), again.detached);
    try testing.expectEqual(@as(usize, 3), page_released_by_test);
}

test "releasing the window without a hook detaches but does not claim a release" {
    try setup(0x200000, 0x300000, 0, 0);
    resetAddressSpacesForTest();

    const window: u64 = 0x200000 - 0x4000;
    const space = createAddressSpace(window).?;
    try mapUserPageIn(space, window, 0x400000);
    try takeOwnership(space, window);

    installPageReleaseHook(null);
    const report = releaseUserPages(space);

    // The mapping is detached; the physical page is not accounted as
    // returned, which is what the caller needs to know to report the leak
    // instead of hiding it.
    try testing.expectEqual(@as(u32, 1), report.detached);
    try testing.expectEqual(@as(u32, 0), report.released);
    try testing.expect(!isUserRangeIn(space, window, page_size, true));
}

test "a page that the space does not own survives the release" {
    try setup(0x200000, 0x300000, 0, 0);
    resetAddressSpacesForTest();

    const window: u64 = 0x200000 - 0x4000;
    const space = createAddressSpace(window).?;

    // The kernel maps a page of its own image into the space: the entry is a
    // page of the user, but the page belongs to the kernel.
    try mapUserPageIn(space, window, 0x400000);

    page_released_by_test = 0;
    installPageReleaseHook(&recordRelease);
    defer installPageReleaseHook(null);

    const report = releaseUserPages(space);

    // The entry is detached, and the page is not returned: the manager never
    // handed it out to this space, and returning it would put a page of the
    // kernel image in the pool.
    try testing.expectEqual(@as(u32, 1), report.detached);
    try testing.expectEqual(@as(u32, 0), report.released);
    try testing.expectEqual(@as(usize, 0), page_released_by_test);
}

test "unmapping an owned page returns it and unmapping a borrowed one does not" {
    try setup(0x200000, 0x300000, 0, 0);
    resetAddressSpacesForTest();

    const window: u64 = 0x200000 - 0x4000;
    const space = createAddressSpace(window).?;
    try mapUserPageIn(space, window, 0x400000);
    try mapUserPageIn(space, window + page_size, 0x401000);
    try takeOwnership(space, window);

    page_released_by_test = 0;
    released_addresses_by_test = @splat(0);
    installPageReleaseHook(&recordRelease);
    defer installPageReleaseHook(null);

    try unmapUserPageIn(space, window);
    try testing.expectEqual(@as(usize, 1), page_released_by_test);
    try testing.expectEqual(@as(u64, 0x400000), released_addresses_by_test[0]);

    // The borrowed page leaves the space without going back to the pool.
    try unmapUserPageIn(space, window + page_size);
    try testing.expectEqual(@as(usize, 1), page_released_by_test);

    // The entry is gone in both cases.
    try testing.expect(!isUserRangeIn(space, window, 2 * page_size, true));
    try testing.expectError(error.NotMapped, unmapUserPageIn(space, window));
}

test "an owned page is not removed when nothing can return it" {
    try setup(0x200000, 0x300000, 0, 0);
    resetAddressSpacesForTest();

    const window: u64 = 0x200000 - 0x4000;
    const space = createAddressSpace(window).?;
    try mapUserPageIn(space, window, 0x400000);
    try takeOwnership(space, window);

    installPageReleaseHook(null);
    try testing.expectError(error.ReleaseUnavailable, unmapUserPageIn(space, window));

    // The entry survives, with its permissions and its ownership: a refusal
    // may not leave the space with the page detached and the page lost.
    try testing.expect(isUserRangeIn(space, window, page_size, true));
    try testing.expect(space.level1.entries[(window >> 12) & 511] & Flags.owned != 0);
}

test "a destroyed space returns its slot and grows the generation" {
    try setup(0x200000, 0x300000, 0, 0);
    resetAddressSpacesForTest();

    var spaces: [max_process_spaces]*AddressSpace = undefined;
    for (&spaces) |*slot| {
        slot.* = createAddressSpace(0x1FF000).?;
    }

    // The pool is exhausted, and a full pool refuses instead of handing out a
    // space that is live.
    try testing.expectEqual(@as(usize, max_process_spaces), liveSpaceCount());
    try testing.expect(createAddressSpace(0x1FF000) == null);

    const first = spaces[0];
    const identity = identityOf(first);
    try testing.expect(spaceById(identity.id) == first);
    try testing.expectEqual(first, spaceByIdentity(identity.id, identity.generation).?);

    // The page of the space comes back when the space is destroyed.
    try mapUserPageIn(first, 0x1FF000, 0x400000);
    try takeOwnership(first, 0x1FF000);
    page_released_by_test = 0;
    installPageReleaseHook(&recordRelease);
    defer installPageReleaseHook(null);

    const report = destroyAddressSpaceReal(first);
    try testing.expectEqual(@as(u32, 1), report.released);
    try testing.expectEqual(@as(usize, max_process_spaces - 1), liveSpaceCount());

    // While the slot is free the identifier names nothing at all.
    try testing.expect(spaceById(identity.id) == null);
    try testing.expect(spaceByIdentity(identity.id, identity.generation) == null);

    // The slot is handed out again with the same index and a new generation:
    // the identity of the previous process does not open the new one.
    const replacement = createAddressSpace(0x1FF000).?;
    try testing.expectEqual(first, replacement);
    try testing.expectEqual(identity.id, replacement.id);
    try testing.expect(replacement.generation != identity.generation);
    try testing.expect(spaceById(identity.id) == replacement);
    try testing.expect(spaceByIdentity(identity.id, identity.generation) == null);
    try testing.expectEqual(
        replacement,
        spaceByIdentity(replacement.id, replacement.generation).?,
    );

    // The new space starts empty: nothing of the previous process is mapped.
    try testing.expect(!isUserRangeIn(replacement, 0x1FF000, page_size, true));
}

test "destroying the space clears the private chain and every table" {
    try setup(0x200000, 0x300000, 0, 0);
    resetAddressSpacesForTest();

    const window: u64 = 0x200000 - 0x4000;
    const space = createAddressSpace(window).?;
    try mapUserPageIn(space, window, 0x400000);

    _ = destroyAddressSpaceReal(space);

    try testing.expect(!isUserRangeIn(space, window, page_size, true));
    try testing.expect(!space.live);
    try testing.expectEqual(@as(u32, 0), space.id);
    for (0..512) |i| {
        try testing.expectEqual(@as(u64, 0), space.level1.entries[i]);
        try testing.expectEqual(@as(u64, 0), space.level2.entries[i]);
        try testing.expectEqual(@as(u64, 0), space.level3.entries[i]);
        try testing.expectEqual(@as(u64, 0), space.root.entries[i]);
    }
}

/// Addresses that the test hook received.
var released_addresses_by_test: [8]u64 = @splat(0);

/// Number of addresses that the test hook received.
var page_released_by_test: usize = 0;

/// Test hook: records the address instead of returning it to a manager.
fn recordRelease(address: u64) void {
    if (page_released_by_test < released_addresses_by_test.len) {
        released_addresses_by_test[page_released_by_test] = address;
    }
    page_released_by_test += 1;
}
