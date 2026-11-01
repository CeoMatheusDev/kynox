# ADR-K4-001 — Process Architecture: contracts, isolation, and dependency order

Status: **accepted for planning** (not implementation).
Date: 2026-11-01.
Related: `docs/architecture/k4-process-model.md`, `docs/architecture/k4-process-lifecycle.md`, `docs/architecture/k4-userspace-transition.md`, `docs/architecture/k4-security-process.md`, `docs/architecture/execution-model.md`, `docs/roadmap/K4_PROCESS_ROADMAP.md`.

## Context

K3.12.5 audit (`main`: `dfa0f8b` → `198aa66`) confirms that the execution model (`execution-model.md`) describes a target process/thread model that does not exist in code:

- No `thread.zig`, `wait.zig`, `runqueue.zig`, `metrics.zig`.
- `scheduler.zig` has `State.blocked` but no `preempt_disable` / `need_resched`.
- `Task` has `state`, `exit_code`, `priority`, `quantum`, `weight`, but no `running_cpu`, no integration with per-CPU queues.
- `cpuId()` hardcoded to 0 (`smp.zig`); `registerCpu` double-increments CPU 0.
- `timer.zig` has tick and EOI; no `clock.zig`, `irq.zig`, `ipi.zig`.
- `fpu.zig` missing; `context.zig` manages FPU state via `fxsave`/`fxrstor`.

K3.12.3 audit (`5e19f51` → `cc39984`) confirms context switching and FPU contracts (`Context`, `frame_size` 176, `fp_state_offset` 192, `fp_state_size` 512, `align(64)`) but no `fpu.zig` isolation.

This ADR defines the architecture for K4 and the dependency order that prevents writing lifetime code against a broken memory manager (`execution-model.md` §3: "Why processes are added after the scheduler is cleaned up: the container's correctness depends on the address-space destroy (K2) and on the lock discipline (K4).").

## Decision

1. K4 design (this ADR + `k4-process-model.md`, `k4-process-lifecycle.md`, `k4-userspace-transition.md`, `k4-security-process.md`) is produced before any K4 implementation.
2. Implementation of process management (`Process`, lifecycle, handles) is deferred until the scheduler (`scheduler.zig`) integrates `ready_queue`, `preempt_disable`, and `need_resched` (K3.12.2 audit finding).
3. `wait.zig` / `runqueue.zig` must exist before K4.2 (lifecycle + reap) and K4.3 (process/thread integration) can start.
4. `SMP` (`cpuId()` fix, AP trampoline) must be fixed before K4.3 requires per-CPU scheduling verification.
5. `ELFLoader` (`ELF64`) exists as partial code; `KEXLoader` (`formats/kex.zig`) exists as codec. They must not be mixed with process creation; separate interfaces (`ImageLoader`, `ExecutableLoader`) must maintain separation.
6. `fork` (process duplication) is deferred to ADR-K4-002; initial K4 uses independent process creation (`Create` with new `AddressSpace`).
7. `Dynamic linking` is deferred; `ELFLoader` handles `PT_INTERP` as optional; if present, loader must verify interpreter image but not load it dynamically.
8. No ABI version change (`syscall_abi.zig` revision 1 remains unstable; no revision increment until K4.8 syscalls are tested in QEMU).

## Consequences

- K4.0 (this design) produces only documentation, ADRs, and `docs-check` assertions.
- K4.1 (process object) can start if `scheduler.zig` is fixed (per K3.12.2 audit) and `wait.zig` exists (per K3.12.4 audit).
- K4.4 (userspace / Ring 3) requires `cpu.zig` (`enableFloatingPoint`), `segment.zig` (TSS), `paging.zig`, and `syscall_abi.zig` — all present, but requires `preempt_disable` and `wait.zig` for safe user-mode scheduling.
- K4.6 (ELF loader) depends on `ELFLoader` partial code; must verify `W^X` before integrating with process creation.
- K4.9 (parent/child + wait/reap) requires `wait.zig` and `reap` protocol; without these, the lifecycle contracts (`k4-process-lifecycle.md`) cannot be validated.

## References

- `docs/architecture/k4-process-model.md`
- `docs/architecture/k4-process-lifecycle.md`
- `docs/architecture/k4-userspace-transition.md`
- `docs/architecture/k4-security-process.md`
- `docs/roadmap/K4_PROCESS_ROADMAP.md`
- `docs/roadmap/KERNEL_COMPLETION_ROADMAP.md` (stages K0–K13; K4 starts after K3 validated)
- `AGENTS.md` §4.3 (assembly ABI), §4.5 (security), §7 (flow), §11 (progress tracking)
