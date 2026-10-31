# Kynox — Project Status & Progress

> Snapshot: **2026-10-31**, produced by a source-tree audit that also **executed**
> the build and the host test suite. Percentages are **engineering maturity
> estimates**, not measured completion of the entire operating system.
>
> Audit report: [`docs/audits/2026-10-31-audit.md`](audits/2026-10-31-audit.md).
> Machine-readable counterpart (schema v2): [`PROJECT_STATUS.json`](PROJECT_STATUS.json).

## How to read the percentages

The percentage estimates the maturity of the scoped subsystem, based on source
implementation, integration evidence, tests present in the repository, and known
limitations:

| Range | Meaning |
|---:|---|
| 0% | No implementation found; only a goal or proposal |
| 1–19% | Initial design, types, or isolated groundwork |
| 20–39% | Partial implementation; important execution paths are missing |
| 40–59% | Core implementation exists, but integration or semantics remain limited |
| 60–79% | Integrated path exists and has repository-level test coverage; important limitations remain |
| 80–99% | Broadly implemented; hardening, compatibility, or validation remains |
| 100% | Scope fully specified, integrated, tested, validated, and documented |

These are not percentages of lines of code, feature count, or time spent. A
module with many source files can still have a low score if its real execution
path is missing. Do not calculate a single overall OS percentage by averaging
unrelated areas.

**State vocabulary** (mandated by `AGENTS.md`): `not_started`, `scaffolding`,
`in_progress`, `implemented`, `integrated`, `validated`, `blocked`. The previous
schema used `partial`/`planned`; the migration is recorded in the JSON
(`status_migration`). No subsystem is `validated` today, because no runtime
(QEMU/hardware) evidence exists for this snapshot.

**Validation distinction.** On 2026-10-31 the following were executed:
`zig build` (13/13 steps) and `zig build test` (43/43 steps, **661/661 tests
passed**). `zig build qemu-test`, `qemu-storage-test`, `qemu-interactive-test`
and `check` were **not executed** — the environment has no QEMU, no OVMF and no
reachable package mirror. Host test results therefore appear as
`host_tests_passed`; every runtime claim remains `not_executed`.

## Executed validation record

| Command | Date | Result |
|---|---|---|
| `zig version` | 2026-10-31 | `0.17.0` |
| `zig build` | 2026-10-31 | success — `kynox-boot.efi` 181,760 B · `kynox-kernel` 65,770,762 B · `kynox.img` 134,217,728 B (128 MiB, FAT16 ESP, 32,731 clusters) |
| `zig build test` | 2026-10-31 | success — 661 tests (21 artifacts): kvdi 167 · fs-loader 154 · arch 112 · shared 64 · kernel 22 · user-composition 22 · security 18 · damage 15 · keyboard-motion 13 · kpk 9 · compositor 9 · sdk 8 · abi-conformance 7 · kex 7 · display 7 · ipc 6 · raster 5 · version 5 · keyboard 4 · block-api 4 · ai 3 |
| `zig build qemu-test` | — | **not executed** (no QEMU/OVMF) |
| `zig build qemu-storage-test` | — | **not executed** |
| `zig build qemu-interactive-test` | — | **not executed** |
| `zig build check` | — | **not executed** (depends on the QEMU steps) |

## Current progress matrix

| Subsystem | Maturity | State | What exists | Main gaps |
|---|---:|---|---|---|
| UEFI bootloader / handoff | **70%** | in_progress | Native UEFI application, kernel placement (ET_DYN bias, RELA), versioned KNB→KNK handoff, framebuffer/ACPI RSDP capture, ExitBootServices retry | No host tests for loader logic; firmware/hardware matrix; `processor_count` fixed to 1; boot never observed here |
| Kernel entry / CPU / interrupts | **60%** | in_progress | x86-64 entry with kernel-owned stack, GDT/TSS, IDT, exception/interrupt stubs, timer, fault self-test, NX enforced before use | Exception recovery audit, per-CPU state, hardware coverage |
| Physical memory / heap / DMA | **60%** | in_progress | PMM over the handoff map, kernel heap, DMA allocation/mapping and window probe | Scalability, fragmentation policy, reclaim, IOMMU |
| Virtual memory / address spaces | **45%** | in_progress | Four-level paging, per-process user windows, W^X encoded with negative tests, `isUserRange` validation everywhere | Region abstraction, demand paging, COW, ASLR, TLB shootdown, high-half |
| ACPI / PCI / APIC | **50%** | in_progress | ACPI RSDP/XSDT/MADT discovery at boot with validated LAPIC base and recorded IOAPICs/overrides, PCI config + BAR + capability walking, LAPIC xAPIC access and IPIs | **IOAPIC is discovered, not programmed**; overrides not applied to routing; no QEMU/hardware evidence |
| SMP / AP startup | **30%** | in_progress | AP stacks, trampoline, INIT/SIPI path invoked at boot | APs do not run the scheduler; per-CPU timer/IPI; SMP stress |
| Scheduler / task switching | **55%** | in_progress | Timer-driven preemption, task contexts/states, context-switch assembly, statistics | Effectively BSP-centric; per-CPU queues, migration, fairness, SMP safety |
| User processes / Ring 3 | **60%** | in_progress | User-mode tasks, separate address spaces, two embedded native apps, lifecycle probe | General process API, resource limits, isolation stress |
| Native syscall ABI | **55%** | in_progress | `syscall`/`iretq` door with MSR programming, 22 calls (12 reserved), pointer validation, SDK wrappers; one normative contract (`shared/syscall_abi.zig`, revision 1) aliased by kernel and SDK; conformance suite against the spec | Door never executed in a VM here; no argument fuzzing; revision checked at build/test time only |
| IPC | **60%** | in_progress | Bounded channels, blocking receive, receive with timeout, scheduler integration | Shared memory, service discovery, cancellation |
| Capabilities / security model | **60%** | in_progress | Typed kinds, per-holder rights, delegation/revocation, enforcement in syscalls | Complete object coverage, lifecycle audit, adversarial tests |
| ELF64 loader | **60%** | in_progress | Parsing, load planning, segment checks, relative relocations, materialization | Dynamic linking, TLS, richer relocations, malformed-input corpus |
| KEX native container | **55%** | in_progress | KEX v1 around ELF64, manifest entries, CRC validation, loader integration | Specification document, signature/trust, dependency metadata, ABI version |
| KPK package format | **45%** | in_progress | Codec with validation/checksum; pack/unpack exercised at boot | Package manager, signatures, dependencies, atomic update |
| Native SDK / runtime | **40%** | in_progress | Raw syscall layer, typed wrappers, shared contracts, two sample apps, startup assembly | Stable API promise, libraries, dynamic linker, allocator/libc |
| RamFS | **55%** | in_progress | In-memory FS: inodes, blocks, directories, file operations | Permissions, scale, crash recovery |
| KFSX namespace / VFS | **35%** | in_progress | Mount namespace, longest-prefix routing, mount generations, RamFS routing | Multiple backends, complete VFS operations, permissions, concurrency |
| KNV volume format | **60%** | in_progress | Deterministic little-endian image codec, validation, CRC, commit/recover; two-boot probe script | Journal, atomic dual-image commit, power-loss consistency |
| Physical block storage | **65%** | in_progress | PCI VirtIO Block discovery, feature negotiation, DMA virtqueue, synchronous read/write/flush | Interrupt/MSI-X, multi-queue, timeouts/reset, hardware coverage |
| KVDI / VirtIO transport | **65%** | in_progress | Transport layer, PCI capabilities/BAR validation, virtqueue, containment/quarantine, fault injection | Async completion, multi-device/queue, more device classes |
| Networking | **10%** | scaffolding | VirtIO-net identifiers/features and module scaffolding | Driver, Ethernet/ARP/IP/UDP/TCP, sockets, service |
| Graphics / compositor | **60%** | in_progress | Rasterizer, framebuffer bridge, window manager, damage tracking, surface presentation | GPU acceleration, isolated compositor service, display modes/hotplug |
| Input | **40%** | in_progress | PS/2 keyboard decode, event queue, pointer motion, input syscalls with capability checks | Mouse/HID/USB, hotplug, keymaps, input service |
| Desktop / windowing UX | **35%** | in_progress | Managed desktop scene, window handles, focus/input routing, boot graphics demo | Taskbar, launcher, shell, terminal, file manager, settings, session model |
| Linux binary compatibility | **0%** | not_started | No implementation | Linux process ABI, syscall translation, signals/futex/TLS, dynamic linker |
| Windows binary compatibility | **0%** | not_started | No implementation | PE32+ loader, Win64 ABI, NT/Win32, DLL/TLS/unwind |
| Security hardening | **45%** | in_progress | Ring 3, page permissions, NX/W^X, capabilities, device containment, bus-master revocation | SMEP/SMAP policy, ASLR/KASLR, threat models, fuzzing, audit |
| Tests / validation infrastructure | **65%** | in_progress | 21 host artifacts (661 tests) in `zig build test`; QEMU boot/storage/interactive scripts with 117 marker/pattern assertions; framebuffer/presentation comparison scripts | No CI, no recorded QEMU result, 8 unreachable files, no fuzzing, no hardware matrix |
| Performance / observability | **40%** | in_progress | Scheduler/syscall/graphics counters, TSC timing, boot-time framebuffer benchmark, serial diagnostics | Benchmark source not in the build graph; no baselines/percentiles/thresholds |
| Build / developer tooling | **60%** | in_progress | Zig 0.17.0 build graph (boot, kernel, 2 apps, image, 21 host-test artifacts, QEMU steps), `fatimg --version`, `bin2zig`, single version source (`version.zig`) mirrored in the manifest and guarded by a test, zero external deps | No CI; toolchain installed by hand; no reproducible-artifact story |

## Implemented foundations

Present in the source tree; this does not imply completeness or runtime
validation:

- UEFI boot application and the versioned KNB→KNK handoff
  (`docs/specs/boot-handoff-spec.md`).
- Freestanding x86-64 kernel; Assembly entry, context-switch, interrupt and
  syscall paths.
- CPU, interrupt, timer, ACPI, PCI, APIC and early SMP code.
- PMM, heap, four-level paging, per-process address spaces and DMA support.
- User-mode tasks, native syscall dispatch
  (`docs/specs/syscall-abi.md`), IPC channels and capabilities.
- ELF64 parsing/loading/materialization, KEX container, KPK codec.
- RamFS, KFSX mount namespace, KNV volume codec, block layer.
- KVDI transport and a synchronous VirtIO Block request path.
- Rasterization, framebuffer presentation, compositor, window manager, PS/2
  input and a boot-time desktop scene.
- Host unit tests (661) and QEMU integration scripts.

## Important limitations and corrections

1. **SMP is not complete.** AP startup code exists and is invoked, but APs do not
   run the normal scheduler workload. Do not describe Kynox as a fully SMP
   operating system.
2. **The active VirtIO Block path is KVDI** (`kernel/drivers/kvdi/block.zig`),
   used by `kernel/main.zig`. `kernel/arch/x86_64/virtio_blk.zig` is a legacy
   stub that unconditionally returns `NotImplemented` and is referenced only by
   the test root; it is not the active driver (removal decided in ADR-0003).
3. **ACPI/MADT discovery runs, but the I/O APIC is not programmed.**
   `discoverAcpi` in `kernel/main.zig` reads the MADT through the RSDP before
   the kernel page tables replace the firmware identity map, validates the
   local APIC address and installs it with `apic.setBase`; an unusable table
   leaves the documented default `0xFEE00000` in place and logs why. The I/O
   APIC entries and interrupt source overrides are parsed, validated and
   recorded, but no redirection-table entry is written and the overrides do
   not change routing yet (audit A-03, resolved in part). No QEMU or hardware
   run has validated the path.
4. **VirtIO Block uses synchronous polling.** No interrupt/MSI-X completion,
   no multi-queue, no asynchronous I/O.
5. **Persistence has bounded evidence.** KNV commit/recover code and a two-boot
   raw block probe exist; neither is a journaled, power-loss-safe filesystem,
   and the probe has not been executed in this snapshot.
6. **KFSX is not a complete VFS.** It routes RamFS volumes; multiple mature
   on-disk backends are not supported.
7. **ELF/KEX is not Linux compatibility.** KEX wraps an ELF64 payload for
   Kynox; Linux ABI compatibility is 0%.
8. **Windows compatibility is 0%.** No PE32+/Win64/NT/Win32 environment exists.
9. **The system version is centralized but the release gate is not met.**
   `version.zig` is the only source (`0.1.0-alpha.1`), the manifest mirrors it
   and a test fails on divergence; that closes audit A-01, it does not make the
   tree releasable.
10. **The ABI has one revision now, and it is still unstable.** Revision 1 is
    declared in `shared/syscall_abi.zig`, aliased by the kernel and the SDK and
    checked by `abi-conformance-tests`, but the door has never run in a VM and
    a future revision may still change semantics. Audit A-04 is closed only for
    the *inconsistency*, not for stability.
11. **No CI and no recorded QEMU result.** Every runtime statement about the
    built image is unverified.
12. **The `check` target excludes the interactive QEMU test.** It runs unit,
    boot and storage steps; `zig build qemu-interactive-test` is separate.
13. **Eight files are unreachable** from any build target or script (audit
    A-13); `tools/benchmarks/syscall_bench.zig` is not built, so no syscall
    benchmark can be run today.
14. Only **two** native applications are built into the image
    (`user/hello.zig`, `user/client.zig`); the files under `tests/user_apps/`
    are not part of the build.

## Next priorities

Taken from the audit plan (see the audit for evidence and scope):

1. Record the exact toolchain and QEMU/OVMF prerequisites in `docs/BUILD.md`
   (done) and make the build claim machine-verifiable (**CI still missing**).
2. ~~Unify the project version and expose the ABI revision from the kernel~~ —
   done: `version.zig`, `shared/syscall_abi.zig`, `version-tests` and
   `abi-conformance-tests`.
3. Execute and record `qemu-test`, `qemu-storage-test` and
   `qemu-interactive-test` on a QEMU-capable machine; fix what they reveal.
   The procedure and the failed attempt are in `docs/validation/qemu.md`;
   **no run has succeeded**.
4. ~~Wire ACPI/MADT discovery into LAPIC/IOAPIC initialization~~ — done for the
   LAPIC base, the IOAPIC list and the overrides; **IOAPIC programming and
   routing remain**.
5. ~~Decide the fate of the legacy `virtio_blk.zig` stub and of the parallel
   `arch/x86_64/virtio.zig` queue code~~ — decided in ADR-0002 and ADR-0003
   (`docs/decisions/`); the code changes are pending.
6. Extract boot-time probes from `kernel/main.zig` into a diagnostics module
   (ADR-0001: accepted, deferred until a boot can be compared before/after).
7. Complete SMP scheduler integration, then VMM regions/TLB shootdown.
8. Strengthen native KEX/ELF ABI, linker and SDK before any compatibility
   personality.
9. Define Linux compatibility as an isolated personality starting from a small
   static ELF64 matrix; Windows as a separate PE32+/Win64 personality.
10. Expand VFS and durable storage (journal/atomic commit) with recovery tests.

## Updating this status

1. Update `PROJECT_STATUS.json` (schema v2) and this file in the same change as
   the code/documentation that changes reality.
2. Keep subsystem `id` values stable; never renumber or repurpose syscall
   numbers, handoff fields or status values.
3. Raise a percentage only when scoped behavior is integrated **and** supported
   by executed evidence. Test code, new files and new TODOs are not evidence.
4. Record the exact command, environment and result under `validation`; use
   `not_executed` when a test was not run.
5. Keep `README.md`, `CHANGELOG.md` and the release notes consistent with this
   file.
