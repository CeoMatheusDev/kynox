# K4 — Security and Isolation Design

Reference: `docs/architecture/security-architecture.md`, `docs/decisions/ADR-K4-001-process-architecture.md`, `AGENTS.md` §4.5.

## 1. Kernel/user boundary

- User code runs at `Ring 3` (`user_code_selector` from `segment.zig`).
- Kernel code runs at `Ring 0` (`kernel_code_selector`).
- System call transition (`syscall.zig` / `syscall.s`) saves user registers, validates arguments, executes handler at `Ring 0`, restores registers, returns to user via `iretq`.
- No user-mode pointer is trusted: the kernel validates all pointers before access.
- No user-mode data is read directly: `copyFromUser`/`copyToUser` must be used.

## 2. Capability enforcement

- Each process holds a `CapabilityTable` (design in `k4-process-model.md`).
- Capabilities granted at process creation based on executable manifest (`KEX` manifest) or default grants.
- Capabilities revoked before reap; any access with stale handle must fail (generation mismatch).
- The kernel does not rely on user-space manifest as authority; it validates capabilities independently.

## 3. Process isolation

- A process's user pages must not be mapped in other processes' address spaces (unless shared memory explicitly granted via capability — deferred).
- The process container verifies that threads from terminated/reaped processes are not scheduled.
- The scheduler selects threads only from processes in valid states (`.running`, `.blocked` for wait, `.exiting` for termination).

## 4. Memory protection

- `W^X`: executable pages (`PF_X`) must not be writable (`PF_W` must not be set); writable pages must not be executable. Enforced during page table construction (`paging.zig`) and verified by `ELFLoader` / `KEXLoader`.
- `NX`: enabled (`cpu.zig` `enableFloatingPoint` sets `EFER.NXE` via CR4 bit 11; CR0 `EM`/`MP`/`TS` managed).
- Page zero protected: user pages must not map address 0.
- User stack guard page: a non-writable, non-executable page below user stack; overflow triggers page fault, handled by exception handler (`interrupt.s`).

## 5. Resource limits

- `ResourceLimits` (design in `k4-process-model.md`) defines max threads, max memory, max file descriptors.
- The scheduler enforces max threads: a process that tries to spawn beyond limit must fail (`spawn` syscall returns error).
- The memory manager enforces max memory: `AddressSpace` creation or page mapping must check against process limit.
- No resource accounting module (`metrics.zig`) exists; resource tracking is embedded in `scheduler.zig` (`Task.schedules`, `Task.priority`, `Task.weight`). The design specifies that `metrics.zig` will centralize accounting (K4.1 or later).

## 6. Handle ownership

- `Handle` (`ProcessHandle`) has `generation` and `pid`.
- The process verifies handle before any access: `handle.generation == process.generation`; otherwise access fails (stale handle).
- Handles cannot be forged: only the kernel creates `Process` objects and assigns handles.
- Revocation removes capability; any handle referencing the revoked capability must fail.

## 7. Fault containment

- A user-mode exception (`INT 6` invalid opcode, `INT 14` page fault) must be caught by the exception handler (`interrupt.s`).
- The exception handler calls the Zig handler (`interrupt.zig` stub) which terminates the offending process (`.exiting`) and resumes another thread.
- A user-mode fault must not corrupt the kernel: the exception stub pushes user registers before calling the handler; the handler uses the kernel stack (`rsp0` from TSS).
- The idle loop (`killed_task_loop` in `task.s`) waits with `hlt` but does not disable interrupts (`cli` absent per `task.s` line 688-690); this ensures the timer continues to wake the system.

## 8. No fictitious permissions

- The design does not introduce any permission mechanism that only records permissions without enforcing them.
- Capabilities must be enforced by the kernel at every resource access; no user-space enforcement.
- No `trusted process` concept: all user processes are untrusted by default; capabilities grant specific rights.
