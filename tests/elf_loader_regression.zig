//! K4.6 regression — ELF loader stub.
const std = @import("std");
const loader = @import("../../task/elf_loader.zig");

test "ELF loader stub validates W^X" {
    const ph: loader.ProgramHeader = .{
        .p_type = 1, .p_flags = 0x5, .p_offset = 0, .p_vaddr = 0x400000,
        .p_paddr = 0, .p_filesz = 0, .p_memsz = 0, .p_align = 0x1000,
    };
    try std.testing.expect(loader.checkWXC(&ph));
}
