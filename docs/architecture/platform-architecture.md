# Kynox — Platform Architecture

- Status: **planning document**; it describes the target architecture and maps it
  to what exists today. It is not a statement that the target is implemented.
- Date: 2026-10-31. Identity: **Kynox One 0.1.0-alpha.1** (see
  [`VERSIONING.md`](../VERSIONING.md)).
- Related: [`market-landscape.md`](../strategy/market-landscape.md),
  [`graphics-platform.md`](graphics-platform.md),
  [`application-ecosystem.md`](application-ecosystem.md),
  [`security-architecture.md`](security-architecture.md),
  [`PRODUCT_ROADMAP.md`](../roadmap/PRODUCT_ROADMAP.md).
- Evidence for the "state today" fields: [`PROJECT_STATUS.md`](../PROJECT_STATUS.md)
  and the source tree; no runtime (QEMU/hardware) evidence exists for this
  snapshot.

## 1. Principles

1. **The kernel proves mechanism; user space decides policy.** Privileged code
   owns memory, scheduling, isolation, device access and the timing of
   presentation. Layout, theming, routing and application policy are services.
2. **Small contracts, explicit ownership.** Every cross-boundary object has an
   owner, a lifetime, a capability that names it and an error model.
3. **No ambient authority.** A process reaches memory, devices, the display, the
   network or another process through a capability it was given, not through a
   global namespace it happens to see.
4. **Failure is contained.** A crashed service is restarted, a hung GPU context is
   reset, a corrupt file is rejected. The system does not treat "it normally
   works" as a recovery strategy.
5. **Validate at every boundary**: user pointers, IPC payloads, command buffers,
   firmware tables, filesystem metadata, network packets.
6. **Measurable claims only.** A performance or security property is published
   with the scenario, the method and the evidence that it holds.
7. **Progressive isolation.** Code moves from Ring 0 to Ring 3 when the
   mechanisms that make the move safe (IOMMU, interrupt delegation, IPC, resource
   handles) exist — not before, and not by convenience in the opposite direction.

## 2. Layer map

Target layering. The right-hand column is the state of the tree today.

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Applications: native (KEX), services, shell, tools                   │ 2 sample apps
├──────────────────────────────────────────────────────────────────────┤
│ SDK / ABI: syscalls, IPC, capabilities, shared memory, KEX, KGA      │ partial SDK
├──────────────────────────────────────────────────────────────────────┤
│ User-space services: init, device manager, compositor, display,      │ none as services
│ audio, network, VFS, package manager, portal broker, session         │ (all in kernel)
├──────────────────────────────────────────────────────────────────────┤
│ Kernel: scheduler, VM, IPC core, capabilities, object table,          │ implemented,
│ syscall gate, device core, graphics core, storage, VFS routing       │ partial
├──────────────────────────────────────────────────────────────────────┤
│ Platform: ACPI, PCI, APIC/IOAPIC, timers, DMA/IOMMU, KVDI            │ partial
├──────────────────────────────────────────────────────────────────────┤
│ Hardware: x86_64, UEFI, MMU, GPUs, storage, network, audio           │ x86_64 + UEFI
└──────────────────────────────────────────────────────────────────────┘
```

**Current reality.** Kynox today runs a freestanding x86_64 kernel loaded by its
own UEFI application; it has processes, a scheduler, paging, syscalls,
capabilities, IPC channels, a VirtIO block path, a filesystem stack, an ELF/KEX
loader, an in-kernel software rasteriser/compositor/window manager and PS/2
input. It has **no** GPU driver, display-controller abstraction, audio, network
stack, user-space services, package manager or installer. The rest of this
document is the target; §10 maps it explicitly.

## 3. Kernel mode versus user mode

The placement below is a decision, not a preference: each entry states why the
code must be privileged or why it must not be.

| Component | Mode | Justification |
|---|---|---|
| CPU setup, GDT/IDT/TSS, exception entry | Kernel | Requires privileged instructions and per-CPU state |
| Interrupt controllers (LAPIC/IOAPIC), timer | Kernel | Hardware registers, EOI, vector allocation |
| Physical memory manager, page tables | Kernel | Controls isolation; MMU programming |
| Scheduler, context switch, IPI | Kernel | Preemption and cross-CPU coordination |
| Syscall gate, user-pointer validation | Kernel | Privilege boundary |
| Capability and handle tables | Kernel | Authority must not be forgeable |
| IPC transport (queues, wake-ups) | Kernel | Needs scheduling and memory sharing |
| Device enumeration core (ACPI/PCI) | Kernel | Firmware and bus access |
| IOMMU / DMA protection | Kernel | Protects memory from devices |
| Display controller (KDS core) | Kernel | Owns scanout, modes, page flips, fences |
| GPU memory objects, GPU page tables, submission rings | Kernel | Isolation between processes and devices |
| GPU command validation (structural) | Kernel | Last line of defence before the ring |
| Vendor GPU driver (registers, firmware, shaders) | User space* | Large untrusted surface; *kernel if no IOMMU |
| Storage block transport (NVMe/AHCI/virtio) | Kernel | DMA and interrupts |
| Filesystem implementation | User space (target) | Complex parsers; recoverable failure |
| VFS namespace and mount policy | User space (target) | Policy, not mechanism |
| Compositor, window manager, input policy | User space | Layout policy; must be restartable |
| Display settings service | User space | Policy over KDS capabilities |
| Device manager (policy, drivers loading) | User space | Coordination, not mechanism |
| Audio graph server | User space | Latency classes, routing, per-app streams |
| Network stack | User space (target) | Large parser surface; restartable |
| Package manager, updater | User space | Policy, signatures, rollback |
| Portal/permission broker | User space | Mediation with user consent |
| Session manager, shell, desktop | User space | User experience |
| Debugger, profiler, validators | User space | Tooling must not run privileged |

\* The user-space driver tier requires an IOMMU. Without one, the vendor driver
runs in the kernel behind the same narrow interface, and that limitation is
published per device.

## 4. Subsystem contracts

The format is compact: **R**esponsibility, **I**nterfaces, **D**ependencies,
**P**rivilege, **C**oncurrency, **M**emory, **F**ailure, **S**ecurity,
**Pf**erformance target, **T**oday, **N**ext.

### 4.1 Boot and firmware handoff

- **R** Load the kernel, describe the machine, transfer control exactly once.
- **I** `KNB → KNK` handoff structure (magic, version, header size, flags, memory
  map, framebuffer, kernel range, ACPI RSDP), documented in
  [`boot-handoff-spec.md`](../specs/boot-handoff-spec.md).
- **D** UEFI services, ELF loader in the bootloader, GOP framebuffer.
- **P** Firmware then Ring 0.
- **C** Single-threaded until the kernel enables interrupts.
- **M** Identity-mapped allocation owned by the loader; everything freed after
  handoff.
- **F** Any invalid field halts with a diagnostic; no partial handoff.
- **S** The kernel treats every handoff field as untrusted input; sizes and
  ranges are validated.
- **Pf** Boot to kernel entry measured in seconds, not asserted as a guarantee.
- **T** Implemented (UEFI application, versioned handoff, framebuffer and RSDP
  capture). No firmware matrix; handoff logic has no host tests.
- **N** Handoff v2 with device-tree-like extras (NVDIMM, reserved regions),
  bootloader self-tests, measured-boot integration.

### 4.2 CPU, exceptions and interrupts

- **R** Own the processor: descriptors, exception entry, interrupt routing,
  vector allocation, EOI.
- **I** IDT registration, interrupt service registration, per-CPU data.
- **D** ACPI/MADT, APIC, IOAPIC.
- **P** Ring 0.
- **C** Interrupts disabled in critical sections; per-CPU structures; spinlocks
  with documented order.
- **M** Static per-CPU areas; no allocation in ISR.
- **F** Faults produce a panic with register state; a user fault kills the
  process, not the kernel.
- **S** IST stacks for critical exceptions; NX before use; no user data in
  messages.
- **Pf** Sub-microsecond interrupt entry/exit (to be measured).
- **T** GDT/TSS/IDT, exception stubs, xAPIC, IOAPIC routing (masked), PIT and
  LAPIC timer.
- **N** Delivery through the IOAPIC proven by a recorded boot; MSI/MSI-X;
  per-CPU vector allocation; IOMMU interrupt remapping.

### 4.3 Time

- **R** Monotonic time, deadlines, timers, scheduling ticks.
- **I** `now()`, `sleep`, timer registration, per-CPU timer.
- **D** TSC (calibrated), LAPIC timer, PIT fallback.
- **P** Ring 0.
- **C** Per-CPU timers; deadline heap protected by a short lock.
- **M** Static timer objects.
- **F** Timer failure falls back to PIT; drift is bounded and reported.
- **S** Time is not a security boundary; sleep is not a privilege.
- **Pf** Clock read without a lock on the fast path; scheduling tick under 1 µs.
- **T** PIT + LAPIC timer at 100 Hz; TSC used for benchmarks.
- **N** High-resolution timers, clock sources selectable at boot, per-CPU
  deadline queues.

### 4.4 Physical and virtual memory

- **R** Own frames, address spaces, mappings, protection and DMA visibility.
- **I** Frame alloc/free, map/unmap/protect, address-space create/destroy,
  shared-memory objects.
- **D** Boot memory map, IOMMU (target), page-table format.
- **P** Ring 0.
- **C** Per-CPU frame caches (target); global locks only for fallback.
- **M** Frames with ownership and refcount; kernel heap with typed pools.
- **F** Out-of-memory returns errors; no silent overcommit in the kernel;
  guard pages catch stack overflow.
- **S** W^X, NX, SMEP/SMAP (target), KASLR (target), user/kernel separation,
  page-zero unmapped.
- **Pf** Page fault path bounded; TLB shootdown cost measured.
- **T** Bitmap PMM, heap, four-level paging, per-process user windows, W^X
  negative tests.
- **N** Region abstraction, demand paging, COW, high-half kernel, TLB shootdown,
  IOMMU domains.

### 4.5 Processes, threads and scheduler

- **R** Create, schedule, preempt, migrate, destroy execution contexts.
- **I** Task creation, states, priority/latency class, affinity, wait objects.
- **D** Memory (stacks, address spaces), timers, IPI.
- **P** Ring 0.
- **C** Per-CPU run queues (target); current single global queue.
- **M** Kernel stacks with guard pages; per-task context.
- **F** A crashing task is reaped; a hung task is killable; the system does not
  block on a dead task.
- **S** No task runs with another's address space; capabilities bound authority.
- **Pf** Wake-up latency and context-switch cost measured; no false sharing in
  per-CPU data.
- **T** Timer-driven preemption, context switching, statistics, two user apps.
- **N** Latency classes (interactive/gaming/background), per-CPU queues, work
  stealing only with evidence, real-time policy with admission control.

### 4.6 Syscall gate and ABI

- **R** Controlled entry into the kernel with a stable, versioned contract.
- **I** `SYSCALL/SYSRET`, MSRs, 22 calls (12 reserved), documented in
  [`syscall-abi.md`](../specs/syscall-abi.md) and `shared/syscall_abi.zig`.
- **D** Scheduler, memory, IPC, capabilities.
- **P** Ring 0 entry from Ring 3.
- **C** Per-thread kernel stack; interrupts masked during entry where required.
- **M** No allocation on the entry path; copy-in/copy-out with validation.
- **F** Invalid arguments return errors; kernel never dereferences user pointers
  directly.
- **S** Every pointer, length and handle validated; no kernel pointers in the ABI.
- **Pf** Round-trip target defined by benchmark, not by adjective.
- **T** Implemented, one ABI revision, conformance tests kernel↔SDK.
- **N** ABI stability policy, versioned additions, fuzzing, faster path
  (dedicated trampolines, PCID).

### 4.7 IPC and shared memory

- **R** Move messages and buffers between isolated processes with bounded
  resources.
- **I** Channels (send/receive/receive-blocking/receive-timeout), message kinds,
  shared-memory handles (target).
- **D** Scheduler blocking, capabilities, memory objects.
- **P** Ring 0 transport; user-space services on top.
- **C** Per-channel queues with wake-ups; no locks held across wake-up.
- **M** Bounded queues; no allocation in the send fast path (target: rings).
- **F** Receiver death closes the channel; sends fail with a defined error.
- **S** Validation of every message; channel capability required; no ambient
  discovery.
- **Pf** Small-message latency and large-buffer throughput measured separately.
- **T** Channels with blocking and timeout receive; no shared memory.
- **N** Shared-memory objects with ownership and revocation, capability transfer
  in messages, backpressure, cancellation.

### 4.8 Capabilities and handles

- **R** Represent authority as unforgeable, revocable tokens.
- **I** Kinds (channel, process, display, input — extendable), rights
  (send/receive/delegate/write/read), grant/revoke.
- **D** Object table, process lifetime.
- **P** Ring 0.
- **C** Per-process tables with generation counters; RCU or locking on lookup.
- **M** Fixed-size slots, no allocation per grant (target).
- **F** Revoked handles fail closed; process death revokes all.
- **S** This is the core of the security model: no global namespace can grant
  authority.
- **Pf** Lookup on the syscall path is O(1).
- **T** Typed kinds, per-holder rights, delegation and revocation, enforcement in
  syscalls.
- **N** Object coverage for devices, GPU contexts, shared memory and files;
  audit trail of grants.

### 4.9 Device model and driver framework

- **R** Discover hardware, bind drivers, hand out device access by capability.
- **I** Device descriptors (PCI address, BARs, MSI-X, IOMMU group), driver
  manifest, probe/attach/start/stop/reset, interrupt delivery to user space
  (target).
- **D** ACPI, PCI, IOMMU, DMA API, IPC.
- **P** Enumeration core in Ring 0; policy and vendor drivers in user space when
  IOMMU exists.
- **C** Driver lifecycle serialised per device; interrupts routed to the owning
  driver context.
- **M** MMIO windows mapped only into the owning driver; DMA buffers pinned and
  owned.
- **F** Driver crash detaches and resets the device; the system survives.
- **S** No ambient device access; DMA restricted by IOMMU; firmware treated as
  untrusted.
- **Pf** Probe failure bounded by timeout; no unbounded polling.
- **T** ACPI/PCI enumeration, KVDI for VirtIO block, bus-master revocation.
- **N** User-space driver host, interrupt delegation, IOMMU groups, driver
  packages with signatures.

### 4.10 Storage and filesystems

- **R** Durable, verifiable storage with a namespace.
- **I** Block device operations (read/write/flush), filesystem VFS operations,
  mount namespace, file handles.
- **D** Device model, DMA, page cache (target).
- **P** Transport in Ring 0; filesystem and VFS in user space (target).
- **C** Per-device queues; concurrent filesystem operations with documented
  locking.
- **M** Page cache with writeback; no double buffering between block layer and
  filesystem.
- **F** Corrupt metadata is rejected; journal/replay recovers; read-only
  fallback.
- **S** Metadata validated; symlinks and paths bounded; permissions checked at
  the VFS, not the backend.
- **Pf** Sequential and random throughput measured per device class.
- **T** VirtIO block (synchronous), RamFS, KFSX routing, KNV volume codec, KPK
  codec.
- **N** Asynchronous I/O, journaled on-disk filesystem, VFS server, snapshot and
  rollback.

### 4.11 Network

- **R** Packet transport and a protocol stack usable by applications.
- **I** Socket-like API in the SDK; interface configuration service.
- **D** Device model, DMA, timers, IPC.
- **P** Driver transport in Ring 0; stack in user space (target).
- **C** Per-queue rings; stack workers with bounded queues.
- **M** Zero-copy receive where the NIC supports it; otherwise one copy, measured.
- **F** Link loss, MTU changes and timeouts handled without leaking buffers.
- **S** Every packet is untrusted input; no privileged parsing.
- **Pf** Throughput per core and latency percentile targets per stage.
- **T** Only VirtIO-net identifiers and scaffolding; **no stack**.
- **N** virtio-net driver, Ethernet/ARP/IPv4/IPv6/UDP/TCP, DNS, sockets, firewall
  policy service.

### 4.12 Display system (KDS core and display service)

- **R** Own connectors, modes, scanout, page flips and fences.
- **I** Kernel: mode-set/commit, framebuffer objects, flip with fence, hotplug
  events. Service: settings, colour, multi-monitor policy.
- **D** GPU/display driver, memory objects, timers, IPC.
- **P** Core in Ring 0; policy in user space.
- **C** Atomic commit ordering; flips serialised per CRTC; fences signal from
  interrupt context.
- **M** Scanout buffers pinned until the flip completes; no tearing by
  construction.
- **F** Link training failure falls back to a safe mode; device loss triggers
  recovery to the firmware framebuffer.
- **S** Applications never touch scanout memory; capture requires a capability.
- **Pf** Page flip latency and missed-vblank rate measured.
- **T** Firmware framebuffer bridge only; no mode setting, no EDID.
- **N** See [`graphics-platform.md`](graphics-platform.md) §4.

### 4.13 Graphics core and GPU drivers

- **R** Memory objects, GPU address spaces, queues, submission, fences, reset.
- **I** Device creation, allocation, command buffer submission, fence wait,
  pipeline/shader objects (see graphics doc).
- **D** Device model, IOMMU, memory, interrupts.
- **P** Core in Ring 0; vendor driver in user space behind validation where IOMMU
  exists.
- **C** Per-engine rings; GPU scheduler with time slices; fences are the only
  cross-queue ordering primitive.
- **M** Explicit heaps; residency managed by the application with driver help.
- **F** Hang detection with per-context reset; device reset as last resort;
  progress guarantee documented.
- **S** Command buffers validated structurally; GPU page tables per context; no
  cross-process resource access.
- **Pf** Submission overhead, frame time variance and reset time measured.
- **T** None (software rasteriser only).
- **N** virtio-gpu first, then Intel/AMD; NVIDIA later.

### 4.14 Audio

- **R** Route streams between applications and devices with bounded latency.
- **I** Stream creation with format and latency class, volume/routing policy,
  capture permission.
- **D** Device model, timers, IPC, shared memory.
- **P** Driver transport in Ring 0; graph in user space.
- **C** Real-time-safe mixing thread with pre-allocated buffers.
- **M** Ring buffers shared with clients; no allocation in the audio callback.
- **F** Underruns reported, not hidden; device loss re-routes.
- **S** Capture requires explicit permission; no ambient microphone access.
- **Pf** Round-trip latency per class (pro-audio vs media vs notification).
- **T** None.
- **N** HDA transport, graph service, PCM/mixer, latency classes.

### 4.15 User-space services and session

- **R** Init/service manager, device policy, VFS, network, audio, compositor,
  portal broker, package manager, session.
- **I** Service manifests, capability grants, restart policy, supervision tree.
- **D** Kernel IPC/capabilities, storage, display.
- **P** Ring 3.
- **C** Each service single-threaded or with its own worker pool; no shared
  mutable state across services.
- **M** Arenas per request; bounded queues.
- **F** A crashed service is restarted with backoff; dependent services are
  notified, the kernel is unaffected.
- **S** Services hold only the capabilities they need; the broker mediates user
  consent.
- **Pf** Service start latency and IPC round-trip measured.
- **T** None; policy today lives in the kernel.
- **N** init, device manager, VFS, network, audio, compositor, portal, updater.

### 4.16 Tooling, diagnostics and observability

- **R** Make the system measurable and debuggable without privileged tools.
- **I** Tracing (kernel + user events), counters, crash dumps, capture files,
  validation reports.
- **D** All subsystems.
- **P** Ring 3 tools; minimal kernel instrumentation.
- **C** Lock-free per-CPU ring buffers for tracing.
- **M** Fixed-size trace buffers, overwritten in a documented way.
- **F** Tracing never blocks the traced path; overflow is reported.
- **S** Telemetry is local by default; upload requires explicit consent.
- **Pf** Tracing overhead measured as a percentage of the traced operation.
- **T** Serial logs, counters, benchmark harness (not in the build graph).
- **N** Binary trace format, frame capture, GPU counters, crash triage tool.

## 5. Cross-cutting contracts

- **Object identity:** every kernel object is named by a 64-bit handle with a
  generation counter; handles are per-process and validated on every use.
- **Error model:** syscalls return a signed status (`0` success, negative error
  codes from `shared/syscall_abi.zig`); IPC carries a status and a small payload.
- **Versioning:** ABI revision in `shared/syscall_abi.zig`; formats carry their
  own magic/version; the system version is never stored in wire formats.
- **Memory sharing:** explicit `SharedMemory` objects with size, permission and
  owner; mapping requires a capability; revocation unmaps on next fault.
- **Time:** `CLOCK_MONOTONIC` semantics for scheduling; wall clock is a service.
- **Security:** a capability is required for every external resource; the broker
  converts user consent into capabilities; the kernel never prompts.
- **Observability:** every service exposes counters and a health state; the
  supervisor tree and the session manager consume them.

## 6. Dependency graph (target)

```text
boot ─▶ CPU/interrupts ─▶ time ─▶ scheduler ─▶ IPC ─▶ capabilities
                    │                              │
                    ├─▶ PMM ─▶ VMM ────────────────┤
                    ├─▶ ACPI/PCI ─▶ device core ───┤
                    │                     │        │
                    │                     ├─▶ IOMMU ─▶ user drivers
                    │                     ├─▶ storage ─▶ VFS service
                    │                     ├─▶ display core ─▶ compositor
                    │                     ├─▶ GPU core ─▶ KGA ─▶ renderer
                    │                     └─▶ network / audio devices
                    └─▶ observability ◀── every subsystem
```

A subsystem may only depend on subsystems to its left/top; violations are
architectural bugs, not style issues.

## 7. Concurrency model

- One scheduler run queue per CPU (target); migration only at defined points.
- Kernel locks are short and ordered; no lock is held across a wake-up, a page
  fault or a user copy.
- Interrupt handlers do the minimum and hand work to a deferred context.
- GPU and audio use their own real-time contexts with admission control.
- All shared-memory rings use acquire/release pairs with documented semantics.
- Every lock is classified (IRQ-safe, sleepable, per-CPU) in the source.

## 8. Memory and failure policy

| Class | Policy |
|---|---|
| Kernel heap | Typed pools for fixed objects; general heap for rare allocations |
| DMA | Pinned, IOMMU-mapped, owned until completion |
| GPU memory | Explicit heaps, residency by application decision, eviction on pressure |
| User memory | Lazy mapping, COW on fork, guard pages |
| Audit | Allocation failures are returned, never ignored |

Recovery ladder: retry with backoff → restart service → reset device/context →
kill process → safe mode. Every rung is observable and testable.

## 9. Performance budgets (to be measured, not asserted)

| Path | Metric | Where it is measured |
|---|---|---|
| Syscall | Round-trip, p50/p99 | `tools/benchmarks` (not in build yet) |
| IPC | 64 B message latency; 1 MiB throughput | IPC benchmark |
| Context switch | Cost and wake-up latency | Scheduler harness |
| Compositing | CPU time per frame, damage ratio | Compositor instrumentation |
| Presentation | Flip-to-vblank, missed frames | KDS counters |
| GPU submission | CPU time per submission, queue depth | KGC counters |
| Storage | Sequential/random throughput, flush latency | Block layer counters |
| Audio | Round-trip latency per class | Audio service counters |
| Boot | Time to first frame and to session | Boot tracer |

No number is published until it has a baseline, a scenario and a repeatable
method.

## 10. State today and next steps (mapping)

| Target area | Exists today | Gap to close first |
|---|---|---|
| Boot | UEFI loader, handoff v1, framebuffer/RSDP | Handoff tests, firmware matrix, measured boot |
| CPU/interrupts | GDT/TSS/IDT, xAPIC, IOAPIC (masked), timers | IOAPIC delivery proven, MSI/MSI-X, per-CPU vectors |
| Memory | PMM, heap, 4-level paging, DMA | Regions, demand paging, TLB shootdown, high-half |
| Processes | Tasks, scheduler, two user apps | Process API, limits, signals/waits, per-CPU queues |
| Syscalls/ABI | 22 calls, revision 1, conformance tests | Stability policy, fuzzing, faster entry, VM execution |
| IPC/caps | Channels, typed rights, delegation | Shared memory, capability transfer, coverage |
| Devices | ACPI/PCI, KVDI (virtio-blk) | Device manager, IOMMU, user-space drivers |
| Storage/FS | VirtIO block synchronous, RamFS, KNV, KPK | Async I/O, journaled FS, VFS service |
| Network | VirtIO-net scaffolding only | Driver, stack, service |
| Display/GPU | Framebuffer bridge, software raster | KDS, GPU core, driver model |
| Compositor/WM | In-kernel compositor/WM/damage | User-space compositor + protocol |
| Audio | None | HDA transport, graph service |
| Desktop | Boot-time scene | Shell, session, file manager, settings |
| Security | Ring 3, W^X, capabilities | SMEP/SMAP, KASLR, IOMMU, secure boot chain |
| Updates | KPK codec | Repository, signatures, atomic update |
| Tooling | Serial logs, counters | Trace format, capture, profilers |

## 11. Open questions

1. High-half kernel and KPTI: when, and at what measured cost?
2. IOMMU-less systems: which devices may run user-space drivers without one?
3. VFS in user space: how is mount policy expressed and recovered after a crash?
4. Display ownership: one compositor per session or one per seat?
5. GPU command validation: how much structure can be enforced without hurting
   submission cost?
6. Audio: single graph service or separate pro-audio server?
7. Networking: user-space stack from day one, or a trusted kernel path first?
8. Telemetry: what is local-only, what is opt-in, and how is consent recorded?

Each question that blocks a subsystem is resolved by an ADR before code.
