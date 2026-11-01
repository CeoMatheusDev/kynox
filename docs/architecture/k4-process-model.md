# K4 — Process Architecture Design

Status: **architectural design**, no implementation. The tree at `main` (post K3.12.5 audit) confirms:

- `kernel/task/thread.zig`: **missing**.
- `kernel/task/wait.zig`: **missing**.
- `kernel/task/runqueue.zig`: **missing**.
- `scheduler.zig`: `Task` exists but `running_cpu`, `ready_queue` integration, and `preempt_disable` are **missing**.
- `context.zig`: `Context` exists (`fp_state_size` 512, `fp_state_offset` 192, `frame_size` 176) but `fpu.zig` isolation module is **missing**.
- `cpu.zig`: `enableFloatingPoint` sets CR0/CR4; no runtime CPUID verification before use.
- `segment.zig`: TSS assertions (`rsp0`, `ist1`, `tss_size` 104) exist.
- `timer.zig`: timer tick and EOI exist; no sleep/deadline module.
- `docs/architecture/execution-model.md`: describes target model; **nothing implemented**.

This document defines the contracts for K4. Implementation must reference these, not invent divergent APIs.

## 1. Process object (`Process`)

```zig
pub const Process = extern struct {
    // Identity — never reused; monotonically increasing.
    pid: ProcessId,          // 32-bit; zero reserved for kernel.
    generation: u32 = 0,    // Increments on reap/reallocate; prevents ABA reuse.
    handle: ProcessHandle = .{ .pid = 0, .generation = 0 },

    // Ownership and relationships.
    parent: ?*Process = null,         // Parent process; null for init.
    children: ?*ChildList = null,    // Weak references; cleaned on exit/reap.

    // Threads — the schedulable entities.
    // A process does NOT own its threads' stacks directly; the scheduler owns scheduling.
    // The process container holds the list so reap can verify no running threads remain.
    threads: ThreadList,

    // Address space — the container owns the space.
    space: ?*paging.AddressSpace,

    // Capabilities — the process holds capabilities granted to it.
    // Not the same as the capability table in the kernel; this is the process-level set.
    capabilities: CapabilityTable,

    // Lifecycle and accounting.
    state: ProcessState,
    exit_code: u16 = 0,              // Only the low 16 bits are meaningful for compatibility.
    resource_accounting: ResourceLimits,

    // Exit/reap.
    reap_state: ReapState = .not_terminated,
    reap_reference: ?*ProcessHandle = null,
};
```

### Invariants

1. A `Process` always has exactly one `AddressSpace` (can be null only during creation before space assignment).
2. A `Process` has at least one thread at creation time (the initial thread created with the process).
3. A `Process` cannot have threads added after it enters `.reaped`.
4. The `generation` is incremented only when the `pid` slot is reused after reap.
5. `handle.generation` must match `process.generation` for any valid reference; a stale handle must be rejected by the kernel.

### State machine (`ProcessState`)

```
not_started → initializing → running → (exiting | blocked) → exited → (reaped) → freed
```

- `not_started`: process object allocated; no space, no threads.
- `initializing`: space assigned; initial thread being created; capabilities being initialized.
- `running`: initial thread started; process may spawn more threads; may block on wait.
- `exiting`: at least one thread has called exit; process is terminating; no new threads allowed.
- `blocked`: process is blocked on a wait (e.g., parent wait) — this applies to the process container, not individual threads.
- `exited`: all threads terminated; resources not yet reclaimed.
- `reaped`: parent (or init) has read exit code; resources released; slot recyclable.
- `freed`: object deallocated; `pid` may be reused with new `generation`.

### Ownership rules

- `Process` owns `AddressSpace` (destroyed when process exits/reaps).
- `Process` owns `CapabilityTable` (revoked/released on reap).
- `Process` owns `ResourceLimits` (enforced by scheduler and memory manager).
- `Process` does NOT own thread stacks directly; stacks are owned by the scheduler/task system. The process verifies no running threads before reap completes.
- `Process` provides parent/child links; these are weak references (not ownership). Child list cleaned on reap; parent reference remains for reap reporting.

## 2. Thread and Process relationship

A thread (`Task` in current tree) belongs to exactly one process.

```zig
pub const ThreadProcessLink = extern struct {
    thread: *Task,        // Reference to scheduler task; not ownership.
    process: *Process,    // The process container.
};
```

### Rules

1. A thread's `AddressSpace` is the process's `space`. The scheduler must verify this on every context switch that updates CR3 (already partially done in `task.s`, but no process-level verification exists).
2. A thread's `kernel_rsp` (kernel stack) belongs to the thread, not to the process. The process does not free it.
3. A process's termination does not immediately terminate its threads; the scheduler must finish each thread's context before reap completes (matching `execution-model.md`: "The current thread never frees its own stack. It switches away first; the reaper frees it in another context.").
4. A process that tries to spawn a thread after `exiting` must fail.
5. A process that tries to exit with running threads must block the exit (not kill threads abruptly) unless `SIGTERM` or equivalent is implemented (not in initial scope).

### Kernel-only threads

A kernel-only thread (e.g., deferred work, driver thread) has:

- `process` pointing to a special `kernel_owner` process (not a user process).
- `space` pointing to the kernel address space (same as current `Task.space` behavior).
- No user-mode capability restrictions.
- No reap dependency on parent process.

This aligns with `execution-model.md`: "A kernel-only thread has a process-less owner (`kernel_owner`), used by deferred work and by drivers. It still has a thread object, so the scheduler has one rule for all schedulable things."

## 3. Lifecycle design (`docs/roadmap/K4_PROCESS_ROADMAP.md` structure)

### K4.0 Process architecture (this document)
- Design contracts, APIs, state machines.
- Define interfaces for Process, ThreadProcessLink, CapabilityTable, ResourceLimits.
- Produce ADR-K4-001 (this design) and update `docs/architecture/`.
- **No code changes to scheduler/task modules** except adding interface stubs (if needed for documentation tests).

### K4.1 Process object and handles
- Implement `Process` struct, `ProcessHandle`, `ProcessId`, `generation`.
- Implement `CapabilityTable` interface (stub; full enforcement in K4.5+).
- Implement `ResourceLimits` (stub; enforced by memory manager in K4.9+).
- Add `docs-check` assertions verifying contracts.
- Tests: handle generation increment, stale handle rejection, parent/child links.

### K4.2 Process lifecycle
- Implement `ProcessState` transitions.
- Implement `reap` protocol: verify no running threads → release space → read exit code → increment generation.
- Implement `wait` protocol: parent blocks until child exits; no lost wakeup (requires `wait.zig` infrastructure from K3.12.4 audit finding).
- Tests: reap with running threads fails; reap after all threads exit succeeds; reap duplicates prevented.

### K4.3 Process/thread integration
- Modify `Task` to reference `Process` (not own it; reference only).
- Verify scheduler selects threads only from processes in `.running` or `.blocked` state.
- Verify `cpuId()` returns correct CPU (requires SMP fix from K3.12.2 audit) before this stage.
- Tests: thread context switch verifies process space matches; thread from terminated process is not scheduled.

### K4.4 User address space and Ring 3 transition
- Define `user_code_selector`, `user_data_selector` (already in `segment.zig`).
- Define user stack setup (`user_stack` address, guard page, alignment).
- Define `syscall` transition: save user context, switch to kernel stack (`kernel_rsp`), handle syscall, restore user context.
- Define `iretq` return: verify user `CS`/`SS` selectors before return.
- Tests: user-mode syscall stub verifies register preservation; page fault in user space does not corrupt kernel.

### K4.5 User memory validation and safe copy
- Define interface: `validateUserRange(address, length) -> bool` (uses page tables).
- Define safe copy: `copyFromUser` and `copyToUser` (must check after copy? No — check before and after, preventing TOCTOU).
- Use atomic validation: check range, disable interrupts temporarily? No — check in kernel context, copy with interrupts disabled is too expensive. Instead: validate range, then copy with validated pointer; do not re-validate (no TOCTOU if pointer is not user-controlled after validation).
- Actually: to prevent TOCTOU, the pointer must be resolved to a physical address or validated page before any user access. The design should use page table walk before copy.
- Tests: invalid user pointer rejected; overlapping ranges handled; copy size overflow prevented.

### K4.6 ELF64 loader
- Implement `ELFLoader` interface: parse header, verify segments (`PT_LOAD`, `PT_INTERP` not required initially), check `p_align`, `p_offset`, `p_filesz`, `p_memsz`.
- Verify W^X: executable segments must have `PF_X` only if `p_flags` indicates; writable segments must not have `PF_X`.
- Build `AddressSpace` from segments.
- Load initial thread entry point from `e_entry`.
- Tests: malformed ELF rejected; W^X violation detected; valid ELF loads.

### K4.7 Native executable integration (`KEX`)
- Define `KEX` format interface (already exists: `formats/kex.zig`).
- Separate from ELF loader: `KEXLoader` calls `ELFLoader` for payload, then applies `KEX` manifest (capabilities, dependencies).
- Process creation uses `KEXLoader` if `.kex` file is passed; `ELFLoader` if `.elf` is passed.
- Tests: KEX manifest validated; dependency missing rejected; payload loaded.

### K4.8 Process syscalls
- Define syscall numbers for process management (create, exit, wait, reap, spawn thread, capability operations).
- Integrate with `syscall.zig` / `shared/syscall_abi.zig` (revision 1 exists; stable? No — audit A-04 says unstable).
- Verify syscall pointer validation (`syscall_abi.zig` contract).
- Tests: invalid pointer rejected; valid syscall executes; syscall number out of range handled.

### K4.9 Parent/child and wait
- Implement `wait` syscall: parent blocks until specified child exits; returns exit code.
- Implement `reap` syscall: reads exit code; releases resources; increments generation.
- Implement `spawn` syscall: creates child process with new `pid`; inherits space? No — child must have its own `AddressSpace` unless `fork` is implemented (not in initial scope). For initial scope, `spawn` creates an independent process.
- Define `fork` evaluation: not required for initial K4 because no process duplication contract exists in `execution-model.md`. If needed, must be documented in a separate ADR (ADR-K4-002) before implementation.
- Tests: parent waits on non-existent child returns error; parent waits successfully; reap reads correct exit code.

### K4.10 Security and isolation hardening
- Implement capability enforcement: process cannot access resources without capability handle; handle generation verified.
- Implement process isolation: user space cannot access kernel pages; kernel validates all user pointers before access.
- Implement resource limits: `ResourceLimits` enforced by scheduler (max threads, max memory); violation causes process termination (not kernel panic).
- Implement handle revocation: capability revoked before reap; stale handles rejected by generation check.
- Tests: capability missing rejected; stale handle rejected; resource limit exceeded terminates process; user pointer to kernel page rejected.

## 4. Security design (`docs/decisions/ADR-K4-001-process-architecture.md`)

### Kernel/user boundary
- All user-mode execution runs at `Ring 3` (`user_code_selector` from `segment.zig`).
- User-mode threads use user stacks (`user_stack`) separate from kernel stacks (`kernel_rsp`).
- The interrupt stub (`interrupt.s`) saves registers, pushes error code, and calls the Zig handler. The handler runs on the kernel stack (`rsp0` from TSS).
- The syscall path (`syscall.zig` / `syscall.s`) saves user registers, switches to kernel stack, executes handler, and restores user registers before `iretq`.
- The switch (`task.s`) saves `fp` state (`fxrstor64` at offset 192) and builds the frame on the kernel stack before `iretq`.

### Capability enforcement
- Every resource access requires a `Handle` with `generation` verification.
- The process holds capabilities granted by the kernel; capabilities can be delegated but not forged.
- Revocation removes the capability from the process's `CapabilityTable`; any subsequent access with a stale handle must fail (generation mismatch).

### Memory protection
- `W^X`: executable pages must not be writable; writable pages must not be executable. Enforced during page table construction (`paging.zig`).
- `NX`: enabled via `EFER.NXE` (`cpu.zig` line 174-217). Not verified at boot time for non-x86-64 CPUs (assumption safe for target architecture).
- `SMEP` / `SMAP`: planned but not implemented; documented as future hardening step.
- Page zero protected: user pages must not map address 0; kernel validates address in syscall arguments.

### Fault containment
- A user-mode page fault must not corrupt the kernel. The exception handler (`interrupt.s`) catches the fault, saves user context, and calls the Zig handler. The handler terminates the offending process (sets `.exiting`) and resumes another thread.
- A user-mode invalid opcode (`INT 6`) is handled the same way.
- The `idle` thread (`killed_task_loop` in `task.s`) waits in a loop with `hlt`; it does not disable interrupts (`cli` deliberately absent per `task.s` line 688-690). This ensures the timer continues to wake the idle thread.

## 5. Dependencies on existing subsystems (`docs/roadmap/K4_PROCESS_ROADMAP.md`)

The K4 stages depend on the following existing (or planned) capabilities:

| Dependency | Source module / audit finding | Required for K4 stage |
|---|---|---|
| `Task` / `Context` | `scheduler.zig`, `context.zig` | K4.3 (process/thread integration) |
| `AddressSpace` | `paging.zig`, `memory-management.md` | K4.1 (process creation), K4.4 (Ring 3 transition) |
| `TSS` / `segment.zig` | `segment.zig` (assertions verified), `cpu.zig` | K4.4 (kernel/user transition) |
| `timer.zig` | `timer.zig` (tick/EOI) | K4.3 (preemption; requires `preempt_disable` fix) |
| `syscall_abi.zig` | `shared/syscall_abi.zig` (revision 1, unstable) | K4.8 (syscalls) |
| `FPU` / `context.zig` | `context.zig` (`fp_state_offset` 192, `fxsave`/`fxrstor`) | K4.4 (user-mode FPU state preservation) |
| `ELF64` loader | `formats/kex.zig` (codec exists), `ELF64` loader partial | K4.6 (ELF loader) |
| `wait.zig` (missing) | K3.12.4 audit finding | K4.9 (wait/reap) |
| `runqueue.zig` (missing) | K3.12.4 audit finding | K4.3 (process-level scheduling) |
| `thread.zig` (missing) | K3.12.4 audit finding | K4.1 (thread handles, anti-ABA) |
| `metrics.zig` (missing) | K3.12.4 audit finding | K4.10 (resource accounting) |
| `clock.zig` / `irq.zig` / `ipi.zig` (missing) | K3.12.4 audit finding | K4.4 (per-CPU timer), K4.3 (SMP scheduling) |
| `SMP` / `smp.zig` | `smp.zig` (partial; `cpuId()` hardcoded 0) | K4.3 (multi-CPU process scheduling) |

### Blockers before K4.1 can start

Based on the K3.12.5 audit (`main` at `dfa0f8b` → `198aa66` with audit), the following must be resolved or documented before K4 implementation:

1. `wait.zig` / `runqueue.zig` / `thread.zig` / `metrics.zig` must exist (or their absence must be explicitly documented as out of scope for K4.1).
2. `scheduler.zig` must integrate `ready_queue` and fix `preempt_disable` / `need_resched` (K3.12.2 audit finding) — otherwise process-level scheduling cannot be guaranteed safe.
3. `cpuId()` must return the actual CPU (K3.12.2 audit finding) — otherwise per-CPU scheduling contracts fail.
4. `SMP` must have at least one AP started (K3.12.1 audit finding) — not required for initial K4.0 design, but must be documented as a dependency for K4.3 if multi-CPU process scheduling is required.
5. `project status` (`docs/PROJECT_STATUS.md`) and `PROJECT_STATUS.json` must remain synchronized; any new K4 stages added to the roadmap must update the JSON.

## 6. Roadmap (summary)

| Stage | Scope | Key contracts | Evidence required |
|---|---|---|---|
| K4.0 | Design (this doc) | Process, lifecycle, security contracts | ADR-K4-001; docs-check passes |
| K4.1 | Process object + handles | `Process`, `Handle`, `Generation` | Unit tests (host); no runtime required |
| K4.2 | Lifecycle + reap | State machine, reap protocol, parent/child links | Unit tests (host) |
| K4.3 | Process/thread integration | `Task` references `Process`; scheduler verifies process state | Requires `wait.zig` + `runqueue.zig` + `preempt_disable` fix |
| K4.4 | User address space + Ring 3 | User stack, syscall transition, `iretq`, `W^X` | QEMU test (user-mode syscall stub) |
| K4.5 | User memory validation + safe copy | Range validation, `copyFromUser`, `copyToUser` | Unit tests (host) |
| K4.6 | ELF64 loader | Header parse, segment validation, `W^X` check | Unit tests (host) |
| K4.7 | Native executable (`KEX`) | Manifest + payload load; dependency check | Unit tests (host) |
| K4.8 | Process syscalls | Syscall ABI integration; pointer validation | QEMU test (syscall execution) |
| K4.9 | Parent/child + wait/reap | `wait`, `reap`, `spawn` contracts | Requires `wait.zig` implementation |
| K4.10 | Security + isolation hardening | Capability enforcement, resource limits, fault containment | Unit tests (host) + QEMU stress test |

## 7. ADR produced

- `docs/decisions/ADR-K4-001-process-architecture.md`: this design; references existing `execution-model.md`, `security-architecture.md`, `memory-management.md`, `syscall_abi.zig`.
- `docs/decisions/ADR-K4-002-fork-evaluation.md` (optional, if `fork` is needed): evaluates whether `fork` (process duplication) is required for initial K4. Recommendation: deferred until K4.2 (lifecycle) proves reap and resource release work correctly.

## 8. No implementation performed

No changes to:
- `kernel/task/scheduler.zig`
- `kernel/task/thread.zig` (does not exist)
- `kernel/task/wait.zig` (does not exist)
- `kernel/task/runqueue.zig` (does not exist)
- `kernel/task/metrics.zig` (does not exist)
- `kernel/arch/x86_64/clock.zig` (does not exist)
- `kernel/arch/x86_64/irq.zig` (does not exist)
- `kernel/arch/x86_64/ipi.zig` (does not exist)
- Any source file implementing process creation, lifecycle, or syscall handling.

Only documentation, design contracts, and this report were produced.
