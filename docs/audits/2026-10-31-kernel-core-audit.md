# Kernel and core systems audit — 2026-10-31

- Status: **audit record**. It describes the tree as it is; it is not a plan and
  it claims no capability. The planning that follows from it lives in
  [`../roadmap/KERNEL_COMPLETION_ROADMAP.md`](../roadmap/KERNEL_COMPLETION_ROADMAP.md).
- Scope: kernel, boot, memory, execution, kernel services, drivers, storage and
  the essential systems (console, input, time, power, diagnostics).
- Out of scope by decision: Linux/Windows compatibility, KGA/KGX/KGL/KVK,
  renderer, compositor and desktop features. Where they influence kernel
  structure, they are mentioned only as such.
- Predecessor: [`2026-10-31-audit.md`](2026-10-31-audit.md) (tree, governance,
  alpha gate). This document does not repeat its findings.
- Baseline: commit `343e9fb`, 49 build steps, **709 host tests**, no QEMU/OVMF
  run ever recorded.

## 0. How to read the classification

| Class | Meaning in this audit |
|---|---|
| `NOT_STARTED` | No code, or only a declaration with no behaviour |
| `STUB` | A structure or function exists whose observable behaviour is a refusal, an empty body or a fixed answer |
| `PARTIAL` | It works for the narrow path that the boot demo exercises, and the general contract is missing |
| `IMPLEMENTED` | It fulfils a defined scope with tests for that scope, and the scope is stated |
| `INTEGRATED` | Callers in the real path depend on it and it is exercised through them |
| `VALIDATED` | Evidence exists at the stated level: `host`, `emulator` or `hardware` |

**No kernel subsystem in this tree is `VALIDATED` at emulator or hardware level.**
No QEMU/OVMF run has ever been recorded (`docs/validation/qemu.md`), so every
statement about runtime behaviour is a code reading, not an observation. Where a
pure module has host tests, the classification says `VALIDATED (host)` and names
the scope that the tests actually cover.

## 1. Headline findings

1. **The kernel is a boot-time demonstration harness, not a running system.**
   `kynox_kmain` (4 974 lines, 114 functions, 63 module-level variables) performs
   every initialisation, then runs a fixed sequence of self-tests, reports and
   benchmarks, and ends in `port.haltForever()`. There is no idle task, no init
   process, no service manager and no way to shut down or reboot.
2. **User processes have a 24 KiB window, not an address space.**
   `shared/usermode.zig: window_size = 0x6000`, enforced by the ELF planner and
   the materialiser. There are 8 static address-space slots
   (`paging.max_process_spaces`), and **no address-space destruction**: the slot
   allocator is never decremented outside tests.
3. **There is exactly one TSS**, with one `rsp0` and one double-fault IST stack
   (`segment.zig`). Even if an AP started, ring-3 entry on that AP would run on
   the BSP's kernel stack.
4. **The scheduler has no synchronisation and no tests.** `Scheduler` is a
   struct of plain arrays in BSS; `current[]`, `ready_queue[]`, `statistics` and
   the task table are written from the timer handler and from syscall paths with
   no lock, no atomic and no per-CPU ownership rule. `kernel/task/scheduler.zig`
   has **0 tests** and is not part of any host test root.
5. **Physical memory is never returned to the allocator when a page is
   unmapped.** `paging.unmapUserPageIn`/`unmapKernelPage` clear the entry and
   flush the TLB but never call `physical.manager.free`. Only `dma.release` and
   the ELF materialiser's failure path free pages.
6. **The capability table cannot be freed.** `capability.create` allocates from a
   16-entry global array and there is no `destroy`; `max_held = 8`,
   `max_processes = 8`. A system that creates more than sixteen capabilities in
   its lifetime stops creating them.
7. **Drivers cannot register interrupts.** The interrupt handler dispatches by
   raw vector: 32 is the PIT, 33 is the PC keyboard, 34–47 are acknowledged and
   ignored. There is no `register(vector, handler)` API, no MSI programming (only
   MSI capability *detection* in `pci.zig`), and no spurious-IRQ accounting.
8. **Two modules form an import cycle** — `apic.zig` imports `timer.zig` and
   `timer.zig` imports `apic.zig`.
9. **`virtio_net.net_transmit()` is an empty function returning success.** That
   is the anti-pattern `AGENTS.md` §10 forbids: a stub that publishes a success.
10. **No TLB shootdown exists.** `paging.zig` documents that a caller "must
    provide a TLB shootdown" and nothing implements it; `cpu.invlpg` only touches
    the calling CPU.

## 2. A. Boot and architecture

### A.1 UEFI bootloader

- **Files:** `boot/uefi/main.zig` (325), `boot/uefi/knb/{loader,memory,fs,protocols,framebuffer,console}.zig`.
- **Works:** loads its own image, allocates, loads `/boot/KYNOXK.ELF` from the
  FAT image it built into, places the kernel, captures the memory map, the
  framebuffer and the RSDP, calls `ExitBootServices` with retry, transfers
  control once.
- **Missing:** a firmware matrix (only the code path exists, never observed in a
  VM here); 5-level paging selection; secure boot verification of the kernel
  image; a second-stage configuration file; any recovery path if the kernel
  image is corrupt.
- **Dependencies:** UEFI services, FAT reader (`boot/uefi/knb/fs.zig`), handoff
  contract.
- **Known bugs:** none proven; `docs/PROJECT_STATUS.md` records that the loader
  logic has no host tests.
- **Risks:** the loader is the only component that can validate the kernel
  before it runs, and it verifies nothing.
- **Tests:** none. **Evidence:** code reading; boot never observed.
- **Classification:** `PARTIAL`.
- **Next:** host-testable ELF placement unit tests, then a recorded QEMU run;
  add a hash check of the kernel image before the jump.

### A.2 Boot handoff (KNB → KNK)

- **Files:** `shared/handoff.zig` (318), `docs/specs/boot-handoff-spec.md`.
- **Works:** magic/version/size validation, memory map copy into the kernel,
  framebuffer and RSDP fields, entry-address cross-check.
- **Missing:** handoff v2 extras (NVDIMM, reserved regions) planned in
  `platform-architecture.md` §4.1; the kernel copies at most 1 024 descriptors
  and silently truncates beyond that.
- **Dependencies:** bootloader, kernel entry.
- **Bugs:** the truncation at `max_memory_descriptors` is not reported.
- **Risks:** a machine with a very fragmented memory map loses descriptors.
- **Tests:** 6 host tests in `shared/memmap.zig`; `handoff.validate` is covered
  indirectly. **Evidence:** host tests only.
- **Classification:** `IMPLEMENTED` (contract), `VALIDATED (host)`.
- **Next:** report truncation as a boot warning; add a host test with 2 000
  descriptors.

### A.3 GDT / TSS / segments

- **Files:** `kernel/arch/x86_64/segment.zig` (364), `segment.s`.
- **Works:** GDT with kernel/user code and data, TSS with `rsp0` and `ist1`,
  compile-time layout assertions, `ltr`.
- **Missing:** per-CPU TSS and per-CPU IST stacks; `rsp0` is a single global
  updated by the scheduler on every switch, which is only correct on one CPU.
- **Dependencies:** none.
- **Bugs:** none proven; the single-TSS design is a structural bug for SMP.
- **Risks:** silent stack corruption the moment a second CPU runs ring 3.
- **Tests:** 3 host tests (layout only). **Evidence:** host.
- **Classification:** `PARTIAL` (single-CPU correct, SMP-unsafe).
- **Next:** per-CPU TSS array with `rsp0` and `ist1` per CPU; a test that asserts
  the TSS is selected through the per-CPU area.

### A.4 IDT and interrupt stubs

- **Files:** `kernel/arch/x86_64/interrupt.zig` (505), `interrupt.s` (351).
- **Works:** 256 gates, 32 exception stubs with error-code handling, 16 IRQ
  stubs, vector 64 for the LAPIC timer, `verify()`.
- **Missing:** IST wiring for machine check and NMI; a gate-type policy table;
  dynamic vector allocation.
- **Dependencies:** segment.zig.
- **Bugs:** none proven. **Risks:** stub count is fixed; adding a vector means
  editing assembly, the extern list and `stubFor`.
- **Tests:** 0. **Evidence:** code reading.
- **Classification:** `PARTIAL`.
- **Next:** replace the hand-written extern list with a table generated at
  comptime, and add host tests for the table arithmetic.

### A.5 Exception handling

- **Files:** `kernel/arch/x86_64/interrupt.zig` (`kynox_exception_handler`).
- **Works:** prints vector, error code, CR2, register dump; if the fault came
  from ring 3 and a current task exists, the task is killed and its frame is
  rewritten to a kernel loop.
- **Missing:** page-fault resolution (no demand paging, no COW, no stack growth);
  fault delivery to a process as a signal; kernel-fault recovery; a fault handler
  registry; a machine-readable fault record.
- **Dependencies:** scheduler, paging.
- **Bugs:** `rewriteFrame` computes the frame position by pointer arithmetic that
  depends on `@sizeOf(Registers)` and the error-code convention — a single wrong
  stub and the kernel rewrites the wrong stack slot. It has no test.
- **Risks:** every user fault is terminal for the process, and every kernel fault
  is terminal for the machine.
- **Tests:** 0 (a runtime `UD2` self-test exists, but no host test of the frame
  layout). **Evidence:** code reading.
- **Classification:** `PARTIAL`.
- **Next:** host test of the frame layout using a synthetic stack; a fault
  registry for the page fault.

### A.6 Local APIC

- **Files:** `kernel/arch/x86_64/apic.zig` (425), `ioapic.zig` (456 — separate).
- **Works:** base discovery through the MADT with fallback, enable, EOI, IPI
  send, LAPIC timer programming and calibration against the PIT, `readApicId`
  masked to eight bits.
- **Missing:** x2APIC, per-CPU timer state, spurious-interrupt accounting, timer
  per CPU actually used by the scheduler (the scheduler uses the PIT vector).
- **Dependencies:** `timer.zig` (import cycle), `cpu.zig`, MADT.
- **Bugs:** the import cycle makes the module impossible to host-test in
  isolation, which is part of why `arch.zig` tests only cover pure helpers.
- **Risks:** timer calibration depends on the PIT still running.
- **Tests:** 8 (ioapic), apic tests are within arch root. **Evidence:** host.
- **Classification:** `PARTIAL`.
- **Next:** move the timer facts `apic` needs into a small `constants` module to
  break the cycle, then test the cycle-free module.

### A.7 I/O APIC

- **Files:** `kernel/arch/x86_64/ioapic.zig`.
- **Works:** MMIO controller abstraction, redirection entry programming with GSI,
  polarity and trigger taken from the MADT overrides, irq-safe lock, 8 tests.
- **Missing:** delivery has **never been observed**; the entries are programmed
  masked and the 8259 still delivers. ISA overrides are applied for IRQ0/IRQ1
  only. No MSI routing, no interrupt remapping.
- **Dependencies:** ACPI/MADT, MMIO.
- **Bugs:** none known after the destination-0 fix (`85a5cbd`).
- **Risks:** the `-Dioapic-delivery=true` build option has never been booted, so
  the delivery path is entirely unproven.
- **Tests:** 8 host. **Evidence:** host only.
- **Classification:** `PARTIAL`.
- **Next:** boot the delivery build in a VM, assert a counter on the PIT vector
  arriving through the I/O APIC, then retire the 8259 for the timer.

### A.8 ACPI / MADT / CPU discovery

- **Files:** `kernel/arch/x86_64/acpi.zig` (953), `docs/specs/acpi-platform.md`.
- **Works:** RSDP/XSDT/MADT discovery with checksum and length validation; LAPIC
  base; IOAPIC list; interrupt source overrides; enabled processor table with
  BSP by APIC id and duplicate skipping; `isaRoute`.
- **Missing:** DSDT/AML parsing entirely; `_PRT`/PCI GSI routing (PCI IRQs are
  therefore not mapped); `_OSI`; power resource control; S3/S4/S5 evaluation;
  FADT flags beyond what is read; HPET table.
- **Dependencies:** boot handoff (RSDP), paging.
- **Bugs:** none known. **Risks:** PCI interrupt routing cannot work without
  `_PRT`, so adding a second driver with a legacy IRQ will need AML.
- **Tests:** 22 host. **Evidence:** host, substantial.
- **Classification:** `IMPLEMENTED` for MADT/RSDP, `VALIDATED (host)`;
  `NOT_STARTED` for AML/power.
- **Next:** `_PRT` extraction requires a minimal AML interpreter — a project of
  its own; until then, use MSI for PCI devices.

### A.9 SMP and AP startup

- **Files:** `kernel/arch/x86_64/smp.zig` (441), `ap_trampoline.s` (286).
- **Works:** CPU table from the MADT, logical CPU numbering by APIC id, AP
  stacks, INIT/SIPI sequence gated behind `trampoline_ready`, 8 tests.
- **Missing:** **the trampoline is never published** (`publishTrampoline` has no
  caller) so no AP has ever started; no per-CPU GDT/TSS; no per-CPU scheduler
  state initialisation; no AP enable sequence for the LAPIC; no IPI beyond
  INIT/SIPI; no TLB shootdown IPI.
- **Dependencies:** ACPI, APIC, paging, segment.
- **Bugs:** none proven; the feature is disabled by construction.
- **Risks:** enabling APs without per-CPU TSS and without scheduler locking would
  corrupt state rather than improve throughput.
- **Tests:** 8 host (table arithmetic). **Evidence:** host.
- **Classification:** `PARTIAL`, explicitly blocked.
- **Next:** the ordered prerequisite list is stages `K0` and `K2` in the kernel
  roadmap: per-CPU data and per-CPU TSS (K0) → trampoline publication → AP
  enable → AP idle loop (K2), in that order, each with its own evidence.

### A.10 Per-CPU data

- **Files:** `kernel/arch/x86_64/smp.zig` (`Cpu`, `cpus[]`).
- **Works:** a static array indexed by logical CPU id, with a lock field that is
  never used, and `cpuId()` derived from the APIC id on every call.
- **Missing:** GS-based per-CPU access (every lookup re-reads the APIC, which is
  an MMIO read on some paths; `apic.readApicId` is an MMIO read), no idle task
  pointer, no preemption counters, no per-CPU run queue ownership enforcement.
- **Dependencies:** APIC.
- **Bugs:** `current_task` in `Cpu` is never written; the scheduler keeps a
  separate array. Two sources of truth for "what runs here".
- **Risks:** APIC-id lookups in hot paths; divergent task pointers.
- **Tests:** covered by the 8 smp tests. **Evidence:** host.
- **Classification:** `STUB`.
- **Next:** one `percpu` struct as the single source of truth, reached through
  GS, with `current_task`, `idle`, `preempt_count`, `run_queue`.

### A.11 Kernel entry and initialisation

- **Files:** `kernel/arch/x86_64/entry.s`, `kernel/main.zig`.
- **Works:** stack setup, switch to the kernel-owned stack, call into Zig.
- **Missing:** a structured init phase system (ordered, with dependencies and
  failure policy); the current order is a 200-line straight-line function with
  comments.
- **Bugs:** `kmain` mixes bring-up with demonstration; a failure anywhere calls
  `haltForever` with a serial line.
- **Risks:** no way to add or remove an initialisation step without editing the
  middle of a 5 000-line file; no way to boot without the demo.
- **Tests:** none. **Evidence:** code reading.
- **Classification:** `PARTIAL`.
- **Next:** `kernel/init/` with an explicit phase table (`early`, `cpu`,
  `memory`, `devices`, `services`, `self_test`), each phase a list of steps with
  a return value and a policy.

### A.12 Panic and fault reporting

- **Files:** `kernel/main.zig:kernelPanic`, `shared/arch/x86_64/serial.zig`.
- **Works:** formatted panic message with return address, halts.
- **Missing:** stack unwinding, a crash dump record, panic reason codes, a way to
  preserve the log after reboot, NMI/machine-check paths.
- **Classification:** `STUB`.
- **Next:** a fixed-size in-memory crash record written before halting, plus a
  symbol table side-file generated at build time.

## 3. B. Memory management

### B.1 Physical memory manager

- **Files:** `kernel/memory/physical.zig` (479).
- **Works:** bitmap over the first 4 GiB, init from the firmware map, reserve,
  contiguous allocation with a ceiling, single-page allocation with a rotating
  hint, free, `isUsed`, statistics, 8 tests.
- **Missing:** memory above 4 GiB (reported as an error, by design); NUMA; zones;
  page-colour or locality policy; huge-page-aware allocation; poisoning; leak
  accounting; per-owner charging.
- **Dependencies:** handoff map.
- **Bugs:** none proven. `minimum_address = 1 MiB` protects low memory, but the
  trampoline for APs will need real-mode memory below 1 MiB, which the manager
  currently refuses to hand out.
- **Risks:** the 4 GiB cap is a hard ceiling that will be hit on any modern
  workstation; the bitmap is 128 KiB in BSS, so it cannot move without a design
  change.
- **Tests:** 8 host. **Evidence:** host.
- **Classification:** `IMPLEMENTED` for <4 GiB, `VALIDATED (host)`.
- **Next:** a second bitmap for the high range with the same API, and a
  `reserveLowMemory` path for the AP trampoline.

### B.2 Virtual memory manager and page tables

- **Files:** `kernel/arch/x86_64/paging.zig` (1 192).
- **Works:** four-level tables, kernel/device/user mappings with NX, static pools
  for level-2 and level-1 tables, per-process private level-1 table, permission
  change, unmap, translation, `isUserRange` verification, 9 tests.
- **Missing:** region abstraction (no `VMA`/`Region` object, so nothing can
  describe "this range is a stack" or "this range is a file mapping"); demand
  paging; COW; guard pages as a contract; huge pages; address-space destruction;
  TLB shootdown; ASLR; high-half kernel.
- **Dependencies:** PMM, cpu.
- **Bugs:**
  - `process_spaces_used` is never decremented: creating more than
    `max_process_spaces` (8) address spaces fails permanently.
  - `paging.window_pages = 4` is dead and contradicts `usermode.window_size`
    (6 pages).
  - unmapping never frees the physical frame.
- **Risks:** the fixed pools (`level2_pool`, `level1_pool`) are sized for the
  current single address-space-per-process model; general mappings will exhaust
  them with no diagnostic.
- **Tests:** 9 host (pure helpers only). **Evidence:** host.
- **Classification:** `PARTIAL`.
- **Next:** see [`../architecture/memory-management.md`](../architecture/memory-management.md):
  region objects, per-address-space page-table allocation from the PMM,
  `destroyAddressSpace`, and `unmap` returning frames.

### B.3 Address spaces and process isolation

- **Files:** `kernel/arch/x86_64/paging.zig` (`AddressSpace`, `createAddressSpace`,
  `activateSpace`).
- **Works:** the process sees the kernel image plus a private level-1 table for
  its window; `activateSpace` switches CR3.
- **Missing:** full user address space; per-process gate/stack; destruction;
  quotas; accounting.
- **Bugs:** the private level-2 table is copied from the kernel's once, so any
  later kernel mapping in the same 2 MiB block is invisible to existing spaces.
- **Risks:** a kernel mapping added after the first process is created is missing
  in every existing address space — a latent fault delivery bug that would appear
  as a kernel page fault in user context.
- **Classification:** `PARTIAL`.
- **Next:** shared kernel half by construction (high-half) or a documented
  `mapIntoAllSpaces` helper; the high-half decision is question 1 of the memory
  document.

### B.4 Kernel heap

- **Files:** `kernel/memory/heap.zig` (358).
- **Works:** first-fit free list with coalescing, statistics, 6 tests.
- **Missing:** locking (none), alignment beyond a fixed policy, size classes,
  guard pages, poisoning, a per-subsystem accounting hook.
- **Risks:** unsafe on SMP; fragmentation is unmeasured.
- **Tests:** 6 host. **Classification:** `IMPLEMENTED`, `VALIDATED (host)` for
  single-threaded use.
- **Next:** a lock derived from the concurrency model (leaf lock), then a
  fragmentation measurement under a scripted workload.

### B.5 DMA memory

- **Files:** `kernel/memory/dma.zig` (492).
- **Works:** 64 MiB virtual window at `0x4000_0000`, page mapping with cache
  disabled, kernel window allocator with a bitmap, free, 7 tests.
- **Missing:** IOMMU domains; scatter-gather; bounce buffers; per-device
  ownership; leak accounting for the window.
- **Dependencies:** paging, PMM.
- **Classification:** `PARTIAL`.
- **Next:** device-scoped DMA arenas so a driver cannot allocate outside its
  budget.

### B.6 Memory protection and W^X

- **Files:** `paging.zig` (`UserPageFlags`), `elf_materializer.zig`.
- **Works:** NX enforced and required at boot, ELF segments mapped with the
  segment's permissions, a page copied writable then protected.
- **Missing:** SMEP/SMAP programming (the status file lists them as absent),
  guard pages, stack executability policy, `PROT_EXEC` refusal policy.
- **Classification:** `PARTIAL`.

### B.7 Page faults

- **Files:** `interrupt.zig` (report only), `paging.describe`.
- **Works:** reports the fault; a user fault kills the process.
- **Missing:** everything a fault handler needs to resolve one. See §2 A.5.
- **Classification:** `STUB`.

### B.8 Memory statistics and diagnostics

- **Files:** `physical.statistics`, `heap.statistics`, `dma`, `main.zig` reports.
- **Works:** totals, used, free, highest address; heap statistics.
- **Missing:** per-owner accounting, high-water marks, leak reports, a queryable
  interface for a future shell.
- **Classification:** `PARTIAL`.

## 4. C. Execution and concurrency

### C.1 Scheduler

- **Files:** `kernel/task/scheduler.zig` (746), `context.zig`, `task.s` (728).
- **Works:** preemptive round-robin with a per-task quantum, priority field
  (consulted by `findNextReady`), EEVDF-style `vruntime`/`deadline` fields,
  blocking on an IPC channel or on input with a timeout, kill, terminate,
  statistics including switch cost, stack canary on switch.
- **Missing:** any lock; per-CPU run queues (the array exists and is used, but
  only for CPU 0); an idle task; CPU affinity; migration; wake-up on sleep;
  priority inheritance; a periodic tick budget; preemption of kernel code (there
  is none: the only preemption points are the timer return path).
- **Bugs:**
  - `current[]` is written by `init` at index 0 regardless of the CPU that runs
    it.
  - `statistics` is incremented from interrupt context and read from thread
    context with no protection.
  - `enqueueReady` silently drops a task when the per-CPU queue is full.
- **Risks:** the whole scheduler is single-CPU by construction while the code
  *looks* per-CPU. That gap is the largest correctness risk in the kernel.
- **Tests:** **0**. Not in any test root; importing it pulls in arch code.
- **Evidence:** code reading only.
- **Classification:** `PARTIAL`.
- **Next:** see [`../architecture/execution-model.md`](../architecture/execution-model.md):
  extract the pure policy (selection, vruntime, quantum) from the mechanism
  (context switch, run queue) so the policy becomes host-testable, then add
  locking and per-CPU ownership.

### C.2 Context switching

- **Files:** `kernel/arch/x86_64/task.s`.
- **Works:** saves and restores general registers, switches CR3 when the space
  changes, updates `rsp0`, measures the switch cost with the TSC, checks the
  stack canary.
- **Missing:** FPU/SSE state save (not saved on switch — see bug), per-CPU TSS
  update, lazy FPU.
- **Bugs:** the comment in `task.s` explains that vector registers are *not*
  saved. Any task that uses SSE (which the compiler may emit in Zig code) can
  corrupt another task's floating-point state. This is a real, latent
  correctness bug masked by the current demo's simple arithmetic.
- **Risks:** silent data corruption in any compute-heavy task.
- **Tests:** none. **Classification:** `PARTIAL`.
- **Next:** FXSAVE/FXRSTOR area per task (or XSAVE if available), with a test
  that two tasks hammering FP registers keep their values.

### C.3 Thread and process lifecycle

- **Files:** `scheduler.zig` (`spawn`, `spawnUser`, `terminateCurrent`,
  `killCurrent`), `main.zig` (`installProcess`).
- **Works:** a task can be created with a stack and an entry point; it can exit
  and it can be killed; the PCBs and stacks are static arrays.
- **Missing:** process objects distinct from tasks (there is no process that owns
  several threads, no PID namespace, no `wait`, no `exec`, no `fork`); no
  reaping; no reclamation of a terminated task's stack, address space, page
  tables, capabilities or open files.
- **Bugs:** `terminateCurrent` marks the task `.terminated` but the task slot is
  never reused (`allocate` scans for `null`, and slots are never nulled).
- **Risks:** every process start permanently consumes a task slot and an address
  space slot; the system can start at most 32 tasks for its lifetime.
- **Classification:** `PARTIAL`.
- **Next:** a process object with a reference count, plus `reap` that releases
  slots, stacks, spaces, capabilities and files.

### C.4 Preemption and priorities

- **Files:** `scheduler.zig`, `timer.zig`.
- **Works:** a 100 Hz tick decrements the quantum and switches.
- **Missing:** kernel preemption points, priority inversion handling, real-time
  class, tickless operation.
- **Classification:** `PARTIAL`.

### C.5 Synchronisation primitives

- **Files:** `kernel/arch/x86_64/spinlock.zig` (3 tests).
- **Works:** `Spinlock` (TAS with pause, acquire/release), `IrqSpinlock`
  (save/restore RFLAGS). Both are correct as written.
- **Missing:** mutex (sleepable), read/write lock, condition variable, wait queue,
  semaphore, `Atomic` wrapper with documented orderings, lock-order assertions,
  lockdep-style deadlock detection.
- **Usage:** only `pci.zig`, `ioapic.zig` and an unused field in `smp.Cpu`.
  No core data structure is protected.
- **Classification:** `IMPLEMENTED` for the two lock types, `NOT_STARTED` for the
  rest.
- **Next:** wait queues are the single most valuable addition, because blocking
  currently only exists as a special case of IPC and input.

### C.6 Timers, sleep and wake-up

- **Files:** `kernel/arch/x86_64/timer.zig` (233), `apic.zig` (LAPIC timer).
- **Works:** PIT at 100 Hz, tick counter, EOI for both PICs, LAPIC timer
  calibration and one-shot programming for SMP.
- **Missing:** a sleep queue (there is no `sleep(ms)`), a general timer wheel,
  HPET, RTC/wall clock, per-CPU tick accounting.
- **Bugs:** the PIT is still the scheduler's clock although the LAPIC timer is
  calibrated; both are enabled after `installTimer`/`installSmp`, so a CPU may
  receive two tick sources.
- **Risks:** double counting ticks inflates the timeout math used by IPC waits.
- **Classification:** `PARTIAL`.
- **Next:** one tick source per CPU, and a timer queue whose API is
  `sleepUntil(tick)`.

### C.7 Atomics and memory ordering

- **Files:** scattered (`@atomicLoad`, `@cmpxchgStrong`, `swap` in KVDI).
- **Works:** used correctly in `spinlock.zig` and the KVDI queue.
- **Missing:** a single wrapper documenting the ordering per primitive, and any
  use in scheduler/IPC/capability.
- **Classification:** `STUB` (no shared contract).

## 5. D. Kernel services

### D.1 Syscall ABI and dispatch

- **Files:** `shared/syscall_abi.zig` (393), `kernel/arch/x86_64/syscall.zig`
  (1 302), `syscall.s`, `sdk/src/*`, `docs/specs/syscall-abi.md`.
- **Works:** `syscall`/`iretq` door with MSR programming, 22 calls, per-call
  pointer validation through `paging.isUserRange`, error codes, SDK wrappers,
  conformance tests between contract, kernel and SDK.
- **Missing:** argument fuzzing; a `copy_from_user`/`copy_to_user` primitive with
  TOCTOU guarantees (see bug); a stable ABI policy beyond revision numbering;
  `syscall` exit path tests; performance baselines.
- **Bugs:** validation and copy are separate steps. Today the process cannot run
  concurrently with itself, so the window is not exploitable; with threads it
  becomes a classic TOCTOU. The contract must state the rule before threads
  exist, not after.
- **Risks:** the door has never executed in a VM.
- **Tests:** 7 `abi-conformance` + 8 sdk. **Evidence:** host.
- **Classification:** `PARTIAL`.
- **Next:** a `user_access` module that pins the mapping for the duration of the
  copy, plus a fuzz corpus for the dispatcher.

### D.2 IPC channels

- **Files:** `kernel/ipc/channel.zig` (542).
- **Works:** two queues per channel, 16 messages of 16 bytes, waiters,
  timeouts with expiry, latency counters, 4 tests.
- **Missing:** payload transfer (no page sharing, no `sendmsg` with a buffer), no
  capability transfer in a message, no service discovery, no channel creation
  syscall (channels are created by the kernel at boot), no back-pressure signal,
  no cancellation.
- **Bugs:** the message is only `{kind, value}`; everything else is passed by the
  separate `copy_to` syscall, which is a second round trip and a second
  permission check.
- **Risks:** a real service protocol cannot be built on 16 bytes plus a copy.
- **Classification:** `PARTIAL`.
- **Next:** message header + optional one-page shared buffer + capability
  attachment, then a `channel_create`/`channel_connect` pair.

### D.3 Shared memory

- **Files:** none.
- **Classification:** `NOT_STARTED`.
- **Next:** a `SharedMemory` object with size/owner/permissions and a mapping
  syscall; required by IPC, graphics and any future driver host.

### D.4 Capabilities and handles

- **Files:** `kernel/security/capability.zig` (632), 17 tests.
- **Works:** typed kinds (channel, process, display, input), rights bitmask with
  per-kind allowed rights, grant/transfer/revoke with delegation rules, lookup by
  kind and subject, table and per-process set.
- **Missing:** object destruction (`create` without `destroy`), handle
  generations, per-process handle namespace (the handle is a global table index),
  revocation of live references, audit trail, quotas.
- **Bugs:** the 16-entry table is a lifetime resource; `give` refuses beyond
  `max_held = 8`; `revoke` removes from one process only.
- **Risks:** the global table index leaks information between processes (a
  process can name any handle and learn whether it exists through the error
  path), and the table cannot be reused.
- **Classification:** `PARTIAL`.
- **Next:** a slab-allocated capability table with generations, a per-process
  handle table as the only visible namespace, and a `destroy` that is called by
  process teardown.

### D.5 Process isolation and enforcement

- **Files:** `capability.zig`, `syscall.zig` (per-call `holds` checks),
  `paging.isUserRange`.
- **Works:** user pointers validated, capability held checked per call, address
  spaces separated by CR3.
- **Missing:** resource limits, quotas per process, enforcement tests with a
  hostile process, SMEP/SMAP.
- **Classification:** `PARTIAL`.

### D.6 ELF/KEX loader

- **Files:** `kernel/elf_loader.zig` (707), `elf_materializer.zig` (242),
  `kernel/native_image.zig` (318), `shared/elf64.zig` (811), `formats/kex.zig`.
- **Works:** header/segment/relocation parsing with validation, window
  placement, materialisation into mapped pages, KEX container with manifest and
  CRC, 10 + 7 + 11 host tests.
- **Missing:** dynamic linking, TLS, `PT_GNU_RELRO` enforcement, interpreter
  (`PT_INTERP`), symbol resolution, a fuzz corpus with malformed images,
  `elf_compat.zig` (a Linux-ABI header validator) is dead code with no caller.
- **Bugs:** the materialiser frees pages on its failure path but a successful
  load leaves the mapping owned by the address space that is never destroyed.
- **Classification:** `IMPLEMENTED` for the static single-window case,
  `VALIDATED (host)`.
- **Next:** fuzz corpus, then the region-based mapping from the memory document.

### D.7 User-space initialisation

- **Files:** `main.zig` `installUserTask`/`installNativeProcess`/... ,
  `user/start.s`.
- **Works:** three embedded programs placed in windows with a fixed stack.
- **Missing:** an init process, an environment, arguments, an entry contract
  beyond "register RDI holds the window base", a `wait`/`exec` model.
- **Classification:** `STUB`.

### D.8 Kernel diagnostics

- **Files:** `shared/arch/x86_64/serial.zig`, `main.zig` reports, `kernel/ai/*`
  (a pure inference module, tested, not used by the kernel path).
- **Works:** serial console with markers; counters in scheduler, IPC, block,
  graphics; a boot benchmark.
- **Missing:** a log level/ring buffer, timestamps, structured records, a crash
  record, tracepoints.
- **Classification:** `PARTIAL`.

## 6. E. Hardware and drivers

### E.1 PCI/PCIe enumeration

- **Files:** `kernel/arch/x86_64/pci.zig` (1 803), 36 tests.
- **Works:** config space through ports `0xCF8/0xCFC` with an irq-safe lock, BAR
  decoding with 64-bit support, capability walking, MSI/MSI-X capability
  *detection*, 36 host tests.
- **Missing:** ECAM/MMCONFIG (no MCFG use), PCIe extended config space beyond
  256 bytes, bus mastering enable/disable policy, MSI/MSI-X *programming*, AER,
  hotplug, interrupt routing through `_PRT`.
- **Bugs:** none proven. **Risks:** port I/O only means no access to extended
  configuration space, which several devices require.
- **Classification:** `IMPLEMENTED` for enumeration, `VALIDATED (host)`.
- **Next:** MCFG/ECAM table use, then MSI programming (needed by every modern
  device driver).

### E.2 Device model, registration and lifecycle

- **Files:** none beyond KVDI's own state machine.
- **Works:** nothing generic: there is no device object, no driver registry, no
  probe ordering, no resource ownership record.
- **Missing:** everything listed in
  [`../architecture/device-driver-model.md`](../architecture/device-driver-model.md).
- **Classification:** `NOT_STARTED`.
- **Next:** `device` + `driver` + `resource` objects and a probe queue; KVDI is
  the first client and the reference implementation.

### E.3 Interrupt routing for drivers

- **Files:** `interrupt.zig` (hard-coded vector dispatch).
- **Works:** PIT and PS/2 only.
- **Missing:** a registration API, IRQ → handler mapping, shared IRQ lists,
  spurious accounting, MSI vectors, per-device interrupt counters.
- **Classification:** `STUB`.

### E.4 VirtIO transport (KVDI)

- **Files:** `kernel/drivers/kvdi/*` (14 files, ~8 500 LOC), 173 tests.
- **Works:** modern (MMIO + PCI) transport, feature negotiation to
  `FEATURES_OK`, split virtqueue, device status machine, containment/quarantine
  on timeout, fault injection harness, capability collection, 173 host tests.
- **Missing:** interrupt-driven completion (the block driver polls), multi-queue,
  packed virtqueue, reset/recovery through the reset line, a second device class
  beyond block.
- **Bugs:** none proven; the polling path has a bounded retry count and
  quarantines on timeout, which is honest.
- **Classification:** `IMPLEMENTED` (transport), `INTEGRATED` (block), `PARTIAL`
  (completion model).
- **Next:** MSI-X + interrupt completion, then multi-queue.

### E.5 VirtIO block

- **Files:** `kernel/drivers/kvdi/block.zig` (663), 13 tests.
- **Works:** synchronous read/write/flush over a split queue, bounded polling,
  quarantine on fault, boot-time persistence probe.
- **Missing:** asynchronous submission, queue depth > 1 usage, timeouts expressed
  in real time (the retry count is a proxy), error classification per request,
  multiple devices.
- **Classification:** `IMPLEMENTED` (single device, synchronous).

### E.6 VirtIO network

- **Files:** `kernel/arch/x86_64/virtio_net.zig` (237), 9 tests of helpers.
- **Works:** nothing functional. `net_transmit()` is an **empty body that returns
  success**; `init()` reads one config word and returns.
- **Missing:** the device, the queues, the frames, the stack.
- **Bugs:** the success-returning stub is a contract violation.
- **Classification:** `STUB`. **Next:** delete the success path, or replace the
  file with `error.NotImplemented` and move the vendor/device ids into KVDI.

### E.7 Legacy VirtIO duplicates

- **Files:** `kernel/arch/x86_64/virtio.zig` (852), `virtio_blk.zig` (stub).
- **Works:** the duplicate queue helpers; `virtio_blk.zig` returns
  `error.NotImplemented` by design and is referenced only by the test root.
- **Missing:** deletion (ADR-0002 step 3, ADR-0003) — still pending, so the tree
  carries two VirtIO implementations and 15 tests that cover dead code.
- **Classification:** `STUB` (both), plus a **duplication defect**.
- **Next:** execute ADR-0002 step 3 and ADR-0003, moving the 15 tests that still
  cover live behaviour into KVDI first.

### E.8 Input devices

- **Files:** `kernel/input/{ps2,keyboard}.zig`, `shared/input.zig`,
  `kernel/graphics/{pointer_input,keyboard_motion,event_queue}.zig`.
- **Works:** PS/2 keyboard decode with modifiers and scancode sets, two event
  queues (diagnostic and user), pointer motion from the aux port or the keyboard.
- **Missing:** mouse as a first-class device with buttons and wheel, USB HID,
  hotplug, keymaps beyond a US layout, an input service, evdev-like abstraction.
- **Bugs:** PS/2 has no timeout/retry handling for the controller's output
  buffer, and the IRQ handler assumes the byte belongs to the keyboard.
- **Classification:** `PARTIAL`.

### E.9 Framebuffer and display (kernel side)

- **Files:** `kernel/graphics/*` (13 files, 2,100 LOC).
- **Works:** linear framebuffer bridge, software rasteriser, damage tracking,
  compositor and window manager in kernel, boot scene.
- **Missing:** mode setting, EDID, hotplug, GPU; and the whole stack is in ring 0
  against the target architecture.
- **Classification:** `PARTIAL`, and structurally misplaced (ADR-0006).
- Out of scope for this initiative except as debt to be moved later.

### E.10 Serial

- **Files:** `shared/arch/x86_64/serial.zig` (224).
- **Works:** COM1 initialisation, polling transmit, formatted printing.
- **Missing:** receive, interrupt-driven transmit, flow control, a device object.
- **Classification:** `IMPLEMENTED` for output.

### E.11 HPET / time sources

- **Files:** none.
- **Classification:** `NOT_STARTED`. The PIT and the LAPIC timer are the only
  clocks; there is no high-resolution source and no monotonic-vs-wall split.

### E.12 ACPI platform services and power

- **Files:** `acpi.zig` (tables only).
- **Works:** table discovery.
- **Missing:** `_S5` (power off), `RESET_REG` (reboot), sleep states, SCI
  handling, thermal, battery, CPU idle (C-states). **There is no shutdown and no
  reboot path in the kernel.**
- **Classification:** `NOT_STARTED` (as a service).

### E.13 IOMMU

- **Files:** none. `kvdi/features.zig` mentions `VIRTIO_F_IOMMU_PLATFORM` only as
  a negotiated feature name.
- **Classification:** `NOT_STARTED`.

## 7. F. Storage and filesystems

### F.1 Block layer

- **Files:** `kernel/storage/block.zig` (247), `phys_blk.zig`, `ramdisk.zig`.
- **Works:** a `Device` vtable with capacity/read/write/flush, one default device
  installed at boot, bounds checks, 4 tests.
- **Missing:** a queue model (no request queue, no scheduler, no merging), no
  multiple devices, no partition table consumption, no error/retry policy, no
  statistics beyond what the driver keeps.
- **Bugs:** `installDefault` overwrites the previous default silently.
- **Classification:** `PARTIAL`.

### F.2 GPT and partitions

- **Files:** none.
- **Classification:** `NOT_STARTED`. The image is a raw FAT with a KNV region;
  the kernel never parses a partition table.

### F.3 VFS

- **Files:** `kernel/fs/fs.zig` (1 584), `kfsx.zig` (503), 47 + 20 tests.
- **Works:** mount namespace with longest-prefix routing, open/close/read/write/
  truncate/seek/rename/unlink/stat, per-process descriptor table with
  generations, `closeAll`, 47 host tests.
- **Missing:** a filesystem *interface*: every operation reaches directly into
  `ramfs.State`. There is no inode/dentry/superblock vtable, no permission check
  on open, no timestamps, no page cache, no `mmap` of files, no symlinks, no
  hard links, no quotas, no locking.
- **Bugs:** `max_processes = 8` and `max_open_files = 16` are hard limits;
  `fs.zig` indexes per-process tables by a `u64` process id that the scheduler
  assigns from a 32-bit counter with no bounds mapping.
- **Risks:** the VFS cannot accept a second filesystem without a rewrite of every
  function; permissions are stored but not enforced.
- **Classification:** `PARTIAL` (single backend), `IMPLEMENTED` for RamFS use.
- **Next:** define `Filesystem`/`Inode`/`File` interfaces, port RamFS to them,
  then enforce permissions from the capability model.

### F.4 RamFS

- **Files:** `kernel/fs/ramfs.zig` (2 227), 60 tests.
- **Works:** inodes, blocks, directories, rename, truncate, auditing, storage
  statistics, 60 host tests — the best-tested module in the tree.
- **Missing:** permissions enforcement, locking, large files beyond the block
  budget, sparse files.
- **Classification:** `IMPLEMENTED`, `VALIDATED (host)`.
- **Next:** locking (a single RamFS lock is acceptable at first) and permission
  hook points.

### F.5 KNV volume format

- **Files:** `kernel/fs/knv.zig` (341), `knv_volume.zig` (341), 20 + tests.
- **Works:** deterministic little-endian image codec with CRC and validation;
  commit/recover over the block layer; a two-boot persistence probe.
- **Missing:** journal, dual-image atomic swap, power-loss testing, versioning
  for format evolution.
- **Classification:** `IMPLEMENTED` (codec + commit), `PARTIAL` (crash safety).
- **Next:** dual-slot commit with a checksummed header and a generation counter;
  then a fault-injection test that truncates the image at every sector.

### F.6 File handles, buffering and caching

- **Files:** `fs.zig` descriptor table.
- **Works:** fd generation revalidation (`CheckedFd`).
- **Missing:** a buffer cache, readahead, write-back, dirty tracking.
- **Classification:** `STUB`.

### F.7 Filesystem consistency and recovery

- **Files:** `ramfs.auditStorage`, `knv.recover`.
- **Works:** an in-memory audit and image recovery on boot.
- **Missing:** `fsck`-like offline validation, journal replay, a documented
  guarantee.
- **Classification:** `PARTIAL`.

## 8. G. Essential systems

### G.1 Console and terminal

- **Files:** `serial.zig`, `syscall write` to the descriptor `console`.
- **Works:** kernel serial output; a user `write` path.
- **Missing:** a terminal device, line discipline, TTY for processes, a screen
  console (the framebuffer text is not a console), keyboard input into a shell.
- **Classification:** `STUB`.

### G.2 Input subsystem (service level)

- **Files:** `shared/input.zig` (237), `graphics/event_queue.zig`.
- **Works:** a wire event format and two queues.
- **Missing:** an input service, device abstraction, hotplug, per-seat routing.
- **Classification:** `STUB` (service), `PARTIAL` (driver).

### G.3 Timekeeping

- **Files:** `timer.zig`, `apic.zig`, TSC reads in `cpu.zig`.
- **Works:** tick count at 100 Hz, TSC for cycle measurement.
- **Missing:** wall clock, monotonic clock API, calibration persistence, NTP
  hooks, a `clock_gettime` equivalent (the syscall ABI has none).
- **Classification:** `PARTIAL`.
- **Note:** there is **no syscall that returns time**. A user program cannot read
  a clock.

### G.4 Kernel logging

- **Files:** `serial.printLine`.
- **Works:** line output with a fixed prefix per component.
- **Missing:** levels, timestamps, a ring buffer, filtering, structured output.
- **Classification:** `STUB`.

### G.5 System information and configuration

- **Files:** `kynox_config` (build option), `reportProcessor`, `reportMemory`.
- **Works:** build-time configuration for IOAPIC delivery; runtime reports to
  serial.
- **Missing:** a queryable system information interface for user space.
- **Classification:** `STUB`.

### G.6 Power management, shutdown, reboot

- **Files:** none.
- **Works:** `port.haltForever()`.
- **Missing:** ACPI power off, reset, sleep, idle states, CPU frequency.
- **Classification:** `NOT_STARTED`. **This is a user-visible gap**: the machine
  cannot be turned off cleanly.

### G.7 Resource accounting

- **Files:** scattered counters.
- **Works:** per-subsystem counters for diagnostics.
- **Missing:** per-process CPU time, memory, IO and GPU accounting; limits.
- **Classification:** `NOT_STARTED`.

## 9. Test coverage map

| Area | Host tests | In a test root | Comment |
|---|---:|---|---|
| RamFS | 60 | yes | strongest module |
| fs (VFS) | 47 | yes | single backend |
| pci | 36 | yes | enumeration only |
| KVDI (all files) | 173 | yes | transport + virtqueue + containment |
| ACPI | 22 | yes | tables only |
| kfsx | 20 | yes | mount namespace |
| capability | 17 | yes | no lifecycle |
| virtio (legacy) | 15 | yes | dead code, planned for deletion |
| elf64 (shared) | 11 | yes | format only |
| elf_loader | 10 | yes | static only |
| paging | 9 | yes | pure helpers |
| physical | 8 | yes | <4 GiB |
| smp | 8 | yes | table arithmetic |
| ioapic | 8 | yes | no delivery |
| heap | 6 | yes | single-threaded |
| ipc channel | 4 | yes | 16-byte messages |
| block | 4 | yes | vtable |
| spinlock | 3 | yes | two lock types |
| **scheduler** | **0** | **no** | not importable on the host |
| **timer** | **0** | no | hardware-bound |
| **interrupt/exceptions** | **0** | no | hardware-bound |
| **syscall dispatch** | **0** | no | only the ABI contract is tested |
| **ps2** | **0** | no | hardware-bound |
| **paging (address space)** | 0 | yes | creation/teardown untested |

Total: 709 host tests. The untested set is exactly the set of mechanisms that
SMP, scheduling and fault handling depend on.

## 10. Architecture defects (ranked)

| # | Defect | Evidence | Consequence | Action |
|---|---|---|---|---|
| 1 | Scheduler has no synchronisation and pretends to be per-CPU | `scheduler.zig` arrays | SMP cannot be enabled without corruption | K3 |
| 2 | Single global TSS with one `rsp0` | `segment.zig:194` | ring 3 on an AP uses the wrong stack | K0 |
| 3 | 24 KiB user window, 8 static spaces, no destruction | `usermode.zig`, `paging.zig` | no general process model | K1 |
| 4 | Unmap never frees frames | `paging.zig` | monotonic memory leak | K1 |
| 5 | Capability table cannot be freed; 16 entries | `capability.zig` | hard lifetime limit | K5 |
| 6 | No interrupt registration API | `interrupt.zig` | no second driver can exist | K2 |
| 7 | Two module cycles (`apic`↔`timer`) | imports | untestable modules | K2 |
| 8 | FPU/SSE state not saved on switch | `task.s` | silent corruption in compute tasks | K3 |
| 9 | `main.zig` 4 974 lines mixing bring-up, demo and self-test | file | every change touches everything | K0 |
| 10 | VFS hardwired to RamFS | `fs.zig` | no second filesystem possible | K10 |
| 11 | `net_transmit()` returns success without transmitting | `virtio_net.zig` | violates the stub policy | K7 |
| 12 | Legacy VirtIO duplicate kept alive by tests | `virtio.zig`, `virtio_blk.zig` | two implementations, dead tests | K7 |
| 13 | TOCTOU between `isUserRange` and the copy | `syscall.zig` | becomes exploitable when threads exist | K6 |
| 14 | `isUserRange` does not pin; no `copy_*_user` | `syscall.zig` | same as 13 | K6 |
| 15 | Dead files and a dead constant | `elf_compat.zig`, `dir_entry.zig`, `test_ramfs_runner.zig`, `paging.window_pages` | noise, false surface | K0 |

## 11. Documentation versus implementation

The status inventory is not wrong, but it is imprecise in four places. These are
**review recommendations**; no percentage was changed by this audit.

| Subsystem | Recorded | What the code can do | Recommendation |
|---|---:|---|---|
| `user_processes_ring3` | 60% | 24 KiB window, 8 spaces, no teardown | review downward until K1 |
| `scheduler` | 55% | single-CPU, unlocked, 0 tests | hold at 55% only if K3 is the next task |
| `virtual_memory` | 45% | fixed pools, no regions, no teardown | consistent with the code; keep |
| `ipc` | 60% | 16-byte messages, no payload | review downward until K6 |
| `native_syscall_abi` | 55% | 22 calls, no time, no threaded safety | consistent; keep |

Everything else in the inventory matches the code as read.

## 12. What this audit did not do

- It did not run the kernel. No QEMU/OVMF is available in this environment
  (`docs/validation/qemu.md`), so every runtime statement is a code reading.
- It did not attempt to fix the defects. The one exception permitted by the task
  would be a critical, small, documentation-level correction; none was needed,
  because the documents were already careful about runtime claims.
- It did not evaluate graphics, compatibility or desktop scope beyond noting the
  structural debt they impose on the kernel.
