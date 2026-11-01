//! Wrapper PMM for paging.zig (avoids path mismatch in test builds).
///
const physical = @import("../../memory/physical.zig");

pub const Manager = physical.Manager;
pub const page_size: u64 = physical.page_size;
pub const managed_address_space: u64 = physical.managed_address_space;
pub const bitmap_size: usize = physical.bitmap_size;
pub const managed_pages: u32 = physical.managed_pages;
pub const minimum_address: u64 = physical.minimum_address;

/// Call the global manager's free for reclaim path.
pub fn managerFree(addr: u64) void {
    physical.manager.free(addr);
}
