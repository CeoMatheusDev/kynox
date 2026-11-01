# Kynox compatibility roadmap

- Status: **planning document**. No phase below is complete. Every phase is
  `not_started`; the compatibility subsystems remain at 0% maturity.
- Date: 2026-10-31.
- Related: [`../architecture/graphics-compatibility.md`](../architecture/graphics-compatibility.md),
  [`../architecture/linux-compatibility.md`](../architecture/linux-compatibility.md),
  [`../architecture/windows-compatibility.md`](../architecture/windows-compatibility.md),
  [`PRODUCT_ROADMAP.md`](PRODUCT_ROADMAP.md) S15,
  [`../strategy/market-landscape.md`](../strategy/market-landscape.md) §3.2–3.7.

## 1. How to read this document

Each phase states: objective, scope, dependencies, components, completion
criteria, conformance tests, performance tests, risks, required evidence and the
rule for promoting maturity. The vocabulary is the project's canonical one
(`not_started`, `scaffolding`, `in_progress`, `implemented`, `integrated`,
`validated`, `blocked`) plus the evidence ladder from `PRODUCT_ROADMAP.md` §1:
**P** prototype, **F** functional, **E** emulator-validated, **H**
hardware-validated.

A compatibility phase can only reach **F** when a named corpus runs; **E** when
the same corpus runs under the QEMU suite; **H** on named hardware. Until then it
stays **P** even if it looks complete.

## 2. Critical review of the proposed order

The task proposed: runtime → processes → security → IOMMU → display → GPU model
→ KGC → KGA → KGL/KVK → KGR/KWM → KLC → KWC → D3D.

That order has **two real defects** and one missed opportunity:

| Issue | Why it matters | Correction |
|---|---|---|
| KGL/KVK placed before KWM | Vulkan swapchain and OpenGL surfaces require a compositor and a window protocol; without KWM, KVK can only render offscreen | move KWM (native compositor service) **before** KGL/KVK presentation; KVK object work may proceed in parallel but presentation is blocked |
| KGR before KWM | the compositor does not need the renderer; it needs KGA and KDS. Serialising them delays the desktop | KGR runs in parallel with KWM; neither blocks the other |
| KLC/KWC placed after the entire graphics stack | neither layer needs graphics to run console software; placing them last delays the highest-risk, longest-running work to the end | start KLC once processes, memory, files and security exist (after S3/S4); start the PE parser as host-only work immediately |

Corrected critical path:

```text
S0 runtime evidence
  └─▶ S1 interrupts/IOAPIC/APs
        └─▶ S2 memory + IOMMU
              └─▶ S3 processes/capabilities/ABI
                    ├─▶ S4 storage/VFS ──▶ C1 KLC static ──▶ C2 KLC FS/proc ──▶ C3 KLC dynamic
                    │                          └─▶ C4 PE parser (host, parallel) ──▶ C5 KWC console
                    └─▶ S5 display ──▶ S6 GPU model/KGC ──▶ S7 KGA ──┬─▶ S9 KWM ──▶ C7 KVK
                                                                    ├─▶ C6 KGX
                                                                    └─▶ C8 KGL
                                                                          └─▶ C9 window bridges
                                                                                └─▶ C10 KWC user32
                                                                                      └─▶ C11 D3D (optional)
```

Parallelism that is real (not aspirational):

- **C4 (PE parser)** is pure code with a corpus; it needs no kernel and no
  display. It can start as soon as S3 stabilises the host test harness.
- **C1 (ELF static loader)** needs S3 only; it does not need display, audio or
  networking.
- **C6 (KGX)** and **S9 (KWM)** share only KGA; they can proceed concurrently.
- **KVK (C7)** and **KGL (C8)** share KGX and can proceed concurrently **after**
  C6, but not before.
- **KLC** and **KWC** share no code except the process/thread plumbing; they are
  independent after C0.

Blockers, stated plainly:

| Blocker | Blocks | Resolution |
|---|---|---|
| No runtime evidence (no QEMU/OVMF) | every phase's E/H level | S0 |
| No IOMMU | user-space GPU drivers, safe device assignment | S2 |
| No user-address wait primitive | KLC futex, KWC wait objects | C0 kernel work |
| No signal subsystem | KLC signals, SEH interaction | S3 follow-up |
| No compositor service | KVK swapchain, KWC windows, KGL surfaces | S9 |
| No KGA | all graphics compatibility | S7 |
| No package signing | distributing compatibility runtimes safely | S11 |

## 3. Phases

### C0 — Compatibility foundations in the kernel

- **Objective:** provide the minimal, generic kernel mechanisms every personality
  needs, without teaching the kernel any foreign ABI.
- **Scope:** task personality flag; generic foreign-syscall gate with a validated
  per-persona dispatch table; wait/wake on user addresses (futex-class);
  per-process handle table foundation; hardened `user_access` (copy-in/out,
  TOCTOU-free validation); diagnostic counters for unknown calls.
- **Dependencies:** S3 (processes, capabilities, ABI).
- **Components:** kernel personality gate, wait queues, handle primitives.
- **Completion criteria:** a test persona can execute a trap and reach a handler;
  unknown numbers return a documented error and increment a counter; a hostile
  pointer is rejected in every handler path.
- **Conformance tests:** gate fuzzing (bad pointers, bad sizes, bad numbers); the
  native ABI conformance suite still passes unchanged.
- **Performance tests:** cost per gated call (ns), measured against the native
  syscall on the same machine.
- **Risks:** gate becomes an ABI dumping ground; mitigations: explicit number
  budget per persona, review per family, no handler without a test.
- **Evidence required:** serial log of the gate test, counters, benchmark table.
- **Promotion:** P → F when the gate test runs in the emulator suite.

### C1 — KLC: ELF64 static execution

- **Objective:** run a small corpus of static x86-64 Linux binaries.
- **Scope:** ELF64 parser/loader, initial stack + auxv, ~20 syscalls
  (`read`, `write`, `openat`, `close`, `mmap`, `munmap`, `mprotect`, `brk`,
  `exit`, `exit_group`, `clock_gettime`, `getpid`, `gettid`, `rt_sigaction`,
  `rt_sigprocmask`, `futex`, `clone` thread subset, `execve`, `wait4`, `uname`).
- **Dependencies:** C0, S4 (VFS).
- **Components:** KLC loader, syscall handlers, minimal KLIBC statically linked
  into the test corpus (for early tests only).
- **Completion criteria:** a 10-program corpus (hello, file copy, threads,
  allocator stress, signal, futex, mmap-heavy, malformed-input rejection) passes;
  each program is in the matrix with its exact syscall usage.
- **Conformance tests:** corpus + differential output comparison against an
  independent reference run; malformed ELF fuzzing.
- **Performance tests:** process start time; syscall cost per family.
- **Risks:** `brk` emulation differences; TLS setup errors; signals arriving in
  the middle of loader work.
- **Evidence:** per-program transcript, serial log, matrix entry.
- **Promotion:** P → F with the corpus; E in QEMU; H on reference hardware.

### C2 — KLC: filesystem, `/proc`, epoll

- **Objective:** make real command-line programs usable.
- **Scope:** compatibility root namespace, synthetic `/proc` and `/sys` subset,
  `epoll`/`eventfd`/`timerfd`, pipes, UNIX sockets, `stat`/`getdents`.
- **Dependencies:** C1.
- **Components:** namespace service, procfs generator, wait-set implementation.
- **Completion criteria:** a static file server and a static build tool run; `/proc`
  values are compared against their native sources and match by construction.
- **Conformance tests:** path resolution cases, permission denials, epoll edge
  cases (level vs edge, EPOLLONESHOT).
- **Performance tests:** epoll wait latency and scalability (1, 100, 1000 fds).
- **Risks:** `/proc` fidelity is a rabbit hole; mitigation: publish exactly what
  is generated.
- **Evidence:** transcript, generated-file comparison table.
- **Promotion:** P → F.

### C3 — KLC: dynamic linking and libraries

- **Objective:** run dynamically linked programs built for glibc.
- **Scope:** KLD loader, symbol versioning, TLS models, KLIBC core (memory,
  strings, stdio, pthread, dl), vDSO (KVD).
- **Dependencies:** C1, C2.
- **Components:** KLD, KLIBC, KVD.
- **Completion criteria:** a documented list of programs runs; symbol version
  mismatches are reported, never silently ignored.
- **Conformance tests:** ABI symbol tests (types, errno, struct layouts),
  `dlopen`/`dlsym` cases, TLS access patterns.
- **Performance tests:** library load time; `clock_gettime` via KVD vs syscall.
- **Risks:** glibc private interfaces (NSS, `__libc_*`); mitigation: matrix
  limits, explicit refusals.
- **Evidence:** symbol coverage report, per-program status.
- **Promotion:** P → F.

### C4 — KWC: PE32+ parser and loader (host-only first)

- **Objective:** parse, validate and map PE32+ images without executing them.
- **Scope:** headers, sections, relocations, imports, delay imports, TLS
  directory, `.pdata`, resources, load config.
- **Dependencies:** none beyond the host test harness (S3 for integration later).
- **Components:** PE parser (pure), loader, relocation engine.
- **Completion criteria:** 200-image corpus parsed and mapped in a test harness;
  malformed corpus rejected with diagnostics; relocation results verified against
  computed expectations.
- **Conformance tests:** fuzzing (headers, RVA arithmetic, section counts),
  differential mapping against a reference loader's results for valid images.
- **Performance tests:** parse+map time per megabyte.
- **Risks:** scope creep into execution before parsing is solid.
- **Evidence:** corpus results, fuzz coverage report.
- **Promotion:** P → F when the corpus passes in CI.

### C5 — KWC: console runtime

- **Objective:** run console Windows programs.
- **Scope:** ntdll/kernel32 subset (memory, files, threads, sync, exit), TEB/PEB,
  error codes, SEH/unwind, CRT, C++ exceptions.
- **Dependencies:** C4, C0, S4.
- **Components:** KNTDLL, KERNEL32/KERNELBASE, CRT, exception dispatcher, KOB.
- **Completion criteria:** a console corpus (hello, file I/O, threads, exceptions,
  DLL load) passes; unwind across module boundaries works.
- **Conformance tests:** API-level tests per function; exception matrix
  (C++ throw/catch, SEH `__try`, vectored handlers); malformed unwind tables.
- **Performance tests:** API call cost; thread creation; exception dispatch cost.
- **Risks:** TEB/PEB layout guesses; mitigation: document every field used and
  test it, no "probably matches".
- **Evidence:** transcript per program, field-usage table.
- **Promotion:** P → F.

### C6 — KGX and KGA

- **Objective:** a shared execution core and a native API that can drive a real
  GPU.
- **Scope:** KGX object model, pipeline/state, descriptor model, shader
  ingestion (SPIR-V → IR), validation; KGA objects, command buffers, sync,
  memory, swapchain; KGT validator.
- **Dependencies:** S6 (KGC), S5 (KDS), S7 in `PRODUCT_ROADMAP`.
- **Components:** KGX, KGA, KGT core.
- **Completion criteria:** a triangle and a textured quad render on virtio-gpu
  through KGA; a compute dispatch writes a verifiable buffer; the validator
  catches deliberately broken usage.
- **Conformance tests:** unit tests for encoders, golden-image tests for the
  triangle, negative tests for validation.
- **Performance tests:** submission CPU cost, frame time on the reference scene.
- **Risks:** KGX becomes a lowest common denominator; mitigation: §3 of the
  graphics compatibility document (express the union, emulate locally).
- **Evidence:** captured frame, validation report, counters.
- **Promotion:** P → F; E in QEMU with virtio-gpu.

### C7 — KVK: Vulkan compatibility

- **Objective:** run Vulkan applications on Kynox.
- **Scope:** Vulkan 1.0–1.3 core subset, instance/device/queue, command buffers,
  descriptors, pipelines, render-pass compatibility, sync, memory, swapchain,
  SPIR-V passthrough, feature discovery; `libvulkan` ICD.
- **Dependencies:** C6, S9 (KWM) for swapchain.
- **Components:** KVK front-end, ICD, feature table generator.
- **Completion criteria:** the Vulkan conformance harness subset passes; two
  real applications render correctly; deviations table published.
- **Conformance tests:** CTS subset with a pass-rate matrix; per-feature tests;
  negative tests (invalid usage must be rejected or handled as declared).
- **Performance tests:** `vkQueueSubmit` cost, pipeline cache hit rate, frame
  time versus KGA on the same scene.
- **Risks:** render-pass emulation on a dynamic-rendering backend; descriptor
  emulation cost; feature-table lies (forbidden).
- **Evidence:** CTS report, deviation table, before/after captures.
- **Promotion:** P → F; E in QEMU; H on hardware.

### C8 — KGL: OpenGL compatibility

- **Objective:** run OpenGL 3.3-core and 4.6-core applications; evaluate 1.x/2.x.
- **Scope:** GLX/EGL surfaces, state tracker, object layer, GLSL→SPIR-V front-end,
  FBO/VBO/VAO, immediate mode (1.x/2.x), compatibility-profile study.
- **Dependencies:** C6, S9 for surfaces.
- **Components:** KGL front-end, GLSL compiler, fixed-function shader library.
- **Completion criteria:** OpenGL CTS pass rate per level published; a named
  corpus of applications runs.
- **Conformance tests:** CTS per level; state-tracker unit tests; shader
  compilation corpus.
- **Performance tests:** draw-call cost at increasing state-change rates;
  immediate-mode throughput.
- **Risks:** compatibility profile scope explosion; mitigation: refuse contexts
  that cannot be honoured.
- **Evidence:** CTS matrix, per-application results.
- **Promotion:** P → F; E; H.

### C9 — Window-system bridges

- **Objective:** let Linux and Windows applications create windows.
- **Scope:** Wayland-compatible protocol bridge (preferred) and/or X11 bridge for
  KLC; HWND/message-loop bridge for KWC (part of `user32`); input translation;
  clipboard basics.
- **Dependencies:** S9, C7, C8.
- **Components:** KWM bridge service, protocol translators, input mapper.
- **Completion criteria:** a windowed OpenGL and a windowed Vulkan application
  from each personality open, resize, receive input and present.
- **Conformance tests:** protocol conformance for the implemented subset; input
  edge cases (focus, capture, IME).
- **Performance tests:** input-to-photon for a bridged client versus native.
- **Risks:** X11 protocol breadth; mitigation: Wayland-first, X11 only if the
  application corpus demands it.
- **Evidence:** captured sessions, latency measurements.
- **Promotion:** P → F.

### C10 — KWC: user32, GDI, COM

- **Objective:** run windowed Windows applications.
- **Scope:** user32 windows/messages, gdi32 over KGA-UI, clipboard, COM subset,
  registry virtualisation, installer-like workloads.
- **Dependencies:** C5, C9, KGA-UI.
- **Components:** USER32, GDI32, OLE32 subset, registry service.
- **Completion criteria:** a named corpus of windowed applications runs;
  installer-like workload completes; COM STA/MTA tests pass.
- **Conformance tests:** message-order tests, GDI drawing golden images, COM
  apartment tests.
- **Performance tests:** GDI drawing throughput; message latency.
- **Risks:** GDI performance; COM threading model.
- **Evidence:** corpus results, drawings, latency.
- **Promotion:** P → F.

### C11 — Direct3D (optional, not scheduled)

See §7. Not part of the critical path and not required for any earlier phase.

## 4. Dependency graph

```text
C0 ──▶ C1 ──▶ C2 ──▶ C3
 │       │
 │       └────────────▶ C9 ──▶ C10
 ├──▶ C4 ──▶ C5 ───────────────┘
 │
S5 ──▶ S6 ──▶ C6 ──┬──▶ C7 ──┐
                   │          ├──▶ C9
                   └──▶ C8 ──┘
C7 ──▶ C11 (only with C8 for D3D9)
```

## 5. Conformance and performance harnesses (shared by all phases)

| Harness | Purpose | Must exist before |
|---|---|---|
| **Corpus runner** | executes each program in the matrix and records pass/fail + transcript | C1 |
| **Malformed-input fuzzer** | ELF and PE parsers, syscall gate, unwind tables | C1, C4 |
| **Differential harness** | compares observable behaviour against the reference platform where legal and available | C1 |
| **API conformance suites** | Khronos CTS for GL/VK; KWC's own per-function tests | C7, C8 |
| **Performance lab** | fixed scenarios, fixed hardware, published numbers with dates | C6 |
| **Support-matrix generator** | turns test results into the published matrix; no manual claims | C1 |

Rule: **the matrix is generated from test runs**, never edited by hand. A phase
that cannot generate its matrix is not done.

## 6. Maturity promotion rules

1. A compatibility layer is promoted **per contract**, not as a whole
   (Linux §2, Windows §3): the executable-format contract can be F while the
   library contract is not started.
2. `implemented` requires passing tests in CI; `integrated` requires running
   inside the real boot path; `validated` requires the emulator suite; `blocked`
   is recorded with the blocking issue.
3. A percentage may rise only when the *scoped behaviour* is integrated and
   evidenced. Writing a loader that parses 200 images does not move the
   compatibility percentage; running programs does.
4. A layer may never be promoted because a higher layer depends on it.

## 7. Direct3D: dependencies, risks, entry criteria

| Item | Requirement |
|---|---|
| Architectural prerequisite | KGX descriptor/binding model proven by KVK 1.3; HLSL→SPIR-V front-end |
| D3D12 | after KVK 1.3; root signatures/descriptor heaps map to KGX; bundles need secondary command buffers |
| D3D11 | after D3D12; state translation, deferred contexts |
| D3D10 | after D3D11; close to 11 |
| D3D9 | after KGL 3.3; fixed-function reuses KGL generated shaders |
| Risks | unbounded API surface; shader model gaps; DXGI/window integration; legal exposure of reimplementation |
| Explicit non-goal | running anti-cheat-protected titles, or claiming "runs DirectX games" |

## 8. What this roadmap will never promise

- That any specific game, application or suite runs.
- That compatibility layers are invisible in performance terms.
- That foreign kernel drivers, anti-cheat or DRM work.
- That 32-bit binaries, ARM binaries or other architectures work.
- That a loaded image equals compatibility: every phase has its own matrix.
