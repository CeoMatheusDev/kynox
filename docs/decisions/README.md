# Architecture decision records

One file per decision with broad impact, as required by `strategy.md` §5
(context, options, decision, consequences, risks, migration plan and reversal
criteria). Numbering is sequential and never reused; a superseded record stays
in the tree with its status updated.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-boot-probes-out-of-kernel-main.md) | Extract boot-time probes and reports out of `kernel/main.zig` | accepted, first probe extracted, rest deferred |
| [0002](0002-single-virtio-transport.md) | One VirtIO implementation: KVDI owns the transport | accepted, steps 1–2 executed, step 3 pending |
| [0003](0003-legacy-virtio-blk-stub.md) | Fate of the legacy `virtio_blk.zig` stub | accepted, deletion deferred |

An accepted ADR records a decision, not a change: until the code moves, the
tree behaves exactly as before and the ADR says so. ADR-0001 and ADR-0002 are partially
executed; each has an execution record listing what moved and what did not.
