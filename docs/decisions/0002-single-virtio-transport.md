# ADR-0002 · One VirtIO implementation: KVDI owns the transport

- Status: **accepted**; steps 1 and 2 executed on 2026-10-31, step 3 pending
- Date: 2026-10-31
- Related: audit findings A-06/A-07; `docs/specs/` has no VirtIO spec yet

## Context

The tree carries three VirtIO-related code paths:

| Path | Lines | Used by | What it does |
|---|---:|---|---|
| `kernel/drivers/kvdi/*` | ~8,600 | `kernel/main.zig` (`bringUpVirtioDevices`, `verifyVirtioBlockPersistenceProbe`) | active block driver: PCI transport, MMIO BAR mapping, features, split virtqueue in DMA memory, synchronous I/O, persistence probe |
| `kernel/arch/x86_64/virtio.zig` | 852 | `kernel/main.zig::probeVirtqueueLayout` (a self-test that programs no device) and `virtio_net.zig` | second split-virtqueue implementation: legacy `VRing` helpers, `DeviceQueue`, a hardcoded `pci_virtio_base = 0xFE000000`, `detectVirtioDevice` |
| `kernel/arch/x86_64/virtio_blk.zig` | 124 | only `kernel/arch/x86_64/root.zig` (test root) | legacy stub whose functions always return `error.NotImplemented`; see ADR-0003 |

`virtio.zig` and `kvdi/virtqueue.zig` implement the same device-visible
structure twice. The legacy copy is the one the boot self-test exercises, so the
serial line `virtio: split queue layout ok` proves the *legacy* layout, not the
one KVDI actually uses with the device. That is misleading evidence, not just
dead weight.

`virtio_net.zig` is imported only by the arch test root and has no consumer in
the boot path; it is a scaffold, not a driver.

## Options

**A. Keep both.** Cost: two implementations of a device-visible structure, one
of which is validated by a boot marker the other does not earn.

**B. Make KVDI the only implementation.**
- Move the legacy layout arithmetic tests to `kvdi/virtqueue.zig` (they are
  useful; the *implementation* is what should not exist twice).
- Change `probeVirtqueueLayout` to exercise `kvdi.virtqueue` instead of
  `virtio.DeviceQueue`, keeping the marker text.
- Delete `virtio.zig`'s queue helpers (`VRing`, `DeviceQueue`, `QueueLayout`,
  `splitQueueLayout`, `deviceAddresses`, `popUsed`, `initVRing`).
- Move or delete `virtio_net.zig`; if the network scaffold is kept, it must
  depend on KVDI's virtqueue, not on a second one.

**C. Make the legacy module the shared one and rewrite KVDI on top of it.**
Rejected: KVDI is the integrated, tested path with DMA, feature negotiation and
containment; the legacy module programs no device.

## Decision

Option **B**, in three separate changes, each reversible:

1. Add host tests in `kvdi/virtqueue.zig` for every layout property currently
   tested in `virtio.zig` (descriptor table, available ring, used ring offsets,
   alignment, wrap-around), so the coverage survives independent of the file.
2. Repoint `probeVirtqueueLayout` to `kvdi.virtqueue` and keep the marker.
3. Delete the duplicated queue code from `virtio.zig`; whatever remains
   (`detectVirtioDevice`, `BlockFeatures`, `NetFeatures`) either moves to KVDI
   or disappears with its last caller. `virtio_net.zig` follows.

No deletion happens in this decision record; the changes above are separate
commits with their own validation.

## Execution record (2026-10-31)

- **Step 1 — done.** `kernel/drivers/kvdi/virtqueue.zig` already carried the
  layout tests (`the split layout follows the specification offsets and
  alignment`, `the physical addresses of the three areas are the layout
  offsets`, rejection cases). Nothing had to be copied from `virtio.zig`: the
  coverage was written against KVDI, which is stronger than moving it.
- **Step 2 — done.** `kernel/main.zig::probeVirtqueueLayout` now builds a
  `kvdi.virtqueue.Queue(16)` over the same static buffer and publishes one
  descriptor. The marker text is unchanged (`[KNK] virtio: split queue layout
  ok`), the numbers are the KVDI layout: `desc=0 avail=256 used=304 size=448`.
  The previous numbers (`avail=4096 used=8192 size=12288`) were the legacy
  page-aligned layout, which the driver never programmed — the exact misleading
  evidence this ADR was filed about. `tests/integration/log-assertions-test.sh`
  was updated to the new values; `tests/integration/boot-qemu.sh` asserts only
  the prefix and is unaffected.
- **Step 3 — pending.** `virtio.zig` still exports `VRing`/`DeviceQueue` and
  `virtio_net.zig` still consumes them; no boot path does. Deletion is a
  separate change because it removes three test-visible modules at once and
  cannot be validated by a boot in this environment. `kernel/main.zig` no
  longer imports the legacy module, so the boot path is already KVDI-only.

## Consequences

- Positive: one device-visible structure, one place to fix a virtqueue bug; the
  boot marker starts proving the structure the driver really uses.
- Negative: KVDI's module gains the layout tests (it grows); the legacy module
  disappears, so any external user of it breaks — there is none in the tree.
- Neutral: `virtio.zig`'s `0xFE000000` constant disappears with it; nothing in
  the boot path used it.

## Risks

| Risk | Mitigation |
|---|---|
| KVDI virtqueue and legacy queue disagree on an offset and the marker was hiding it | Step 1 adds the offset tests against KVDI **before** the probe is repointed; a difference shows up as a failing host test |
| The probe stops exercising a code path that was load-bearing | Call-graph check first; the probe only writes to a static buffer and reads back indices |
| `virtio_net.zig` is someone's next task | It is imported by the test root only; the ADR is recorded and the deletion is a separate commit, easy to revert |

### Reversal criteria

If `kvdi/virtqueue.zig` cannot absorb the layout tests without importing the
legacy module, stop: that would mean the two are not equivalent and the
duplication is structural, not accidental. In that case the legacy module gets a
stated owner and a documented purpose instead of deletion.

### Does this contradict "never replace own implementations with external libraries"?

No. Both implementations are Kynox's own code; the decision removes a
duplicate, not a dependency.
