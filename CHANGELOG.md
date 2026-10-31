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
contract, ACPI platform discovery). No tag exists.

### Added

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
- `version.zig` — single source of the system version (`0.1.0-alpha.1`),
  `build.zig.zon` mirror, `version-tests` artifact.
- `docs/specs/versioning.md` — system version vs ABI revision vs binary-format
  versions, channels and release procedure.
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

### Changed

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
| `zig build` | success (13/13 steps); `kynox.img` 128 MiB, 32 731 clusters |
| `zig build test` | success — 661/661 tests, 43/43 steps (21 test artifacts, fresh cache) |
| `zig build qemu-test` | not executed — exits 2, `no OVMF firmware found` (see `docs/validation/qemu.md`) |
| `zig build qemu-storage-test` | not executed — fails through the same dependency |
| `zig build qemu-interactive-test` | not executed — same missing firmware |
| `command -v qemu-system-x86_64` | absent; installing is impossible in this sandbox |

### Known limitations

See `docs/PROJECT_STATUS.md` §"Important limitations and corrections" and the
audit findings A-01 … A-18. The most important open items:
IOAPIC programming and routing, runtime evidence at all (QEMU/OVMF), CI, and
the architecture decisions listed in stage 5 of the readiness phase.

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
