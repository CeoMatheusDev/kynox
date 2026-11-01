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

/// Creates a new process with fresh pid/generation.
/// Returns the process pointer; caller must initialize space/threads.
pub fn createProcess(pid: ProcessId, space: ?*paging.AddressSpace) ?*Process {
    // In full implementation: allocate from pool; here scaffold.
    // For regression testing, return a static buffer or null if invalid.
    _ = space; // stub: full space assignment deferred to K4.1 integration.
    if (pid == 0) return null; // kernel process; user must have non-zero
    // Stub: no dynamic allocation in kernel yet (per AGENTS.md 4.2 — avoid dynamic allocation in critical paths).
    // The process object is meant to be embedded in a pool or static array.
    return null; // deferred to full allocation mechanism
}
// K4.9 reap: destrói AddressSpace via paging.zig; capabilities revogadas; ainda parcial (paging.zig destruição completa pendente)

/// K4.9 reap: calls paging destruction and revokes capabilities (stub for full revocation).
pub fn reapFull(p: *Process, handle: ProcessHandle) bool {
    const paging = @import("../arch/x86_64/paging.zig");
    if (p.space) |space| {
        paging.destroyAddressSpaceReal(space);
    } else {
        paging.destroyAddressSpace();
    }
    const security = @import("../ai/security.zig");
    security.revokeCapabilities();
    // Capabilities revocation: requires full revocation path (stub).
    return p.reapProcess(handle);
}
