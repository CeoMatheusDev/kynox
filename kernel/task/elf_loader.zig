//! K4.6 — ELF64 loader stub.
//! Contract: docs/architecture/k4-userspace-transition.md; docs/decisions/ADR-K4-001.md.
//! Status: scaffolding; full segment validation and loading deferred.

const std = @import("std");

/// ELF64 header fields (minimal for stub).
const ElfHeader = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

/// Program header fields (minimal).
const ProgramHeader = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

/// Validates that executable segments are not writable (W^X contract from k4-security-process.md).
pub fn checkWXC(p_hdr: *ProgramHeader) bool {
    const PF_X = 0x1;
    const PF_W = 0x2;
    if (p_hdr.p_type == 1) { // PT_LOAD
        const has_x = (p_hdr.p_flags & PF_X) != 0;
        const has_w = (p_hdr.p_flags & PF_W) != 0;
        if (has_x and has_w) return false; // W and X together: W^X violation.
    }
    return true;
}

/// Stub loader: validates header and first program header; returns entry point.
pub fn loadElfStub(header: *ElfHeader, phdr: *ProgramHeader) u64 {
    _ = header;
    _ = checkWXC(phdr);
    return phdr.p_vaddr;
}
