# ADR-0003 · Fate of the legacy `virtio_blk.zig` stub

- Status: **accepted**; deletion deferred to a separate change
- Date: 2026-10-31
- Related: ADR-0002, audit finding A-07

## Context

`kernel/arch/x86_64/virtio_blk.zig` (124 lines) declares two functions,
`blk_read()` and `blk_write()`, whose whole body is `return error.NotImplemented`.
It has no LBA argument, no buffer and no sector count, so it is not a block
interface at all. Four tests in the file assert that the functions keep
returning the error — the guard exists because an empty `!void` body in Zig
returns success, and an empty stub would silently publish a completed I/O.

Reference check (zero inbound references, excluding the file itself):

| Referrer | Kind |
|---|---|
| `kernel/arch/x86_64/root.zig:46` | test root import, so its tests run |
| `kernel/arch/x86_64/root.zig` (pub const) | none — the module is not exported |
| `kernel/main.zig` | none |
| `build.zig` | none |
| scripts, docs | narrative only (README, PROJECT_STATUS, this ADR) |

The active block path is `kernel/drivers/kvdi/block.zig`, integrated through
`kernel/main.zig`, with `block.Error`, DMA buffers and a synchronous request
loop. Its interface is the one callers should use.

The four tests protect against a real hazard (a stub that reports success), but
they protect nothing that exists: nobody calls the stub.

## Options

**A. Keep it as a documented stub.** Cost: a file whose existence suggests a
second block driver; a reader must read the ADR and the module doc to learn it
is inert. It also creates a permanent temptation to "fill it in" outside KVDI.

**B. Delete the file and its import.** Removes 124 lines and 4 tests. The hazard
it guards against — a placeholder that reports success — is not something a
deleted file can do.

**C. Turn it into a thin compatibility shim over KVDI.** No caller exists, so a
shim would be a third interface with no users. Rejected.

## Decision

Option **B**, executed as its own commit:

1. Delete `kernel/arch/x86_64/virtio_blk.zig`.
2. Remove the import from `kernel/arch/x86_64/root.zig`; the arch test count
   drops by the four tests (from 112 to 108) and that is expected, not a
   regression — the behavior under test no longer exists.
3. Remove the narrative references in `README.md`, `docs/PROJECT_STATUS.md`
   and the audit's "pending" list, replacing them with a statement that there is
   exactly one block driver (KVDI).
4. Keep the *lesson* in `kvdi/block.zig`: its error set is explicit and its
   tests already refuse silent success, which is the part worth preserving.

The deletion is **not** performed by this ADR. It is deferred because:

- the current phase forbids deleting implementations before an independent
  confirmation that they are unused, and this ADR is that confirmation only in
  written form;
- the change is trivial to review later and gains nothing from being bundled
  with the ACPI/ABI work;
- if the decision turns out to be wrong, the revert is a single commit.

## Consequences

- Positive: one block driver, no misleading file, no permanent test of inert
  code.
- Negative: a reviewer who came to expect the stub in the tree has to read this
  ADR. The test count reported in documentation decreases by four.
- Neutral: nothing in the boot path changes; the image is byte-identical except
  for debug information.

## Risks

| Risk | Mitigation |
|---|---|
| Some external (out-of-tree) consumer imports the module | The module is not exported from any root and its signatures cannot perform I/O; a real consumer would gain nothing. Search of the tree is recorded above |
| Losing the "no silent success" guard | `kvdi/block.zig` has the functional equivalent; the ADR text preserves the reasoning |
| Deletion done together with a behavior change | Forbidden by the plan: pure deletion commit, `zig build` + `zig build test` before and after |

## Reversal criteria

If any consumer appears before deletion (a new import outside the test root), do
not delete: the module must then either be implemented over KVDI or reclassified
as a deliberate part of the public kernel API with an ADR of its own.
