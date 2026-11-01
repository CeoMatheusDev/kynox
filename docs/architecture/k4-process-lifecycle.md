# K4 — Process Lifecycle Design

Status: **planning document**; no implementation.
Reference: `docs/architecture/k4-process-model.md`, `docs/architecture/execution-model.md`.

## 1. Lifecycle states (`ProcessState`)

```
not_started → initializing → running → (exiting | blocked) → exited → reaped → freed
```

- `not_started`: object allocated; no threads, no space.
- `initializing`: space assigned; initial thread created; capabilities initialized.
- `running`: process active; may spawn threads; may block.
- `exiting`: exit requested; no new threads allowed; existing threads must finish or be terminated by policy (not in initial scope).
- `blocked`: process blocked on wait; applies to container, not threads.
- `exited`: all threads finished; exit code recorded; resources still held.
- `reaped`: parent (or init) read exit code; resources released; generation incremented.
- `freed`: object deallocated; `pid` recyclable with new generation.

## 2. Create (`Create`)

Inputs: executable image (`ELF` or `KEX`), capability grants.
Steps:

1. Allocate `Process` object with new `pid` and `generation`.
2. Assign `AddressSpace` (new space, not shared unless `fork` implemented — deferred by ADR-K4-002).
3. Create initial thread (`Task`): set `process` reference, `context` with entry point from executable header, `stack` (user stack), `kernel_rsp` (kernel stack).
4. Initialize capabilities: grant basic capabilities (console, file access to executable image) based on manifest; deny all others.
5. Set state to `initializing`, then `running` when initial thread enters ready queue.

Invariants:
- `Create` must complete before `Publish` (process visible to other processes).
- `Create` fails if executable header is invalid, `W^X` violated, or resource limits exceeded.
- `Create` does not modify any other process's `CapabilityTable`.

## 3. Initialize and Publish

- `Publish`: make process visible in process list (if process registry exists — not implemented in current tree; `fs` uses fixed `max_processes = 8` per `execution-model.md`).
- `Initialize`: final setup before `running`: set `parent`, initialize `ResourceLimits`, verify `AddressSpace` mapping.

No new code required for `Publish`/`Initialize` if process registry is deferred; documentation only.

## 4. Execute (thread scheduling)

- Threads scheduled by `scheduler.zig`; `Task` has `priority`, `quantum`, `weight`.
- The process container (`Process`) is checked by the scheduler: a thread from a process in `.exited` or `.reaped` must not be selected (requires `scheduler.zig` integration — missing per K3.12.4 audit).
- A process in `.exiting` may have running threads; the scheduler continues to run them until all finish.

## 5. Block (`Wait`)

- `Wait` applies to the process container: parent waits for child to exit.
- Implementation requires `wait.zig` (missing per K3.12.4 audit). The design contracts:
  - Parent thread blocks; `wait` syscall sets parent process state to `.blocked`.
  - Child exit sets parent process state back to `.running` and wakes parent thread.
  - No lost wakeup: `wait` protocol must verify condition atomically with scheduling lock (requires `wait.zig` infrastructure).
- Timeout: if `wait` has timeout, timer tick (`timer.zig`) must wake parent with timeout error. No deadline module (`clock.zig` missing) means timeout must be handled by `timer.ticks()` difference.

## 6. Exit (`Exit`)

- Any thread in the process may call exit (syscall number 4 per `user_program` in `task.s`).
- `Exit` sets process state to `.exiting`; records `exit_code`.
- All threads must finish before reap; the scheduler must continue running threads from `.exiting` process.
- If `terminateCurrent` is called, the current thread must not free its own stack (`execution-model.md` invariant 2); it switches to idle/reaper context.

## 7. Reap (`Reap` / `Join`)

- `Reap` reads `exit_code`, verifies `generation`, releases `AddressSpace`, releases capabilities, increments `generation`, frees `Process` object.
- Reap must verify no running threads remain (`Task.schedules` > 0? No — `schedules` is count; must verify `Task.state` is `.terminated` or `.ready` with no active CPU assignment).
- Reap must not be duplicated: `reap_reference` handle must match current `generation`; duplicate reap must fail.
- Reap must handle parent process: child list cleaned; parent state updated.

Invariants:
- A process in `.reaped` cannot be reap'd again (generation changed; handle stale).
- A process in `.exiting` cannot be reap'd (threads still running).
- A process with `.blocked` parent must unblock parent on reap (requires `wait.zig`).

## 8. Resource release order

1. Capability table revoked (before reap completes).
2. Child list cleaned (before reap completes).
3. Address space destroyed (after reap, before generation increment).
4. Process object freed (after all references removed).

This matches `execution-model.md`: "Exit is not destruction. The thread records its exit status and moves to `exited`; its kernel stack is freed when the last joiner or the reaper runs."
