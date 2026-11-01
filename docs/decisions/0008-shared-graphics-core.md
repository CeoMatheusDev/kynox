# ADR-0008 · One shared graphics execution core behind KGA, KGL and KVK

- Status: **accepted for planning**. No code implements it.
- Date: 2026-10-31.
- Related: [`graphics-compatibility.md`](../architecture/graphics-compatibility.md) §1, §3, §6,
  [`graphics-platform.md`](../architecture/graphics-platform.md) §3, §7,
  ADR-[0005](0005-native-graphics-api.md).

## Context

Kynox needs three graphics surfaces: a native API (KGA), OpenGL compatibility
(KGL) and Vulkan compatibility (KVK). Two structures are possible:

1. Each API implemented independently, each talking to the kernel graphics core.
2. All APIs translated onto KGA, which becomes the single internal interface.
3. A shared internal execution core (KGX) that is not any of the APIs, with each
   API as a front-end over it.

Option 2 is the intuitive one, and it fails in a specific way: Vulkan's
guarantees — concurrent queue ownership, explicit memory types, timeline
semaphores, render-pass load/store semantics, descriptor indexing — would have to
be expressed in KGA's object model. Either KGA grows those semantics (becoming
Vulkan with another name) or the translation approximates them (breaking
applications silently). OpenGL adds a second direction: implicit state and
implicit synchronisation that KGA deliberately does not have.

## Options

**A. Independent implementations per API.**
Maximum fidelity per API, but triplicates shader compilation, descriptor
lowering, memory layout, validation, caching and the submission encoder — and
triplicates the bugs.

**B. Everything translates to KGA.**
One surface for drivers, small kernel contract. Rejected: it forces KGA to carry
Vulkan semantics while claiming not to, and makes OpenGL's implicit behaviour an
ever-growing set of KGA extensions.

**C. Shared core, per-API front-ends (chosen).**
KGX owns mechanisms shared by all three (resources, pipelines, descriptors,
shader ingestion, validation, caches); each front-end owns its API's semantics
and emulates locally what the core cannot express, with a published deviation
table.

## Decision

Adopt **C**.

1. **KGX** is specified from the union of the three APIs' required semantics, not
   from KGA's current feature set.
2. **KGA** is one front-end among three; it is not the internal interface.
3. A semantic KGX cannot express is emulated in the front-end that needs it and
   documented as a deviation; the core never silently weakens a guarantee.
4. **KGC** remains the only component touching hardware; all three front-ends
   submit through it.
5. Every front-end publishes a **conformance matrix and a deviation table**;
   `VkPhysicalDeviceProperties`, GL version strings and KGA capability queries
   report what is actually implemented.

## Consequences

- Positive: one implementation of the expensive shared parts; per-API fidelity;
  one place to optimise and test; tools (validator, capture) attach once.
- Negative: KGX must be designed before KVK can be honest, which delays KVK
  slightly compared with a direct KGA translation; the core's surface is larger
  than KGA's.
- Neutral: the kernel contract (KGC) does not change because of compatibility.

## Risks

| Risk | Mitigation |
|---|---|
| KGX becomes a lowest common denominator | union-of-semantics rule; deviations live in front-ends |
| KGX balloons into a fourth API | object model limited to what KGC can execute; no API-specific sugar |
| Front-ends duplicate work anyway | shared encoders and caches are mandatory; duplication requires a review note |
| Performance lost in an extra layer | measured per-path budgets; direct submission path for KGA |

## Reversal criteria

If after KVK 1.3 the shared core cannot express a required Vulkan guarantee
without emulation that costs more than 10% of frame time in the reference
workload, split the KVK path into its own encoder while keeping shared caches —
documenting which parts of KGX remain common. A return to "everything through
KGA" is not an option.
