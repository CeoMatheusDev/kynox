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
| [0004](0004-graphics-stack-split.md) | Graphics stack split: minimal kernel core, vendor drivers in user space | accepted for planning |
| [0005](0005-native-graphics-api.md) | Native graphics API: one explicit core with optional higher layers | accepted for planning |
| [0006](0006-userspace-compositor.md) | Compositor and window manager as a user-space service | accepted for planning |
| [0007](0007-packaging-sandbox-updates.md) | Packaging, sandbox and updates: one signed format, one broker, atomic rollback | accepted for planning |

An accepted ADR records a decision, not a change: until the code moves, the
tree behaves exactly as before and the ADR says so. ADR-0001 and ADR-0002 are partially
executed; each has an execution record listing what moved and what did not.

"Accepted for planning" (ADR-0004…0007) means the decision constrains the design
documents and the roadmap, and **nothing in the tree implements it yet**. They
carry reversal criteria so that measurement, not preference, can overturn them.
