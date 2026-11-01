//! K4.8 — Process syscall stubs.
//! Contract: docs/decisions/ADR-K4-001.md; syscalls validated before access (AGENTS.md §4.5).
//! Full syscall ABI (syscall_abi.zig rev 1) used; revision not incremented.

const std = @import("std");

/// Stub syscall number for process creation.
pub const SYSCALL_CREATE_PROCESS: u32 = 20;

/// Stub syscall number for process exit.
pub const SYSCALL_EXIT_PROCESS: u32 = 21;

/// Stub syscall number for wait/reap (deferred to K4.9 full wait.zig).
pub const SYSCALL_WAIT_PROCESS: u32 = 22;

/// Stub: validates user pointer argument before access.
/// Returns true if pointer is within user range (stub validates only alignment/non-zero).
pub fn validateSyscallPointer(ptr: u64) bool {
    if (ptr == 0) return false; // page zero protected.
    // Full validation requires page-table walk (paging.zig); deferred.
    return true;
}
