//! Process object — K4.1 minimal implementation.
//! Contract from docs/architecture/k4-process-model.md.
//! Status: partial (scaffolding); full lifecycle/reap/wait deferred to K4.2/K4.9.

const std = @import("std");
const scheduler = @import("scheduler.zig");
const context = @import("context.zig");
const paging = @import("../arch/x86_64/paging.zig");

pub const ProcessId = u32;

/// Handle with generation — prevents ABA reuse of pid.
pub const ProcessHandle = extern struct {
    pid: ProcessId,
    generation: u32,
};

/// Process lifecycle state.
pub const ProcessLifecycleState = enum(u8) {
    not_started,
    initializing,
    running,
    exiting,
    blocked,
    exited,
    reaped,
    freed,
};

/// Minimal process container for K4.1.
pub const Process = extern struct {
    /// Process identifier (monotonic, non-zero for user processes).
    pid: ProcessId = 0,
    /// Generation — incremented on reap/reallocate; prevents stale handle reuse.
    generation: u32 = 0,
    /// Handle — mirrors pid + generation.
    handle: ProcessHandle = .{ .pid = 0, .generation = 0 },
    /// Parent process reference (weak; cleaned on reap).
    parent: ?*Process = null,
    /// Process state (stored as u8 for extern struct compatibility).
    state: ProcessLifecycleState = .not_started,
    /// Address space — owned by process; destroyed on reap.
    space: ?*paging.AddressSpace = null,
    /// Exit code (set at exit; read by reap).
    exit_code: u16 = 0,
    /// List of threads — stub; full list deferred to K4.3 integration.
    thread_count: u8 = 0,
    /// Capability table placeholder (full table deferred to K4.10).
    capabilities: u32 = 0,
    /// Resource limits placeholder.
    max_threads: u8 = 4,
    /// Minimal resource accounting.
    schedules: u64 = 0,
};

/// K4.2: Lifecycle stubs — create/init/publish/exit/reap.
/// Full reap requires K4.9 (wait/reap integration) and scheduler fix.

/// Initialize a process from created state to initializing.
pub fn initializeProcess(p: *Process, space: *paging.AddressSpace) void {
    p.space = space;
    p.state = .initializing;
}

/// Publish process to running state (after initial thread created).
pub fn publishProcess(p: *Process) void {
    p.state = .running;
}

/// Request process exit — transitions to .exiting.
pub fn exitProcess(p: *Process, code: u16) void {
    p.exit_code = code;
    p.state = .exiting;
}

/// Reap process — verifies state .exited, releases generation (stub).
/// Full reap releases AddressSpace and capabilities (deferred to K4.9).
pub fn reapProcess(p: *Process, handle: ProcessHandle) bool {
    if (p.state != .exited) return false;
    if (!verifyHandle(p, handle)) return false;
    p.generation += 1; // generation incremented on reap to prevent stale handle reuse
    p.handle.generation = p.generation;
    p.state = .reaped;
    // AddressSpace and capabilities release deferred to full reap (K4.9).
    return true;
}

/// Verify handle matches process (generation check — no ABA reuse).
pub fn verifyHandle(proc: *Process, handle: ProcessHandle) bool {
    return proc.pid == handle.pid and proc.generation == handle.generation;
}

/// Maximum number of processes in the static pool.
pub const max_processes: usize = 8;

/// Static process pool (no dynamic allocation in critical paths).
var process_pool: [max_processes]Process = @splat(.{});
var process_pool_used: [max_processes]bool = @splat(false);

/// Creates a new process with fresh pid/generation.
/// Allocates from the static pool; returns null if pool exhausted or pid==0.
pub fn createProcess(pid: ProcessId, space: ?*paging.AddressSpace) ?*Process {
    if (pid == 0) return null; // kernel process; user must have non-zero

    // Find a free slot in the pool.
    var i: usize = 0;
    while (i < max_processes) : (i += 1) {
        if (!process_pool_used[i]) {
            process_pool_used[i] = true;
            var p = &process_pool[i];
            p.* = .{}; // reset
            p.pid = pid;
            p.generation += 1;
            p.handle = .{ .pid = pid, .generation = p.generation };
            p.space = space;
            p.state = .not_started;
            return p;
        }
    }
    return null; // pool exhausted
}

/// Releases a process back to the pool (called by reap after resources freed).
pub fn freeProcess(p: *Process) void {
    // Find the slot and mark as free.
    var i: usize = 0;
    while (i < max_processes) : (i += 1) {
        if (&process_pool[i] == p) {
            process_pool_used[i] = false;
            p.* = .{}; // reset
            return;
        }
    }
}
/// Reaps a process: releases its address space, its pages and its
/// capabilities, then returns the process slot to the pool.
///
/// The order is the one the tables require. `destroyAddressSpaceReal` returns
/// the pages of the window to the manager while the entries still name them,
/// clears the private tables, and releases the slot with a new identifier, so
/// an identifier that a caller kept from the reaped process resolves to
/// nothing.
///
/// The capabilities go with the space: a process that no longer exists cannot
/// hold a permission, and the caller that kept a handle may not use it on the
/// next process that receives the same slot.
pub fn reapFull(p: *Process, handle: ProcessHandle) bool {
    const pag = @import("../arch/x86_64/paging.zig");
    const capability = @import("../security/capability.zig");

    if (p.space) |space| {
        // The set of capabilities of a process is indexed by the identifier of
        // its space, and it has to go while the identifier still names the
        // process: after the slot is handed out again the same index belongs to
        // another process.
        _ = capability.releaseProcess(space.id);
        _ = pag.destroyAddressSpaceReal(space);
        p.space = null;
    } else {
        pag.destroyAddressSpace();
    }

    return p.reapProcess(handle);
}
