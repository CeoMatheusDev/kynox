# ADR-0005 · Native graphics API: one explicit core with optional higher layers

- Status: **accepted for planning**; API revision 1 is not implemented.
  One clause ("drivers see KGA") is **superseded in part** by
  [ADR-0008](0008-shared-graphics-core.md) and
  [ADR-0009](0009-spirv-ingestion.md): drivers see the KGX backend IR,
  and KGA is one of three front-ends. Everything else stands.
- Date: 2026-10-31.
- Related: [`graphics-platform.md`](../architecture/graphics-platform.md) §7,
  [`market-landscape.md`](../strategy/market-landscape.md) §3.2.

## Context

Kynox needs a native graphics API that serves games, engines, desktop
applications, CAD, scientific visualisation and GPU compute. Three families of
answer exist in the market:

- **Vulkan** — explicit, cross-vendor, extension-heavy; 1.4 (December 2024)
  consolidated many optional features into the core `[S1]`.
- **Direct3D 12 / Metal** — explicit, vendor/OS-integrated, with strong tooling;
  Metal 4 (June 2025) added a unified encoder model and tensor support `[S2][S3]`.
- **Higher-level APIs** (OpenGL, WebGPU) — easier, but hide the control engines
  need.

Kynox has no graphics API today; the software rasteriser has its own internal
interface. The decision must therefore be made before any renderer or driver
work.

## Options

**A. Adopt Vulkan as the native API.**
Maximum ecosystem reach and tooling reuse; but it makes Kynox's ABI depend on an
external specification's evolution, inherits decades of extensions and the
platform-specific WSI split, and gives up the freedom a new system has to
simplify.

**B. Design a minimal explicit API and grow it.**
Owns the contract, can remove legacy concepts (render passes, layouts), can make
capability tiers first-class. Cost: no existing ecosystem, tooling must be built.

**C. Start with a high-level API and expose a low-level one later.**
Easiest for application developers, but low-level control cannot be retrofitted
without breaking the high-level contract; engines need explicit resources from
day one.

## Decision

Adopt **B**, with two layers delivered together but developed in order:

1. **KGA** — low-level, explicit: devices, queues, command buffers, pipelines,
   descriptor sets, images/buffers, fences and timeline semaphores. Dynamic
   rendering (no render-pass objects), explicit synchronisation, per-process GPU
   address spaces, capability queries.
2. **KGA-H / KGA-UI** — optional layers: render graph with automatic barriers and
   transient allocation, default PBR/HDR pipelines, and a 2D/UI layer for desktop
   applications.

The low-level API is the only contract that hardware drivers see. The higher
layers are libraries on top and may change faster.

> **Superseded in part (2026-10-31).** With the compatibility work, Kynox adopted
> a shared execution core (KGX) behind three front-ends (ADR-0008) and SPIR-V
> ingestion lowered to a backend IR (ADR-0009). Vendor drivers therefore see the
> **backend IR**, not KGA commands. KGA remains the native API and the reference
> for what the core must express; it is no longer the driver-facing contract.
> The rest of this decision — one explicit low-level API plus optional higher
> layers — is unchanged.

Additionally:

- **Shader input:** adopting SPIR-V as an *input* format is a separate decision
  (a follow-up ADR) because it affects tooling, validation and compiler scope;
  KGA itself does not mandate a source language. **Decided in ADR-0009:**
  SPIR-V is the canonical ingestion format, lowered to a backend IR.
- **Versioning:** KGA has a revision number; extensions are opt-in and
  enumerated; nothing is removed within a major revision without a deprecation
  window.

## Consequences

- Positive: the API fits Kynox's security model (validation, per-process GPU
  memory), avoids legacy concepts, and leaves room for a simpler mental model
  than Vulkan.
- Negative: no existing engine support; the SDK must provide wrappers and
  documentation; tooling (validator, capture) must be written.
- Neutral: Vulkan/D3D12/Metal are references, not dependencies; their concepts
  are re-used where they are proven (pipelines, descriptor sets, fences).

## Risks

| Risk | Mitigation |
|---|---|
| API diverges from what engines need | Build an engine-style sample early; iterate before stabilising |
| Scope creep into a full Vulkan clone | Ship a minimal core (2D, textures, one queue) first; grow by capability tier |
| Shader toolchain underestimated | Decide SPIR-V input early; start with a small shader subset |
| Tooling absence kills adoption | Validator and capture are part of the first release, not a later phase |

## Reversal criteria

If, after the first engine integration, the API cannot express a required
workload without ad-hoc extensions, stop and reassess: either adopt Vulkan as the
native API and keep KGA as an internal layer, or revise the object model before
declaring revision 1 stable.
