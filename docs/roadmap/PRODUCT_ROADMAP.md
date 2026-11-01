# Kynox — Product Roadmap

- Status: **planning document**. No stage below is complete. Stage ordering is
  derived from the dependency graph and from the audit of the tree, not from a
  desired feature list.
- Date: 2026-10-31. Identity: **Kynox One 0.1.0-alpha.1** (the roadmap does not
  change the version).
- Related: [`platform-architecture.md`](../architecture/platform-architecture.md),
  [`graphics-platform.md`](../architecture/graphics-platform.md),
  [`application-ecosystem.md`](../architecture/application-ecosystem.md),
  [`security-architecture.md`](../architecture/security-architecture.md),
  [`market-landscape.md`](../strategy/market-landscape.md),
  [`KERNEL_COMPLETION_ROADMAP.md`](KERNEL_COMPLETION_ROADMAP.md),
  [`PROJECT_STATUS.md`](../PROJECT_STATUS.md).

## 1. Status ladder used in this document

Every deliverable is described at one of these levels. The ladder is cumulative;
a stage is only "done" at the level it declares.

| Level | Meaning | Evidence required |
|---|---|---|
| **P** Prototype | Code exists, may be incomplete, not in the boot path | Builds; unit tests where the code is pure |
| **F** Functional | Integrated into the real path, works on the reference machine | Host tests + a recorded run |
| **E** Emulator-validated | Works in QEMU/OVMF with the suite green | Recorded serial log, screenshots, marker assertions |
| **H** Hardware-validated | Works on named physical hardware | Recorded evidence per device, published matrix |

**Today no graphics, display, audio, network, IOMMU, update or sandbox item is
above P** — most are not even P. The kernel items that exist are at F/E-blocked
(no runtime evidence).

## 2. Ordering rationale (from the audit)

This roadmap orders the *product*: display, graphics, services, compatibility.
Kernel and core-systems work is ordered separately and at finer grain by
[`KERNEL_COMPLETION_ROADMAP.md`](KERNEL_COMPLETION_ROADMAP.md) (stages K0–K13).
Where the two overlap — S0 runtime evidence, S1 interrupts/SMP, S2 memory/IOMMU,
S3 processes/ABI — the kernel roadmap is the authority on ordering and this one
remains the authority on what the product needs from the kernel.

1. **Runtime evidence is the critical path.** The tree compiles and passes 748
   host tests, but no QEMU/OVMF run has ever been recorded. Every subsystem's
   maturity is capped by that, and no graphics work can be validated without a
   running system. This is stage 0 — an infrastructure prerequisite, not a
   feature.
2. **Interrupts and SMP must be honest before drivers multiply.** Programming
   more devices on top of an unproven interrupt path multiplies unverified code.
3. **Memory and IOMMU precede user-space drivers.** Without IOMMU, moving drivers
   to user space is a security theatre.
4. **Display before 3D.** A working mode-setting path with page flips gives the
   compositor a real target and produces visible, testable evidence early.
5. **Graphics core before renderer.** A renderer written before the API is
   stable teaches the wrong lessons.
6. **Services before desktop polish.** The desktop is a client of the compositor,
   the portal, the package manager and the session service.
7. **Gaming/professional features after the platform can measure itself.**
   Frame pacing and colour management are meaningless without instrumentation.

## 3. Dependency graph

```text
S0 runtime evidence ─┬─▶ S1 interrupts/SMP ─▶ S2 memory/IOMMU ─▶ S3 processes/ABI
                     │                                    │
                     ├─▶ S4 storage/VFS ──────────────────┤
                     │                                    ▼
                     └────────────────────────────▶ S5 display foundation
                                                          │
                                                          ▼
                                              S6 GPU model + KGC
                                                          │
                                                          ▼
                                                     S7 KGA + shaders
                                                       │        │
                                                       ▼        ▼
                                                  S8 renderer  S9 compositor
                                                                  │
                                                                  ▼
                                                            S10 desktop
                                                                  │
                                     S11 SDK/packaging ───────────┤
                                     S12 native apps ─────────────┤
                                                                  ▼
                                                   S13 gaming / S14 pro-enterprise
                                                                  │
                                                                  ▼
                                                        S15 compatibility
```

Parallelisable early: S4 (storage) with S1–S2; S11 (packaging) with S5–S9;
S12 (apps) only after S10.

## 4. Stages

### S0 — Runtime evidence and CI execution

- **Objective:** make every subsequent claim verifiable.
- **Scope:** QEMU/OVMF in the environment and in CI; execute boot, storage and
  interactive suites; record logs, versions and image hashes; fix what they
  reveal.
- **Prerequisites:** none (it is the prerequisite).
- **Components:** `tests/integration/*`, `docs/validation/*`, CI workflow.
- **Interfaces:** the existing `zig build qemu-*` targets.
- **Deliverables:** recorded suite results; `docs/validation/qemu.md` updated with
  real logs; CI green.
- **Completion criteria:** three suites executed at least once with logs stored;
  failures triaged.
- **Tests:** the suites themselves; marker assertions; screenshots.
- **Risks:** environment without virtualization; flaky timing; large logs.
- **External deps:** QEMU, OVMF, a machine/runner that can boot.
- **Acceptance:** evidence table in the repo, no "not executed" entries for the
  suites that ran.

### S1 — Interrupts, IOAPIC delivery and AP bring-up

- **Objective:** real interrupt routing and a second CPU executing code.
- **Scope:** I/O APIC delivery proven for PIT/keyboard; trampoline copied below
  1 MiB; AP starts, runs a known workload, reports back; per-CPU timer and IPI.
- **Prerequisites:** S0.
- **Components:** `arch/x86_64/{apic,ioapic,smp,timer,interrupt}.zig`, trampoline.
- **Interfaces:** interrupt registration, IPI send, AP start handshake.
- **Deliverables:** boot log showing an AP online and a work counter per CPU.
- **Completion criteria:** AP executes ≥ N iterations, BSP observes it, no lost
  interrupts over M seconds.
- **Tests:** boot suite with assertions on the new markers; stress of
  INIT-SIPI-SIPI; timeouts.
- **Risks:** firmware/APIC differences; triple faults during AP start.
- **External deps:** QEMU SMP ≥ 2 vCPUs.
- **Acceptance:** recorded run with 2+ CPUs; no SMP claim before it.

### S2 — Memory, address spaces and IOMMU

- **Objective:** safe, scalable memory management with device isolation.
- **Scope:** region abstraction, demand paging, TLB shootdown, high-half decision,
  IOMMU discovery and domain mapping, DMA pinning.
- **Prerequisites:** S1.
- **Components:** `kernel/memory/*`, `arch/x86_64/paging.zig`, ACPI DMAR/IVRS.
- **Interfaces:** map/protect/region, DMA map/unmap, IOMMU domain attach.
- **Deliverables:** documented VM layout; IOMMU fault injection test.
- **Completion criteria:** isolation tests between two address spaces; device
  writes outside its window fault; TLB shootdown correct under stress.
- **Tests:** unit + QEMU stress; IOMMU negative tests.
- **Risks:** IOMMU absent in many systems; performance cost of shootdown.
- **External deps:** virtual IOMMU in QEMU; real hardware later.
- **Acceptance:** recorded scenarios, including the no-IOMMU fallback.

### S3 — Process model, ABI and capability coverage

- **Objective:** a complete process lifecycle and an enforceable authority model.
- **Scope:** process/thread creation and reaping, wait objects, signals
  equivalents, resource limits, capability kinds for devices/GPU/memory, ABI
  stability policy, syscall fuzzing.
- **Prerequisites:** S1, S2.
- **Components:** `kernel/task/*`, `kernel/security/*`, `shared/syscall_abi.zig`,
  `sdk/*`.
- **Interfaces:** ABI revision 2 (additive), process API, capability transfer.
- **Deliverables:** SDK process API; conformance tests; fuzz corpus.
- **Completion criteria:** malformed syscalls never crash the kernel; every
  capability kind has an enforcement test.
- **Tests:** host + QEMU; fuzzing in CI.
- **Risks:** ABI churn breaking samples; revocation complexity.
- **External deps:** none.
- **Acceptance:** ABI document updated and conformance suite green.

### S4 — Storage, VFS and recovery

- **Objective:** durable, recoverable storage suitable for a real system.
- **Scope:** async block I/O with timeouts, journaled filesystem, VFS service,
  permissions, crash recovery tests.
- **Prerequisites:** S1, S2.
- **Components:** `kernel/storage/*`, `kernel/fs/*`, future VFS service.
- **Interfaces:** block device ops, VFS ops, mount policy.
- **Deliverables:** filesystem with journal/replay; power-loss test harness.
- **Completion criteria:** kill-at-random-point test leaves a mountable FS with no
  corruption; fsck-equivalent tool repairs metadata.
- **Tests:** QEMU with forced resets; fault injection.
- **Risks:** data loss bugs; performance of journaling.
- **External deps:** none.
- **Acceptance:** recorded recovery runs; limitations published.

### S5 — Display foundation (KDS Tier 0/1)

- **Objective:** real mode setting and page flips with fences.
- **Scope:** KDS object model, EDID/DisplayID parsing, atomic commit, hotplug,
  DPMS, GOP fallback; virtio-gpu driver as the first target.
- **Prerequisites:** S1, S2, S4 (for firmware loading paths).
- **Components:** new `kernel/graphics/display_core`, virtio-gpu transport,
  display service skeleton.
- **Interfaces:** KDS commit API; connector/CRTC/plane model; event queue.
- **Deliverables:** mode change to a non-firmware mode in QEMU; flip with fence;
  hotplug event.
- **Completion criteria:** 1000 flips without a missed fence; mode change
  survives an invalid request; unplug is handled.
- **Tests:** QEMU display tests; screenshot comparison; fence timing.
- **Risks:** virtio-gpu limitations; EDID corpora quality.
- **External deps:** QEMU virtio-gpu.
- **Acceptance:** recorded evidence at E level.

### S6 — GPU driver model and graphics core

- **Objective:** memory objects, queues, submission, fences and reset.
- **Scope:** KGC objects/heaps/VA, rings, scheduler, hang detection/reset; driver
  host interface; virtio-gpu 3D if available, otherwise a null device for tests.
- **Prerequisites:** S5, S2 (IOMMU for user-space drivers).
- **Components:** `kernel/graphics/core/*`, driver host service, validation.
- **Interfaces:** KGC ioctl-like API (internal), driver interface (§5.1 of the
  graphics doc).
- **Deliverables:** submission of an empty command buffer completing via fence;
  forced hang → context reset.
- **Completion criteria:** 10k submissions without leak; reset path tested;
  validator rejects malformed streams.
- **Tests:** host validator tests; QEMU with a virtual GPU; fault injection.
- **Risks:** no virtual GPU with real 3D in QEMU; driver host complexity.
- **External deps:** virtio-gpu, optional vhost-user GPU.
- **Acceptance:** E-level for submission/reset; H-level only later.

### S7 — Native graphics API and shader toolchain

- **Objective:** a stable, documented, validated low-level API.
- **Scope:** KGA objects, command buffers, pipelines, descriptors, fences;
  shader input format decision (ADR-0005); compiler MVP; validation layer.
- **Prerequisites:** S6.
- **Components:** user-space KGA library, KSC compiler, validator.
- **Interfaces:** KGA revision 1; ABI for SDK bindings.
- **Deliverables:** triangle and textured quad samples; pipeline cache; validator
  report.
- **Completion criteria:** API reference published; samples pass on Tier 1/2;
  validator catches a seeded bug class.
- **Tests:** golden-image tests on the software path; API conformance suite.
- **Risks:** API scope creep; shader compiler effort underestimated.
- **External deps:** SPIR-V tooling if adopted.
- **Acceptance:** documented API + samples + tests.

### S8 — Renderer

- **Objective:** a reference renderer usable by applications and tests.
- **Scope:** software reference renderer; GPU renderer with PBR/HDR/shadows;
  feature matrix from the graphics doc; deterministic capture.
- **Prerequisites:** S7.
- **Components:** `kynox-render` library, scene format, golden-image harness.
- **Interfaces:** render graph (KGA-H), scene description.
- **Deliverables:** scenes (Cornell box, PBR material grid, HDR test chart).
- **Completion criteria:** deterministic software output; GPU output within
  documented tolerance.
- **Tests:** golden images in CI; performance baselines.
- **Risks:** floating-point nondeterminism; GPU/driver bugs on early hardware.
- **External deps:** none mandatory.
- **Acceptance:** E-level on Tier 0; P-level on GPU until hardware exists.

### S9 — Compositor and window system

- **Objective:** a restartable user-space compositor with a real protocol.
- **Scope:** surfaces, buffers, damage, frame callbacks, input routing, scaling,
  multi-monitor, HDR/colour policy, capture permissions.
- **Prerequisites:** S5, S3 (IPC/capabilities), S2 (shared memory).
- **Components:** KWM service, client library, session integration.
- **Interfaces:** KWM protocol revision 1; KDS commit; input events.
- **Deliverables:** multi-window session with damage-based composition and frame
  pacing metrics.
- **Completion criteria:** compositor restart preserves clients; 60 fps UI on
  reference hardware; missed-frame attribution works.
- **Tests:** protocol conformance; crash/restart; golden screenshots.
- **Risks:** input focus semantics; GPU/CPU composition divergence.
- **External deps:** none.
- **Acceptance:** E-level on Tier 0/1.

### S10 — Desktop environment and session

- **Objective:** a familiar, responsive desktop.
- **Scope:** shell/launcher, taskbar, notifications, session manager, settings,
  file manager, terminal, accessibility basics.
- **Prerequisites:** S9, S4, S11 (packaging for apps).
- **Components:** session service, desktop shell, native applications.
- **Interfaces:** KWM, portal broker, package manager.
- **Deliverables:** installable image with a working desktop and app launching.
- **Completion criteria:** documented user flows (login, launch, move/resize,
  lock, logout) pass automated UI tests.
- **Tests:** scripted session tests; accessibility checks; the Home profile
  requirements HOM-01…HOM-07 of `user-experiences.md` become test cases here.
- **Risks:** scope; theming consistency; input edge cases.
- **External deps:** fonts (licensed/open), iconography.
- **Acceptance:** E-level run recorded; usability review documented.

### S11 — SDK, packaging, updates

- **Objective:** third parties can build, install and update software.
- **Scope:** KEX v2, manifest, signed KPK, repository protocol, installer,
  atomic updates, rollback, developer tools.
- **Prerequisites:** S3 (ABI), S4 (storage), S10 (installer UX).
- **Components:** `tools/kynox` CLI, package service, repository, updater.
- **Interfaces:** package format spec, manifest schema, repository index.
- **Deliverables:** `kynox new/build/pack/publish`, install and rollback.
- **Completion criteria:** tampered package rejected; failed update rolls back
  automatically; offline install works.
- **Tests:** update/rollback fault injection; signature tests.
- **Risks:** key management; delta format complexity.
- **External deps:** signing infrastructure.
- **Acceptance:** E-level end-to-end install/update recorded.

### S12 — Native applications

- **Objective:** prove the platform with real applications.
- **Scope:** shell, terminal, file manager, settings, text editor, image viewer,
  a 2D game, a 3D sample.
- **Prerequisites:** S10, S11, S7/S8.
- **Deliverables:** applications shipped in the image.
- **Completion criteria:** each app has tests and no privileged code; SDK samples
  become these apps.
- **Tests:** UI automation; crash-free session tests; Development profile
  requirements DEV-01…DEV-07 of `user-experiences.md`.
- **Risks:** application quality distracts from platform work; scope control.
- **Acceptance:** documented per-app status.

### S13 — Gaming features

- **Objective:** competitive, measurable gaming experience.
- **Scope:** latency classes, frame pacing API, direct scanout, VRR, controller
  support, low-latency audio, capture/profiling for developers, game-mode
  session.
- **Prerequisites:** S9, S6, S7, audio service.
- **Deliverables:** input-to-photon measurement harness; game session mode.
- **Completion criteria:** published measurements on named hardware; no
  regressions in desktop latency.
- **Tests:** latency harness in CI (emulator) and on hardware.
- **Risks:** hardware variance; anti-cheat incompatibility (documented, not
  solved).
- **Acceptance:** H-level evidence for the reference device.

### S14 — Professional and enterprise

- **Objective:** colour-critical, compute-heavy and managed deployments.
- **Scope:** colour calibration/ICC, 10-bit HDR pipeline, multi-GPU compute,
  virtualization, device management, encryption policy, audit, fleet enrolment.
- **Prerequisites:** S5–S8, S11, security architecture stages.
- **Deliverables:** colour-managed workflow; management service; encrypted
  fleet image.
- **Completion criteria:** colour accuracy measured; policy enforcement tested;
  recovery audited.
- **Tests:** colour charts; policy conformance; recovery drills; Professional
  (PRO-01…PRO-08) and Enterprise (ENT-01…ENT-08) requirements from
  `user-experiences.md`.
- **Risks:** certification requirements; management plane scope.
- **Acceptance:** documented pilot deployment.

### S15 — Compatibility and ecosystem expansion

- **Objective:** run foreign binaries and third-party drivers without compromising
  the native platform.
- **Scope:** the compatibility phases of
  [`COMPATIBILITY_ROADMAP.md`](COMPATIBILITY_ROADMAP.md): KLC (ELF64 → Linux ABI
  subset), KWC (PE32+ → Win64/NT subset), KGL/KVK, third-party driver packages,
  conformance and deviation matrices.
- **Ordering note:** compatibility does **not** wait for S15. The roadmap splits
  it: the ELF loader and syscall gate begin after S3/S4, the PE parser is
  host-only work that can start earlier, and the graphics front-ends follow S7
  and S9. S15 is the *publication* stage: matrices, per-application status and
  the first supported set.
- **Prerequisites:** S3, S6, S11, security architecture.
- **Deliverables:** published support matrices; conformance harness; per-title
  status.
- **Completion criteria:** a documented set of applications runs with tests; no
  Ring 0 compatibility shims.
- **Tests:** differential and conformance tests; anti-cheat expectations
  documented.
- **Risks:** unbounded scope; legal; anti-cheat.
- **Acceptance:** matrix published, claims limited to tested items.

## 5. Critical path and schedule discipline

- **Critical path:** S0 → S1 → S2 → S5 → S6 → S7 → S9 → S10 → S11 → S12.
- **Do not start** S6 before S5, S9 before S5, S13 before S9, or S15 before S11
  and the security stages.
- **Parallel work that is safe now:** S4 (storage), S11 design (packaging
  specification), documentation and conformance harnesses.
- **Blocked by infrastructure:** everything that needs a boot. S0 is the single
  highest-value unblocking action.

## 6. Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| No runtime environment | Every stage stalls at P | S0 first; CI runner with KVM/TCG |
| GPU vendor support | Graphics stalls at Tier 1 | virtio-gpu first; Intel/AMD next; NVIDIA later |
| Scope explosion | No stage completes | Per-stage acceptance criteria; no stage starts early |
| Security claims without tests | Credibility loss | Evidence table per property; no claim without a test |
| Performance claims without baselines | Misleading marketing | Benchmark harness before optimisation |
| ABI churn | Ecosystem distrust | Additive revisions; deprecation windows |
| Key management | Update chain failure | Pre-production key rotation test |

## 7. Traceability to status percentages

This roadmap **does not raise any maturity percentage**. The status inventory in
[`PROJECT_STATUS.md`](../PROJECT_STATUS.md) moves only when a stage produces
integrated, executed evidence. As of 2026-10-31:

- every kernel subsystem is at F or below, with E blocked by S0;
- graphics is at P (software rasteriser/compositor) with no display or GPU
  contract;
- application ecosystem, packaging, audio, network and compatibility are at or
  near 0%;
- no stage in this roadmap is complete.

## 8. Definition of done for a stage

A stage is complete only when: deliverables exist and are integrated; acceptance
tests were executed and recorded; limitations and non-goals are documented;
status files and CHANGELOG are updated; and the next stage's prerequisites are
satisfied without hidden debt.
