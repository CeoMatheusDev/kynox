# ADR-0004 · Graphics stack split: minimal kernel core, vendor drivers in user space

- Status: **accepted for planning**. No code implements this split yet.
  Updated 2026-10-31: the driver-facing contract is the KGX backend IR
  (ADR-0008/0009), not KGA commands.
- Date: 2026-10-31.
- Related: [`graphics-platform.md`](../architecture/graphics-platform.md) §5–6,
  [`security-architecture.md`](../architecture/security-architecture.md) §6,
  [`market-landscape.md`](../strategy/market-landscape.md) §3.3.

## Context

A graphics stack must choose where vendor-specific device code runs. The market
offers two established models:

- **In-kernel drivers** (Linux DRM, Windows WDDM kernel-mode miniport): maximum
  performance and simple memory management, but vendor code — often large,
  closed and buggy — runs in the most privileged ring. WDDM pairs it with a
  user-mode driver for command generation `[S9][S10]`.
- **User-space drivers** (Fuchsia-style, and the direction of several
  microkernel projects): strong isolation, but requires IOMMU, interrupt
  delegation, shared memory and a fast IPC path; without an IOMMU the device can
  DMA over kernel memory regardless of where the driver runs.

Kynox has none of these mechanisms today: no IOMMU support, no user-space
driver host, no interrupt delegation and no GPU core. It does have capabilities,
IPC channels, separate address spaces and a working VirtIO block path — enough
to build toward a user-space driver host, but not yet enough to *require* one.

## Options

**A. All drivers in the kernel.**
Simple and fast; contradicts the project's direction of moving drivers out of
Ring 0 and makes every vendor driver part of the trusted base. Rejected as a
long-term target, acceptable only as a documented fallback.

**B. All drivers in user space, unconditionally.**
Strongest isolation, but without IOMMU the isolation is illusory: a user-space
driver with MMIO access can program DMA to any physical address. Requiring it
would exclude most current hardware and delay all graphics work.

**C. Tiered split (chosen).**
Kernel owns memory, submission, fences and reset; vendor code runs in user space
when an IOMMU domain can be attached, and in the kernel behind the same narrow
interface otherwise. The interface is identical in both cases; only the trust
boundary changes, and the support matrix publishes which tier each device is in.

## Decision

Adopt **C**.

1. **Kernel graphics core (KGC)** implements: GPU memory objects and heaps,
   per-process GPU address spaces, command rings/queues, submission, fences and
   timelines, hang detection, context/device reset, and power transitions.
2. **KDS-K** implements display control: connectors, CRTCs, planes, modes,
   atomic commit, page flips with fences, VRR/HDR metadata, hotplug, DPMS.
3. **Vendor drivers** implement register programming, command generation,
   backend-IR to machine-ISA lowering and memory placement (ADR-0009).
   They receive:
   - an MMIO window capability (never raw physical access),
   - an interrupt capability,
   - GPU object handles,
   - a submission interface with validation.
4. **Trust tiers:** user-space driver when an IOMMU domain exists; in-kernel
   driver otherwise. Both use the same interface; the difference is documented
   per device.
5. **Validation** is layered: structural in the kernel, semantic in development
   builds (see graphics doc §6.6).

## Consequences

- Positive: a single interface for both tiers; vendor code does not grow the
  trusted base on IOMMU-capable systems; resets and recovery live in one place;
  the support matrix becomes honest.
- Negative: two execution paths to test (user and kernel driver hosts); IPC
  overhead for submission on the user-space path; more kernel work before the
  first driver runs.
- Neutral: the first driver target is virtio-gpu, which is simple enough to
  validate the interface before a real vendor driver exists.

## Risks

| Risk | Mitigation |
|---|---|
| IPC overhead makes submission slow | Measure per-submission CPU cost; batch; shared-memory rings |
| No IOMMU on target hardware | In-kernel tier with the same narrow interface, published limitation |
| Two paths diverge | The driver interface is the contract; conformance tests run against both hosts |
| Reset semantics differ by vendor | Reset is owned by KGC; vendor hooks are optional and bounded |

## Reversal criteria

If measurement shows the user-space host cannot meet the submission CPU budget
on reference hardware, keep the interface but move the driver back into the
kernel for that device class, documenting the exception. If, on the contrary,
IOMMU support proves universal on supported hardware, make the user-space tier
mandatory and delete the in-kernel path.
