# ADR-0001 · Extract boot-time probes and reports out of `kernel/main.zig`

- Status: **accepted**, first probe extracted on 2026-10-31; the rest is still deferred
- Date: 2026-10-31
- Related: audit finding A-09; `strategy.md` §3.2 (module boundaries) and §5

## Context

`kernel/main.zig` is 4,865 lines. It contains the entry point, the boot
sequence, and roughly forty functions that are not part of the boot sequence:
probes (`probeDmaWindow`, `probeVirtqueueLayout`, `probePciBus`,
`probeFramebuffer`, `benchmarkFramebufferWrites`, `selfTest`), verifications
(`verifyFsLifecycleProbe`, `verifyVirtioBlockPersistenceProbe`) and reporters
(`reportProcessor`, `reportMemory`, `reportScheduler`, `reportUserTask`, …).

Two problems follow from that:

1. **No test boundary.** Everything in the file can only be exercised by booting
   the kernel. The logic that a probe encodes (layout arithmetic, expected
   offsets, marker strings) is invisible to `zig build test`.
2. **Boot sequence readability.** The order of initialization — the part that
   matters for correctness — is interleaved with demonstration code. A reader
   cannot tell which call is required for the system to work and which exists
   to prove something on the serial console.

The file also holds the deliberate serial contract of about 117 assertions used
by `tests/integration/boot-qemu.sh`; moving code must not move or rename a
marker.

## Options

**A. Leave the file as it is.** No risk today; the file grows with every
feature and the test boundary never appears.

**B. Move all probes into a new `kernel/diagnostics/` module and keep the
call order in `main.zig`.** The boot sequence stays readable, probes become
separately compilable, and the markers can be asserted in host tests by calling
the probe against a fake writer.

**C. Split `main.zig` by boot phase** (`boot/`, `init/`, `probes/`,
`reports/`). Cleaner on paper, but a large simultaneous refactor of the most
fragile file in the tree, at a moment when no QEMU run can validate it.

**D. Merge the probes into the modules they prove** (`paging` probe into
`paging.zig`, and so on). Tempting, but it puts demonstration code inside
production modules and makes the modules depend on the serial console.

## Decision

Option **B**, executed incrementally:

1. First, a `kernel/diagnostics/writer.zig` abstraction: an interface with
   `line(comptime fmt, args)` that the kernel implements over `serial` and the
   tests implement over a fixed buffer. No behavior change.
2. Then one probe per change, starting with the pure ones that need no device:
   `probeVirtqueueLayout` (layout arithmetic), then the DMA window probe, then
   the PCI scan probe. Each move keeps the exact marker text and the exact call
   position in the boot sequence.
3. Reports (`report*`) move last, into `kernel/diagnostics/report.zig`, because
   they read global state and are the least testable.
4. `kernel/main.zig` keeps: the entry point, the ordered initialization calls,
   `discoverAcpi`, `installSmp` and the other `install*` functions.

The `/KNK/`-prefixed strings are a contract with `boot-qemu.sh`; a probe that is
moved keeps the string byte for byte, and a host test asserts that the moved
probe emits it.

## Consequences

- Positive: probes become testable without hardware; `main.zig` shrinks to the
  sequence a reader needs; markers gain a host-level guard.
- Negative: one more indirection for the serial writer; a move can silently
  change boot order if done carelessly, which is why it is one probe at a time.
- Neutral: the file stays large until the last probe moves; there is no target
  line count, only a boundary.

## Risks

| Risk | Mitigation |
|---|---|
| A moved probe changes a serial marker | Host test asserts the exact string; `boot-qemu.sh` unchanged |
| A probe's side effect was load-bearing (e.g. mapping a page) | Each move starts with a call-graph check of the probe's callees; probes that touch hardware stay in place until their dependencies are extracted |
| The refactor hides a bug during a phase with no QEMU | No behavior change is allowed; each step is a pure move plus a test |

## Migration plan

Not scheduled. It is deliberately deferred until a QEMU-capable environment
exists, so the moves can be validated by a boot before and after. When it
starts, one probe per commit, with `zig build test` and a recorded boot on both
sides.

## Execution record (2026-10-31)

One probe moved, without changing boot order or marker text:

- `probeVirtqueueLayout` left `kernel/main.zig`. Its logic (build a
  `kvdi.virtqueue.Queue`, publish one descriptor, read the layout) is now
  `kernel/drivers/kvdi/virtqueue_probe.zig`, returning a `Result` value; the
  boot prints `prefix` plus `Result.format(&buffer)` at the same call site.
- The module does not write to the console, so the marker contract is tested on
  the host: `the rendered text is the serial marker asserted by the boot suite`
  and `the marker prefix is the one the integration scripts require` assert the
  exact strings, and `log-assertions-test.sh` asserts the full line.
- `boot_markers_conformance.zig` embeds the new file, because the marker prefix
  is now a literal there; without that line the guard reported the marker as
  lost (it did, and the failure is what proved the guard still works).

Why it did not go to `kernel/diagnostics/` as option B describes: a Zig module
root must sit above every file it imports, and the probe imports
`kvdi/virtqueue.zig`. A `kernel/diagnostics/` root cannot reach
`kernel/drivers/kvdi/` without a second module instance of the same file. The
probe therefore lives next to the code it proves, and moves to `diagnostics/`
when the kernel module itself is reorganized. That is the reversal criterion
firing in miniature: the boundary is a real constraint, not a preference.

The remaining probes and the `report*` functions stay where they are: moving
them cannot be validated by a boot here, which is the migration plan's own
condition.

## Reversal criteria

If the diagnostics module starts needing kernel globals to the point of
becoming a second `main.zig`, stop and keep the remaining probes in place. If a
moved probe cannot be tested on the host even with the writer abstraction, it
was not a probe but boot logic, and it should return to `main.zig`.
