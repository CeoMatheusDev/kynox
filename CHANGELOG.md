# Changelog

All notable changes to Kynox are recorded in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project uses [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)
with release tags prefixed by `v` (`v0.1.0-alpha.1`). Prereleases use the
`-alpha.N` / `-beta.N` / `-rc.N` suffixes.

Rules used for this file:

- Entries describe what the **tree** does, not intentions.
- Validation entries name the command and its result; a test that was not
  executed is listed as not executed.
- Maturity percentages are not changelog material; see `docs/PROJECT_STATUS.md`.

## [Unreleased]

Repository audit, governance and documentation for the first alpha, followed by
the P1 blockers of the alpha readiness phase (single version source, native ABI
contract, ACPI platform discovery) and the official identity scheme. Current
identity: **Kynox One 0.1.0-alpha.1**. No tag exists.

### Added

- `docs/strategy/market-landscape.md` — market structure, nine technology
  deep dives (desktop, window management, rendering, GPU APIs, driver models,
  gaming, security, updates, tooling), ranked opportunities, risk register and
  fifteen dated sources. Planning document: it claims no feature.
- `docs/architecture/platform-architecture.md` — layer map with a "today"
  column, a sixteen-row kernel/user-mode table, twenty subsystem contracts
  (responsibility, interfaces, dependencies, privilege bounds, concurrency,
  memory, failure, security, performance criteria, current state, next step),
  dependency graph, concurrency model, failure ladder and unmeasured budgets.
- `docs/architecture/graphics-platform.md` — Display System (KDS), GPU driver
  model with honest vendor tiers, graphics core (KGC), native API (KGA),
  renderer (KGR), compositor and window system (KWM), tools (KGT), security
  and performance model, and graphics steps G0–G9.
- `docs/architecture/application-ecosystem.md` — KEX v2 layout and manifest,
  loader pipeline, SDK layers, linking model, KPK packaging and signing,
  installation layout, atomic updates and rollback, portal sandbox, and the
  compatibility contract for KLC/KWC.
- `docs/architecture/security-architecture.md` — claimed-today table, threat
  model, boot chain, hardening, capability proof obligations, device/IOMMU
  rules, sandbox, supply chain, audit and recovery, per-property evidence and
  explicit non-guarantees.
- `docs/architecture/graphics-compatibility.md` — KGA formalised as a contract
  (objects, commands, synchronisation, memory, pipelines, shaders, versioning,
  capability tiers, public/internal split), plus KGL (OpenGL) and KVK (Vulkan)
  as front-ends over one shared execution core (KGX). Includes semantic-gap
  tables, the Linux/Windows graphics path matrix, a security table and a
  performance-claim policy that forbids "zero overhead" language.
- `docs/architecture/linux-compatibility.md` — KLC: the seven separated
  contracts, ELF64 loading and initial process state, the three syscall
  translation options and the chosen staged hybrid, signals, futex/TLS,
  dynamic linking, KLIBC/KLD/KVD policy, namespace and permission model,
  security threats, support matrix and phases C-L0…C-L5.
- `docs/architecture/windows-compatibility.md` — KWC: why the ntdll boundary
  differs from Linux's trap boundary, PE32+ loading, TEB/PEB, the KOB handle
  model, kernel32/CRT, SEH/unwind, registry virtualisation, user32/GDI, COM,
  Winsock, the D3D evaluation and explicit non-guarantees.
- `docs/roadmap/COMPATIBILITY_ROADMAP.md` — phases C0–C11 with objective,
  scope, dependencies, components, completion criteria, conformance and
  performance tests, risks, evidence and promotion rules; a critical review
  that reorders the proposed sequence (KWM before KGL/KVK, KLC/KWC in
  parallel rather than last).
- `docs/architecture/platform-architecture.md` §4.19–4.20 — compatibility
  personalities (KLC/KWC) and graphics front-ends (KGL/KVK) contracts, plus
  their rows in §4.0 and §10 and the dependency-graph entry.
- `docs/architecture/application-ecosystem.md` §8, `security-architecture.md`
  §8.1 and `PRODUCT_ROADMAP.md` S15 integrated with the new layers; no
  maturity percentage changed and no compatibility claim added.
- `docs/decisions/0008` shared graphics core, `0009` SPIR-V ingestion,
  `0010` compatibility execution model — all accepted for planning with
  reversal criteria.
- `docs/strategy/market-landscape.md` sources S16–S26 (Vulkan 1.4.365 spec and
  SDK, OpenGL 4.6, System V AMD64 psABI, PE format, x64 ABI, Linux ABI
  stability, futex) and extended planning-document inventory.
- `docs/architecture/user-experiences.md` — five profiles (home, gaming,
  development, enterprise, professional) with numbered, measurable
  requirements and the rule that a profile is policy, never a separate ABI,
  package format or graphics stack.
- `docs/architecture/platform-architecture.md` §4.0 — public versus internal
  interface table for all eighteen subsystems; §4.17 updates/recovery and
  §4.18 virtualisation/enterprise contracts.
- `docs/roadmap/PRODUCT_ROADMAP.md` — stages S0–S15 ordered by real
  dependencies, each with scope, prerequisites, interfaces, deliverables,
  objective completion criteria, tests, risks, external dependencies and
  acceptance; the P/F/E/H evidence ladder separates prototype from hardware
  validation.
- `docs/decisions/0004…0007` — graphics stack split, native graphics API,
  user-space compositor, and packaging/sandbox/updates. Marked **accepted for
  planning**; none is implemented and each carries reversal criteria.
- `docs_conformance.zig` — `docs-conformance-tests`: asserts the required
  sections of the planning documents, their dated sources, their presence in
  `docs/PROJECT_STATUS.json`, the ADR index entries and the roadmap ladder. It
  asserts structure only, never that a planned feature exists.
- `docs/PROJECT_STATUS.json` — new `planning_documents` inventory; no
  percentage was changed.

### Added (earlier)

- `VERSION` — root file with the technical version (`0.1.0-alpha.1`), the only
  writable source of it.
- `docs/VERSIONING.md` — normative identity and versioning policy: public and
  technical forms, single source, generation resolution, SemVer rules, the five
  independent version lines, tags and the guards.
- `docs/roadmap/ERAS.md` — normative chart of generations (`0 Kynox One` …
  `14 Kynox Cosmos`), rules for opening an era and how to add one.
- `boot_markers_conformance.zig` — `boot-markers-conformance-tests`: every
  literal serial marker asserted by `tests/integration/boot-qemu.sh` must still
  be printed by a source. Verified by mutation (renaming `[KNK] handoff ok`
  fails the test). This guard caught a real regression: the kernel banner had
  stopped printing `[KNK] Kynox Nucleus Kernel`.
- `docs/audits/2026-10-31-audit.md` — full audit: executed build/test evidence,
  findings P1–P4 with file/line evidence, `v0.1.0-alpha.1` criteria assessment
  and a prioritized incremental plan.
- `docs/specs/boot-handoff-spec.md` — normative KNB → KNK handoff contract v1,
  derived from `shared/handoff.zig` and the loader/kernel call sites.
- `docs/specs/syscall-abi.md` — normative native syscall ABI (calling
  convention, frame layout, 22 syscalls, reserved number 12, validation rules,
  25 error codes, versioning policy).
- `docs/BUILD.md` — build/validation reference: toolchain acquisition, build and
  test commands, QEMU/OVMF prerequisites, and how to record results.
- `CHANGELOG.md` (this file).
- `docs/releases/0.1.0-alpha.1.md` — release-notes **draft** with the gate
  checklist; the tag does not exist.
- `version.zig` — single source of the system version (from `VERSION`),
  `build.zig.zon` mirror and `version-tests` artifact.
- `docs/VERSIONING.md` — identity, system version vs generation vs ABI revision
  vs binary-format vs protocol versions, channels and release procedure.
- `shared/syscall_abi.zig` — normative native ABI: revision 1, call numbers,
  limits, privilege values, error codes, capability kinds and rights.
- `abi_conformance.zig` — `abi-conformance-tests` artifact: fails when the
  contract, kernel dispatch, SDK and `docs/specs/syscall-abi.md` diverge.
- `docs/decisions/` — ADR register and three records: probes out of
  `kernel/main.zig` (0001), a single VirtIO transport owned by KVDI (0002), and
  the fate of the legacy `virtio_blk.zig` stub (0003). All three record a
  decision; none of them changes code.
- `docs/validation/qemu.md` — QEMU procedure (prerequisites, exact VM
  configuration, what a run must record) and the dated table of attempts, all
  marked not executed for the missing firmware and emulator.
- `docs/specs/acpi-platform.md` — RSDP/XSDT/RSDT/MADT discovery, validation,
  fallback lines and the explicit list of what is not implemented.
- ACPI discovery in the boot path: `acpi.discoverMadt` with an injected table
  source, `Madt.lapicBase()`/`IoApic.isValid()` validation, `apic.setBase`/
  `resetBase`, and `discoverAcpi` in `kernel/main.zig` (before CR3 is replaced).
- `acpi.zig` is now reachable from the `arch-tests` root: its tests had never
  executed before this change.

- `kernel/arch/x86_64/ioapic.zig` — I/O APIC register access and redirection
  entries: MMIO offsets (select `0x00`, window `0x10`), version decode (version
  in bits 0..7, entry count minus one in bits 16..23), 64-bit entry
  encode/decode, `DeliveryMode`/`Polarity`/`Trigger`, `Controller` with
  `init`/`ownsGsi`/`readEntry`/`program`/`mask`/`unmask`/`maskAll`/`allMasked`
  and a small spinlock for the select/window pair. Eight host tests.
- `acpi.IsaRoute` and `acpi.isaRoute(irq, overrides)` — effective GSI,
  polarity and trigger of an ISA line, with the ISA bus default (high level,
  edge) and the MADT interrupt-source-override flags decoded per bits [1:0] and
  [3:2] (3 = reserved → conforming high/edge).
- I/O APIC programming in the boot path (`installIoApic`): maps the controller
  page, initialises it, masks every entry, programs the ISA lines in use
  (`32 + irq`, BSP destination) with the properties from `isaRoute`, and logs
  one line per route. Entries stay **masked**; delivery switches to the I/O
  APIC only with the new build option `-Dioapic-delivery=true`
  (`kynox_config.ioapic_delivery`, default `false`), which masks both 8259s
  before unmasking any entry.
- `timer.endOfInterrupt(vector)` and `timer.disablePic()` — the EOI target
  follows the delivery switch (local APIC when the I/O APIC delivers, 8259
  otherwise); masking the PIC is explicit and separate from the 8259 remap.
- `apic.sendInit(apic_id)` — INIT IPI, first message of the INIT-SIPI-SIPI
  sequence.
- SMP CPU table from the MADT: `smp.configureFromMadt` (enabled processors in
  table order, duplicates skipped, `max_cpus` cap), `apicIdFor`,
  `cpuIndexForApicId`, `bspCpuIndex`, `discoveredCpuCount`; `cpuId()` now
  translates the local APIC id through the table instead of assuming 0.
- `smp.publishTrampoline` and the startup gate: `startAps()` sends nothing when
  no AP was discovered or when the trampoline is not published below 1 MiB.
  When both hold, each AP receives INIT + two SIPIs and the BSP waits a bounded
  number of pauses for `online`; a silent AP is reported, never assumed online.
- `scripts/check-docs-links.py` and the build step `docs-check` (also part of
  `test`): every relative Markdown link must resolve in the tree.
- `scripts/provision-qemu.sh` — isolated, root-free provisioning of a static
  QEMU and OVMF into `.tools/` (ignored by Git); `--check` reports what is
  present. Blocked in this sandbox (see `docs/validation/qemu.md` §8).
- `.github/workflows/ci.yml` — build + host tests + documentation links, and a
  separate QEMU job that installs `qemu-system-x86`/`ovmf` and **fails
  explicitly** when it cannot, instead of reporting a green run that booted
  nothing. Not executed yet.

### Changed

- `probeVirtqueueLayout` (ADR-0002 step 2) now exercises
  `kvdi.virtqueue` instead of the legacy queue: the marker
  `[KNK] virtio: split queue layout ok` is unchanged, its numbers are the KVDI
  layout (`desc=0 avail=256 used=304 size=448`). `kernel/main.zig` no longer
  imports `arch/x86_64/virtio.zig`; the legacy module and `virtio_net.zig`
  remain for their last step (deletion), which is recorded as pending.
- `apic.zig` no longer leaves the register pointer `undefined` before `map`
  (undefined pointer arithmetic in `isMapped`); it points at the default base
  until mapped and `isMapped` reports an explicit flag. `sendIpi` mixed an enum
  with an integer in a bitwise or, which did not compile once instantiated —
  now explicit conversions.
- `smp.startAps()` no longer assumes sequential APIC ids (BSP = 0, APs = 1..n).
- `version.zig` now embeds `VERSION` instead of holding components, and resolves
  the official generation from the major: `display` is `Kynox One 0.1.0-alpha.1`,
  `generationFor`/`generationNameFor`/`generationOf`/`publicNameInto` reject
  majors without a name (`error.UnnamedGeneration`). Tests cover the chart,
  name uniqueness, arbitrary versions, the documents and the absence of
  literals in components.
- Boot and kernel banners print the public identity and the separate
  version/generation/tag/channel/ABI lines; the component marker is preserved
  (`[KNB] Kynox Native Boot - …`, `[KNK] Kynox Nucleus Kernel - …`).
- `docs/PROJECT_STATUS.md` / `docs/PROJECT_STATUS.json` — schema v2: per-subsystem
  `implemented`, `limitations`, `pending_work`, `tests` and `validation` fields;
  status vocabulary migrated to the mandated set
  (`not_started`, `scaffolding`, `in_progress`, `implemented`, `integrated`,
  `validated`, `blocked`); executed validation recorded. **Maturity percentages
  were not raised.**
- `README.md` — dated verification record (what was executed), toolchain
  acquisition note, links to the new audit and specs, corrected claims about
  built test applications.
- `sdk/README.md` — rewritten from the code: current modules, entry contract,
  usage, ABI reference and real validation state. Removed obsolete claims
  (unvalidated status, `feat/native-sdk` branch instructions, "Fedora" as the
  only validation host, ABI revision 9, "no new syscall numbers", F6 raster
  "not connected to the boot framebuffer").

- `kernel/arch/x86_64/syscall.zig`, `kernel/security/capability.zig`, `sdk/src/syscall.zig`,
  `sdk/src/root.zig`, `boot/uefi/main.zig`, `kernel/main.zig`, `tools/fatimg.zig`
  now derive their version constants, syscall numbers, error codes and
  capability values from the shared contract instead of private copies.
- `apic.apic_base` (fixed const) became `apic.default_base` plus a validated,
  runtime-selected base; `installSmp` maps the base actually in use.
- `build.zig.zon` version `0.1.0-dev.3` → `0.1.0-alpha.1`; loader and kernel
  banners print the system version, tag and ABI revision.
- `tests/integration/boot-qemu.sh` — an empty `OVMF_CODE`/`OVMF_VARS` pair is no
  longer printed as `:` in the diagnostic (setting only one of them is now an
  explicit error), and a missing `qemu-system-x86_64` is reported as such with
  exit code 3 instead of failing inside the VM launch.

### Fixed

- Dangling documentation references: `docs/specs/boot-handoff-spec.md` and
  `docs/specs/syscall-abi.md` are now real; the reference to a non-existent
  `docs/adr/ADR-F04-block-driver-proposta.md` in
  `kernel/arch/x86_64/virtio_blk.zig` was replaced by an honest statement of the
  pending work (ADR to live in `docs/decisions/`, per `strategy.md`).
- `.gitignore` — removed a stray Markdown fence that had been committed at the
  end of the file.
- `tools/fatimg.zig` module documentation — stated the image content it really
  writes (`/boot/KYNOXK.ELF`) instead of a file name the loader would not find
  (audit A-19).
- `docs/PROJECT_STATUS.md` — "multiple built test applications" corrected to the
  two applications the build actually embeds (`user/hello.zig`,
  `user/client.zig`).

### Validation performed

| Command | Result |
|---|---|
| `zig version` | `0.17.0` |
| `zig build` | success (14/14 steps); `kynox.img` 128 MiB, 32 731 clusters |
| `zig build test` | success — 709/709 tests, 49/49 steps (23 test artifacts, fresh cache, `docs-check` and `docs-conformance-tests` included) |
| `zig build docs-check` | success — every relative link resolves |
| `zig build -Dioapic-delivery=true` | success (compiles; **never booted**, so no delivery is claimed) |
| `zig build qemu-test` | not executed — exits 2, `no OVMF firmware found` (see `docs/validation/qemu.md`) |
| `zig build qemu-storage-test` | not executed — fails through the same dependency |
| `zig build qemu-interactive-test` | not executed — same missing firmware |
| `command -v qemu-system-x86_64` | absent; installing is impossible in this sandbox |

### Known limitations

See `docs/PROJECT_STATUS.md` §"Important limitations and corrections" and the
audit findings A-01 … A-18. The most important open items: runtime evidence at
all (QEMU/OVMF) — every I/O APIC and SMP claim above is host-tested only —,
delivery through the I/O APIC, AP bring-up (the trampoline is not published),
PCI GSI routing, and the remaining ADR steps (0001 reports/remaining probes,
0002 step 3, 0003).

## [0.1.0-alpha.1] — UNRELEASED (draft)

> This section is a **draft**. The tag `v0.1.0-alpha.1` does not exist, no date
> is assigned and no commit is recorded. It will be finalized only when the gate
> checklist in `docs/releases/0.1.0-alpha.1.md` is satisfied. Nothing here may be
> read as a released capability.

Work expected to be summarized at release time (already present in the tree,
first time documented):

- Native UEFI boot application (KNB) with the versioned KNB → KNK handoff.
- Freestanding x86_64 kernel (KNK) with GDT/TSS/IDT, exception stubs, timer,
  four-level paging with NX enforcement and per-process user windows.
- PMM, kernel heap, DMA window; ACPI/PCI parsers; LAPIC; early AP startup.
- Preemptive scheduler with context switching and task lifecycle.
- `syscall`/`iretq` entry path with 22 native calls, capability checks and
  user-pointer validation.
- IPC channels with blocking, bounded queues, timeouts; typed capabilities with
  delegation and revocation.
- ELF64 load planning/materialization, KEX container, KPK package codec.
- RamFS, KFSX namespace, KNV volume commit/recovery, block API.
- KVDI (Kynox Virtual Device Interface) transport and synchronous VirtIO Block
  read/write/flush over a PCI virtqueue.
- Rasterizer, compositor, window manager, damage tracking, PS/2 keyboard input
  and a boot-time desktop scene.
- Zig SDK, two native applications embedded in the image, host test suite
  (661 tests) and QEMU integration scripts.
- **Not included:** Linux compatibility (0%), Windows compatibility (0%),
  networking stack, GPU acceleration, ring-3 services/compositor, dynamic
  linking, journaled filesystem.

## Release history

No release has been published. `git tag` is empty and the history starts at a
single commit (`5c98311`, branch base).
