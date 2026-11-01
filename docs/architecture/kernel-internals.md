# Kernel internals and module organisation

- Status: **planning document** for the target structure, plus a description of
  the current structure. It describes no capability that does not exist; the
  current state is the one recorded in
  [`../audits/2026-10-31-kernel-core-audit.md`](../audits/2026-10-31-kernel-core-audit.md).
- Date: 2026-10-31.
- Related: [`platform-architecture.md`](platform-architecture.md) §4.1–4.10,
  [`memory-management.md`](memory-management.md),
  [`execution-model.md`](execution-model.md),
  [`device-driver-model.md`](device-driver-model.md),
  [`../roadmap/KERNEL_COMPLETION_ROADMAP.md`](../roadmap/KERNEL_COMPLETION_ROADMAP.md),
  ADR-[0001](../decisions/0001-boot-probes-out-of-kernel-main.md),
  ADR-[0002](../decisions/0002-single-virtio-transport.md),
  ADR-[0003](../decisions/0003-legacy-virtio-blk-stub.md).

## 1. What the kernel is today

A freestanding x86-64 program, loaded by an EFI application, that:

1. validates the handoff and re-derives its own entry address;
2. installs GDT/TSS/IDT and the exception stubs;
3. runs ACPI discovery before switching page tables, then builds and activates
   its own tables;
4. brings up the heap, DMA window, PCI, the VirtIO block device, RamFS and the
   process windows;
5. installs the syscall door, IPC channels, capabilities and the scheduler;
6. starts the PIT, tries to start the APs (it cannot), and then **runs a fixed
   demonstration**: reports, self-tests, a filesystem persistence probe, a KPK
   round-trip, a framebuffer benchmark;
7. halts forever.

The last step is the important one. The kernel has no steady state: it has a
script. Everything in this document exists to turn the script into a system
whose behaviour is defined by its services, not by the order of calls in a
5 000-line function.

## 2. Target layering

```text
kernel/
  arch/x86_64/     architecture mechanisms: segments, IDT, APIC, timers, paging,
                   port I/O, context switch, syscall entry
  memory/          physical manager, virtual manager, regions, heap, DMA
  exec/            tasks, threads, processes, scheduler, wait queues, signals(1)
  ipc/             channels, shared memory, capability attachment
  security/        capability objects, handle tables, audit
  devices/         device/driver/resource model, probe queue, IRQ registry
  drivers/         kvdi/, ps2/, serial/, and later the rest
  storage/         block layer, partitions, queues
  fs/              VFS interfaces, ramfs, knv, kfsx namespace
  services/        in-kernel services with a defined interface (klog, clocks)
  init/            phase table and init steps
  diag/            counters, crash record, tracepoints
  main.zig         entry only: validate, call init, enter idle
```

Rules that make the layering real:

1. **A module may only import modules below it in this list**, plus `arch` for
   mechanisms. Violations are architectural bugs (the tree currently has one:
   `apic` ↔ `timer`).
2. **No module reaches into another module's global state.** If `X` needs data
   from `Y`, `Y` exposes a function. The audit found 126 module-level mutable
   variables; the target is that the only mutable globals are inside the module
   that owns the object, reached through functions.
3. **`main.zig` is not a module.** It parses the handoff, calls `init.run()`, and
   enters the idle loop. Target: under 200 lines.
4. **Architecture code contains no policy.** `arch` knows how to program an APIC;
   it does not decide which timer drives the scheduler.

## 3. Initialisation as data

Replace the straight-line `kmain` with a phase table:

```zig
// kernel/init/phases.zig (target)
pub const Phase = enum { early, cpu, memory, devices, services, user, self_test };

pub const Step = struct {
    phase: Phase,
    name: []const u8,
    run: *const fn () error{InitFailed}!void,
    required: bool,
};

pub const steps = [_]Step{
    .{ .phase = .early,  .name = "serial",     .run = serial.init,      .required = true },
    .{ .phase = .early,  .name = "handoff",    .run = init.validate,    .required = true },
    .{ .phase = .cpu,    .name = "segments",   .run = segment.install,  .required = true },
    ...
};
```

Properties this gives the project:

- **Order is explicit and reviewable**, and a dependency violation is visible in
  one place instead of being implied by call order.
- **Failure policy per step**: `required` steps halt with a diagnostic; optional
  steps (a missing NIC, a broken ACPI table) record a degraded state and the boot
  continues. Today any failure halts.
- **The self-test demonstration becomes a phase**, so a production boot can skip
  it (`--no-self-test` build option) while the CI boot keeps it.
- **A phase transcript** (name, cycle count, result) is printed once and is
  machine-checkable by `boot-qemu.sh`, replacing implicit assertions on line
  order.

## 4. Module contracts

Every module in the kernel declares, in its file header:

| Field | Content |
|---|---|
| Responsibility | one sentence, one subject |
| Public interface | the functions and types other modules may use |
| Internal interface | everything else; explicitly not stable |
| Dependencies | modules imported, and why |
| Concurrency | which context may call it (init, interrupt, thread, any) |
| Memory | who allocates, who frees, and the lifetime |
| Failure | what it returns on error and what state it leaves |
| Tests | the test root that covers it, or `none` and why |

The audit found that several modules already follow this in prose; the target is
to make it uniform and to have the test-root field be a real, checkable fact.

## 5. Global state policy

1. **Owned state lives in a struct instance.** A module keeps at most one
   `var` for its own instance, or none if the instance is passed in.
2. **No cross-module `var`.** `main.zig` currently exposes 63; the target is 0.
3. **Per-CPU state is one struct reached through `percpu.current()`**, never an
   array indexed by `apic.readApicId()` at every use.
4. **Immutable configuration is `const`** and set at build time or at init.
5. **Anything mutable and shared carries its lock in the same struct** and the
   module header says which lock protects which field.

## 6. Error model

The kernel already returns Zig errors from most pure modules. The gaps are in the
boot path, where `haltForever` is the universal answer, and in the driver paths,
where a quarantine is used for one class of failure only.

| Layer | Model |
|---|---|
| Pure modules (parsers, codecs, allocators) | Zig error set, no side effects on failure |
| Architecture mechanisms | error return; the caller decides whether the failure is fatal |
| Init steps | `error{InitFailed}` plus a `required` flag and a logged reason |
| Drivers | typed error per request (`Timeout`, `DeviceFault`, `Quarantined`, `InvalidArg`); the device state machine records the transition |
| Syscalls | negative status codes from `shared/syscall_abi.zig` |
| Kernel fault | crash record + halt; never "continue and hope" |

Rule: **no function returns success after doing nothing.** The audit found one
(`net_transmit`); the rule exists because that pattern is invisible at the call
site and poisons every status report built on top of it.

## 7. Naming and interface size

- Public functions carry the module's subject: `physical.allocate`, not `alloc`.
- A module's public surface is reviewed for size; above ~12 functions is a signal
  that it has more than one responsibility.
- Types that cross a module boundary are defined in the module that owns them and
  re-exported, never duplicated.
- Constants that describe a shared layout (the process window, the syscall frame)
  live in `shared/`, because user space needs them too.

## 8. Directory changes proposed (small, ordered)

| Step | Change | Why | Risk |
|---|---|---|---|
| 1 | `kernel/init/` with the phase table; `main.zig` reduced to entry + phases | the audit's defect #9 | low, mechanical, covered by the boot markers |
| 2 | `kernel/diag/` for the crash record, counters and the self-test phase | removes the demonstration from the boot path | low |
| 3 | `kernel/exec/` for tasks, scheduler, wait queues (moved from `task/`) | one name for one concept; `task/` and `arch/.../task.s` are confusing today | medium: imports |
| 4 | `kernel/devices/` for the device/driver/resource model | there is no such directory today; drivers own their own lifecycle | low until the model exists |
| 5 | delete `kernel/arch/x86_64/elf_compat.zig`, `kernel/fs/dir_entry.zig`, `kernel/fs/test_ramfs_runner.zig` | dead code (audit §10 #15) | none |
| 6 | delete `kernel/arch/x86_64/virtio.zig` and `virtio_blk.zig` after moving their live tests | ADR-0002 step 3, ADR-0003 | medium: 15 tests |
| 7 | move `kernel/graphics/*` out of the kernel, later | ADR-0006; not part of this initiative | high, and explicitly deferred |

Items 1–6 are part of the kernel completion roadmap. Item 7 is not: it belongs to
the graphics platform stages and needs the user-space compositor to exist first.

## 9. Refactors justified by the audit (and the ones not justified)

**Justified, because they are prerequisites for correctness:**

| Refactor | Reason | Stage |
|---|---|---|
| Break `apic` ↔ `timer` | a cycle makes both untestable and hides the timer's ownership of the tick | K1 |
| Extract scheduler policy from mechanism | 0 tests today; the policy is pure arithmetic that *can* be tested | K4 |
| Split `main.zig` into phases | every change touches the file that boots | K0 |
| Introduce regions in the VMM | without them, no demand paging, no file mapping, no teardown | K2 |
| Make `arch` expose a per-CPU TSS | the single TSS silently breaks SMP | K3 |

**Not justified now (documented so that nobody does them "for cleanliness"):**

- Rewriting the RamFS: it is the best-tested module (60 tests) and its limits are
  known.
- Replacing the KVDI transport: 173 tests, a containment model and a fault
  injection harness; it needs completion, not replacement.
- Moving the compositor out of the kernel: correct target, but it depends on the
  user-space compositor and the display core, both of which are outside this
  initiative.
- Rewriting the syscall ABI: revision 1 is contract-checked and coherent; it needs
  one safety primitive and more calls, not a redesign.

## 10. Observability as a first-class citizen

The kernel's diagnostics are serial lines and counters. The target adds:

1. **A crash record**: fixed 512-byte structure with reason, vector, rip, CR2,
   the last 16 tracepoints, and the init phase reached. Survives into the next
   boot when the storage is writable.
2. **Tracepoints**: named, compile-time-selected events with a timestamp, written
   to a per-CPU ring; zero cost when disabled.
3. **A per-subsystem health block**: counters plus a state (`ok`, `degraded`,
   `quarantined`) that a future shell can query.

These exist so that the roadmap's later stages can be measured instead of
argued about.

## 11. Coding standards (binding for kernel work)

1. **Ownership is in the type or in the function name.** `allocate`, `destroy`,
   `borrow`, `release`. A function that stores a pointer says who must free it.
2. **No allocation in an interrupt handler.** Handlers record events and wake
   waiters; they do not allocate, copy user memory or log dynamically.
3. **No lock held across a user copy, a wake-up or a page fault.**
4. **Every loop that waits on hardware has a bound**, and the bound has a name
   (`timeout_polls`, `budget_ticks`) and a documented unit. A retry count is not
   a timeout; when the unit is time, use the tick source.
5. **Every `pause`/`hlt` loop must be reachable only from the idle or INIT
   state**, never from a path that is supposed to make progress.
6. **Atomics state their ordering**, and the ordering is justified in one line
   (`acquire` because we observe the producer's writes).
7. **Structure layout that matches a hardware format uses `extern struct`** with
   compile-time offset assertions, as `segment.zig` already does.
8. **A new module ships with its test root registration** or an explicit note in
   the module header saying why it cannot be host-tested.
9. **No `@panic` in a path reachable from user input**; return an error.
10. **Measure before optimising**: a change to a hot path cites a number from
    `kernel/diag` counters or a benchmark, not an intuition.

## 12. What "done" means for the kernel

Not "all features", but these four properties, each with evidence:

| Property | Evidence |
|---|---|
| It boots to a steady state on virtual hardware | recorded QEMU serial log with the phase transcript and no self-test | 
| It does not corrupt itself under concurrency | SMP enabled on 2+ APs, a stress test that hammers the scheduler, IPC and memory, and a clean run |
| It can be shut down and rebooted | ACPI power-off and reset, verified in the emulator with a power state assertion |
| Its failures are diagnosable | crash record retrieved after an injected fault, and a tracepoint-based test that reproduces it |

Everything else — drivers, filesystems, services — is built on those four, which
is why the roadmap puts them first.
