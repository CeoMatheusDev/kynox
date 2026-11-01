# ADR-0006 · Compositor and window manager as a user-space service

- Status: **accepted for planning**. The current compositor runs in the kernel.
- Date: 2026-10-31.
- Related: [`graphics-platform.md`](../architecture/graphics-platform.md) §9,
  [`platform-architecture.md`](../architecture/platform-architecture.md) §3,
  [`security-architecture.md`](../architecture/security-architecture.md) §8.

## Context

Kynox today composites inside the kernel (`kernel/graphics/compositor.zig`,
`window_manager.zig`, `damage.zig`, `framebuffer_bridge.zig`). That was the right
choice for a system without a scheduler-driven user-space service model: it made
the boot demo possible and kept the frame path simple.

A real desktop needs compositing policy that changes weekly (animations, effects,
layouts, HDR tone mapping, accessibility) next to a display contract that must be
stable and minimal. Keeping policy in the kernel means every visual change
touches privileged code, a compositor bug panics the machine, and third parties
cannot extend the desktop.

## Options

**A. Keep compositing in the kernel.**
Fastest path for the current demo; no crash isolation; every effect is kernel
code. Rejected as the long-term architecture.

**B. Compositor in user space, display control in the kernel (chosen).**
The kernel owns connectors, modes, planes, scanout and fences; the compositor
owns the scene, the client protocol, input routing, effects and colour policy.
This is the split used by every mainstream desktop (DRM/KMS + compositor,
Dxgkrnl + DWM) `[S9][S10]`.

**C. A single privileged display server that also drives the hardware.**
Keeps compositing and CRTC programming in one process. Simpler for a monolithic
server, but requires the server to hold raw MMIO/display capabilities and
reintroduces the trust concentration the capability model is meant to avoid.

## Decision

Adopt **B**:

1. **KDS-K** (kernel) exposes connectors, CRTCs, planes, framebuffers, atomic
   commit, page flips with fences, VRR/HDR metadata and hotplug events. It never
   decides layout or colour policy.
2. **KWM** (user space) implements the scene graph, the client protocol
   (surface/buffer/damage/frame callback), input routing and the presentation
   policy, submitting commits to KDS.
3. **Direct scanout** is a KWM decision expressed as a KDS commit; the kernel
   validates and enforces it.
4. **Recovery:** if KWM dies, the supervisor restarts it; KDS keeps the last
   committed framebuffer so the screen freezes instead of going black.
5. **Migration path:** the existing in-kernel compositor remains as a boot-time
   fallback until KWM is functional; it is not removed before KWM passes the
   session tests.

## Consequences

- Positive: visual policy evolves without kernel changes; a compositor bug is a
  service crash; third parties can implement alternative compositors on the same
  protocol; the kernel's trusted code shrinks.
- Negative: one more IPC hop for input and presentation; shared-memory management
  must be solid before the move; the session must handle compositor restart.
- Neutral: the current in-kernel compositor becomes a fallback and test oracle.

## Risks

| Risk | Mitigation |
|---|---|
| IPC latency hurts input-to-photon | Shared-memory rings, direct scanout, measured budgets |
| Compositor restart loses client buffers | Clients receive `compositor_lost`; protocol defines re-attach |
| Kernel display interface becomes policy | KDS accepts only declarative commits; no layout semantics |
| Two compositors (kernel fallback + KWM) diverge | Fallback is frozen and used only for recovery/bring-up |

## Reversal criteria

If measurements show the user-space compositor cannot meet the input-to-photon
budget on the reference hardware after the first optimisation pass, keep the
protocol and move only the presentation loop back into a privileged service —
not into the kernel — documenting the exception. Restoring full in-kernel
compositing requires a new ADR.
