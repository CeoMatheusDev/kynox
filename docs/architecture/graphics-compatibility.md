# Graphics compatibility: KGA, KGL, KVK and the shared execution core

- Status: **planning document**. Nothing here is implemented. Kynox exposes no
  graphics API, no OpenGL and no Vulkan today; the tree has a software
  rasteriser and an in-kernel compositor.
- Date: 2026-10-31.
- Related: [`graphics-platform.md`](graphics-platform.md) §3, §6–§7, §10,
  [`platform-architecture.md`](platform-architecture.md) §4.13,
  [`linux-compatibility.md`](linux-compatibility.md) §11,
  [`windows-compatibility.md`](windows-compatibility.md) §13,
  [`security-architecture.md`](security-architecture.md) §8,
  ADR-[0008](../decisions/0008-shared-graphics-core.md),
  ADR-[0009](../decisions/0009-spirv-ingestion.md),
  [`../roadmap/COMPATIBILITY_ROADMAP.md`](../roadmap/COMPATIBILITY_ROADMAP.md).

## 1. What this document decides

Kynox needs three graphics surfaces with different obligations:

1. **KGA** — the native API. The contract Kynox controls, optimises and can
   change on its own schedule.
2. **KGL** — OpenGL compatibility, so that existing OpenGL applications run
   without recompilation.
3. **KVK** — Vulkan compatibility, so that Vulkan applications and engines run
   without recompilation.

The central decision (ADR-0008) is that these three are **front-ends over one
shared execution core**, not three independent stacks and not "translations to
KGA". KGA is one client of that core, not the core itself. Making Vulkan a
translation onto KGA would force KGA to grow Vulkan's semantics anyway, while
hiding the places where the semantics differ — exactly the failure this
document exists to avoid.

The stack:

```text
  KGA (native)        KGL (OpenGL)          KVK (Vulkan)     front-ends, user space
       │                   │                     │
       └───────────────┬───┴─────────────────────┘
                       ▼
              KGX — shared execution core (user space)
        pipeline/state objects · descriptor model · resource layout
        shader ingestion (SPIR-V) → backend IR · validation · caches
                       │
                       ▼
              KGC — kernel graphics core
        memory objects · GPU address spaces · rings/queues · submission
        fences/timelines · hang detection · reset
                       │
                       ▼
              KDS — display system (kernel)      KWM — compositor (user space)
```

Each front-end owns **its API's semantics**; KGX owns the **mechanisms shared by
all three**; KGC owns **hardware-facing state and isolation**. A semantic that
KGX cannot express is implemented *in the front-end that needs it*, never by
distorting the shared core for everyone.

## 2. KGA — the native API, formalised

`graphics-platform.md` §7 defines KGA's goals and object sketch. This section
turns it into a contract.

### 2.1 Object model

| Object | Created by | Lifetime | Thread-safe |
|---|---|---|---|
| `Device` | Application, from a physical device handle | Explicit close; backed by a capability | Creation/destruction externally synchronised |
| `Queue` | Device | Device lifetime; one per engine class | Submission externally synchronised |
| `CommandPool` | Device, bound to a queue family | Destroying it invalidates its buffers | One pool per thread by default |
| `CommandBuffer` | Pool | Reset by the application or by the pool | Recording externally synchronised per buffer |
| `Buffer` | Device + memory requirement | Explicit destroy; references tracked | Externally synchronised |
| `Image` | Device + format/usage/mips/layers | Explicit destroy | Externally synchronised |
| `Sampler` | Device | Explicit destroy | Immutable after creation |
| `ShaderModule` | Device + SPIR-V blob | Explicit destroy; compiled form cached by hash | Immutable |
| `Pipeline` | Device + pipeline description | Explicit destroy; cacheable across runs | Immutable |
| `DescriptorSetLayout` / `DescriptorSet` | Device / pool | Explicit destroy | Update externally synchronised |
| `Fence` / `Timeline` | Device | Explicit destroy | Waitable from any thread |
| `Swapchain` | Application + KWM | Until reconfigure | Presentation externally synchronised |
| `Surface` | Application + KWM | Until window close | — |

Rules:

- **No implicit allocation.** Every GPU allocation is requested explicitly or
  comes from a pool the application created.
- **No hidden synchronisation.** KGA never inserts a barrier the application did
  not ask for. The validator reports missing barriers in development builds.
- **Handles are per-process and never reused after destroy** within a generation
  counter, so stale handles are detected rather than silently aliasing.
- **Immutable objects** (samplers, pipelines, shader modules) cannot be mutated;
  changing them creates a new object, which makes caching and multithreading
  predictable.

### 2.2 Command buffers and queues

- Three queue classes: **graphics**, **compute**, **transfer** (copy engine).
  A device reports how many queues of each class it has; an application may not
  assume `≥ 2` of any class.
- Command buffers belong to a pool with a queue class. Recording is single
  threaded per buffer; pools may be distributed per thread.
- Submissions take: command buffers, wait list (timelines + stages), signal list.
- **Batching is explicit**: multiple command buffers per submission, and
  multiple submissions may be coalesced by the front-end, but coalescing is
  observable only through the timing counters, never through ordering.

### 2.3 Explicit synchronisation

- A **fence** is a boolean with a counter; a **timeline** is a monotonic 64-bit
  counter with wait/signal values. Both are waitable by the CPU and by the GPU.
- Barriers are declared as `(resource range, src stage/access → dst stage/access,
  layout transition)`. KGA has **no implicit layout tracking**; images carry an
  explicit layout that the application must transition.
- The application declares which queue class may touch a resource at submission
  time; KGC tracks ownership per queue family and rejects cross-class use
  without an ownership transfer.

### 2.4 GPU memory

- Memory is exposed as **heaps** with properties (`device_local`,
  `host_visible`, `host_coherent`, `cached`) and **types** derived from them.
  The application chooses the type; KGA does not guess `[S16]`.
- Allocation granularity, alignment and the maximum single allocation are
  queried, not assumed.
- **Suballocation is an application/engine concern**, supported by a documented
  block allocator in the SDK; KGA exposes only what the hardware can express.
- Residency: the application declares which allocations must stay resident; KGC
  evicts others under pressure and reports the event.

### 2.5 Pipelines, shaders and state

- One immutable `Pipeline` object per (shader stages, fixed state, attachment
  formats, layout). Pipelines are cached by content hash, both in process and on
  disk (see [`graphics-platform.md`](graphics-platform.md) §7).
- **Dynamic state** is limited to what is cheap on all supported hardware
  (viewport, scissor, blend constants, stencil reference). Anything that forces
  a hardware re-program is part of the pipeline key.
- Shader ingestion: **SPIR-V** is the canonical input (ADR-0009), lowered to a
  Kynox backend IR per vendor. The front-end may accept other languages through
  a separate compiler that emits SPIR-V, but the driver contract is SPIR-V → IR.
- Compute uses the same pipeline object with a compute stage and a workgroup
  size; there is no separate "compute API".

### 2.6 Multithreading and lifetime

- Object creation is thread-safe; destruction requires external
  synchronisation with any in-flight use (the application's job, as in Vulkan).
- Command recording is embarrassingly parallel across pools.
- The SDK ships a **deferred-deletion** helper because most engines need one;
  Kynox does not build it into the driver.
- No global locks in the submission path; per-queue locks only.

### 2.7 Versioning, extensions and capability tiers

| Mechanism | Rule |
|---|---|
| Revision | Integer `KGA_REVISION`; additive changes only within a revision |
| Extensions | Named, opt-in, queried individually; never change existing behaviour |
| Capability tiers | Tier 0 (linear framebuffer), 1 (basic 3D), 2 (compute), 3 (advanced: multiview, bindless, sparse), 4 (ray tracing) |
| Removal | Requires a new revision and a deprecation window of at least one release cycle |
| Behaviour queries | Every device reports limits, formats and features; **not** a marketing string |

The tier is a *floor* for feature sets, not a promise that every tier-3 GPU
implements every tier-3 optional feature; applications must query.

### 2.8 Integration with KGC, KDS and KGR

- **KGC** executes submissions; KGA never touches MMIO.
- **KDS** owns presentation; `Swapchain` is a KWM object that KGA presents into.
  Direct scanout is a KWM/KDS decision, requested but not guaranteed.
- **KGR** is a client of KGA, not part of it; it uses the same public surface as
  any engine.
- Tools (KGT) attach to KGA/KGX through a debug capability, never by reading
  driver memory.

### 2.9 Public and internal contracts

| Public (stable) | Internal (changeable) |
|---|---|
| Object model, command encoding, synchronisation rules, shader ingestion, capability queries | Backend IR, pipeline cache format, descriptor lowering, memory allocator |
| Error codes and validation messages | Validation rule numbering |
| Extension discovery | Extension implementation |

## 3. KGX — the shared execution core

### 3.1 Why a shared core exists

Three front-ends with three independent implementations would triplicate:
shader compilation, descriptor lowering, memory layout calculation, pipeline
caching, validation and the submission encoder. A shared core means one place
where these are correct, one place to optimise, and one place to test — while
each front-end keeps its own semantics.

### 3.2 What the core must be able to express

KGX is designed against the **union of the three APIs' needs**, minus what is
purely syntactic:

- multiple queues and queue families; concurrent submission;
- explicit memory types, aliasing, and non-coherent host access;
- render passes *as a compatibility construct* (KVK) and dynamic rendering (KGA,
  modern KVK) — one encoder supports both;
- descriptor sets with multiple layouts, push constants, bindless arrays;
- pipeline derivatives and caches;
- secondary command buffers (KVK) and parallel recording;
- query objects (occlusion, timestamps, pipeline statistics);
- transform feedback (KGL) — implemented as a KGX feature available to all.

### 3.3 Mapping table

| Concept | KGA | KVK | KGL | KGX representation |
|---|---|---|---|---|
| Device | `Device` | `VkDevice` (+ physical devices) | context | device object + capability table |
| Submission unit | command buffer | `VkCommandBuffer` | draw call stream | encoded command list |
| Sync | fence/timeline/barrier | fence/timeline/semaphore/barrier | implicit + `glFinish`/fences | timeline + barrier records |
| Binding | descriptor set | descriptor set | bound state | descriptor table + layout |
| Pipeline | immutable | immutable (PSO) | state vector → cached pipeline | pipeline object + state key |
| Layout | explicit image layout | image layout + render pass | implicit | explicit layout + transition list |

### 3.4 Where the core must not be forced

If a front-end needs a semantic the core cannot express, the front-end emulates
it **locally**. Examples: Vulkan's render-pass load/store operations on a
dynamic-rendering-only backend; OpenGL's client-side vertex arrays; Vulkan
`VK_KHR_sparse` (declared unsupported rather than emulated badly). Each
deviation is listed in the front-end's support matrix.

## 4. KGL — OpenGL compatibility

### 4.1 Why OpenGL still matters

OpenGL 4.6 (released 2017) remains the last core version of the API; the Khronos
registry publishes both core and compatibility profiles dated 2022-05-05 and
GLSL 4.60 dated 2023-08-14 `[S19]`. Conformance submissions for 4.6 continue in
2025–2026 `[S20]`. The installed base of OpenGL applications (older games, CAD,
scientific tools, plugins) is the reason the layer exists; it is not the future
of the platform.

### 4.2 Support ladder

| Level | Content | Rationale |
|---|---|---|
| **GL 1.1 / 1.2** | fixed function, immediate mode, display lists, `glBegin` | the long tail of legacy software |
| **GL 2.1** | GLSL 1.20, FBOs (extension), VBOs | the last "old" baseline |
| **GL 3.3 core** | modern core, VAOs, GLSL 3.30 | the practical floor for ports |
| **GL 4.6 core** | the modern ceiling | engines that never moved to Vulkan |
| **Compatibility profile** | deprecated features on top of 4.6 | **only to the extent proved**; not declared upfront |
| **OpenGL ES** | 2.0 / 3.2 | evaluated only if mobile-derived tooling becomes relevant |

### 4.3 Architecture

```text
GL application
   │  GLX / EGL subset  ──────────────▶ KWM surface (window or offscreen)
   ▼
KGL front-end
   ├─ state tracker (shadow state, dirty bits)
   ├─ object layer (textures, buffers, VAOs, FBOs, samplers)
   ├─ GLSL front-end ──▶ SPIR-V ──▶ KGX shader pipeline
   └─ draw translator (immediate mode → streaming buffers)
   ▼
KGX ──▶ KGC
```

- **State tracker.** OpenGL is a state machine; the hardware is not. KGL keeps
  the authoritative state, computes a pipeline key on draw, and looks it up in a
  cache. The cost of a state change is a few writes, not a hardware call.
- **Immediate mode.** `glBegin/glEnd`, client arrays and display lists are
  accumulated into a ring buffer and issued as one draw; this is the only way to
  make GL 1.x software run at a tolerable speed. Display lists are compiled
  into command lists, not replayed instruction by instruction.
- **Shaders.** GLSL is compiled by Kynox's own front-end to SPIR-V (ADR-0009),
  then flows through the same KGX path as every other API. Fixed-function state
  is turned into *generated* shaders from a small library (one variant per state
  combination actually used), which keeps one shader pipeline in the system.
- **Objects.** FBO/VBO/VAO/textures map to KGX resources with reference
  counting; GL names are a front-end table, never kernel handles.

### 4.4 Semantic gaps that cannot be translated directly

| OpenGL behaviour | Why it does not map | Kynox approach |
|---|---|---|
| Unbounded client-side arrays (`glVertexPointer`) | no residency, arbitrary pointers per draw | copy into a streaming buffer with a documented size limit |
| `glReadPixels` from the front buffer | the compositor owns the framebuffer | read from the application's last rendered surface; front-buffer reads are serviced by KWM with a copy |
| Implicit pipeline barriers | the core is explicit | state tracker inserts the minimum barrier set; validator proves it |
| Display lists with embedded state changes | they are command streams | compile to a command list, replay as one submission |
| `GL_ARB_compatibility` behaviours | deprecated and vendor-dependent | implemented only where a test exists; otherwise the context is refused at creation |
| Multisample resolve rules | vary by driver in practice | fixed, documented rule; deviations reported by the conformance suite |
| `glFinish` semantics | global stall | implemented as queue completion, not device reset-level stall |

### 4.5 Context and surface model

- Contexts are per-thread, shareable through a share group; sharing maps to one
  KGX device and one memory heap set.
- GLX is implemented as a protocol shim over KWM, not as a network protocol;
  EGL is implemented as the primary surface API. Direct Rendering
  Infrastructure (DRI) module loading is **not** supported.
- A GL context is bound to the device that owns its share group; a share group
  cannot span devices.

### 4.6 Conformance

- Khronos OpenGL CTS is the external oracle; Kynox maintains a pass-rate matrix
  per level (1.1, 2.1, 3.3, 4.6 core) with an explicit list of excluded tests
  and the reason.
- No GL version is advertised until the matrix for that level is published and
  the context creation path refuses unsupported requests.

## 5. KVK — Vulkan compatibility

### 5.1 Scope

| Version | Position |
|---|---|
| Vulkan 1.0 | baseline; required for old titles |
| Vulkan 1.1 | required: timeline semaphores |
| Vulkan 1.2 | required: descriptor indexing, buffer device address, timeline |
| Vulkan 1.3 | target: dynamic rendering, synchronisation2, extended formats |
| Vulkan 1.4 | **not claimed**; the specification is 1.4.365 (2026-10-02) `[S16]` and consolidates push descriptors, dynamic rendering local reads, scalar block layouts and maintenance6 into core `[S18]`. Reaching 1.4 is a later phase, after 1.3 is conformant. |

`VkPhysicalDeviceProperties::apiVersion` reports **what is actually supported**.
Lying to satisfy an application is forbidden: an application that requires 1.4
receives 1.3 and must decide what to do.

### 5.2 Instance, device and queue model

- `VkInstance` and `VkPhysicalDevice` map to KGX's enumeration; one physical
  device per GPU, no invented devices.
- Queue families map 1:1 to KGC queue classes where the hardware allows; where a
  family is a superset, KVK reports the narrower set rather than a family it
  cannot honour.
- `VkDevice` creation fails cleanly if a requested feature is not available; no
  silent downgrade.

### 5.3 Core object mapping and fidelity

| Vulkan | Fidelity requirement | Implementation |
|---|---|---|
| `VkCommandBuffer` | recording semantics, secondary buffers | direct mapping to KGX command lists |
| `VkRenderPass` / `VkFramebuffer` | load/store ops, subpass dependencies, input attachments | compatibility object compiled to dynamic rendering + explicit barriers; `LOAD` on a tile-based GPU may require a resolve |
| `VkPipeline` / layouts | push constants, specialisation constants, derivatives | direct; specialisation is resolved at pipeline creation |
| `VkDescriptorSet` | update-after-bind, partially bound, aliasing | KGX descriptor table with per-set validation |
| `VkFence` / `VkSemaphore` / timeline | GPU-GPU ordering, wait before signal | KGC timeline primitives |
| `VkDeviceMemory` | type bits, dedicated allocations, aliasing | KGC heap + object binding; aliasing only where the driver declares support |
| `VkSwapchainKHR` | acquire/present, images in flight | KWM swapchain; presentation through KDS |
| `VkQueryPool` | occlusion, timestamps, statistics | KGC query objects |

### 5.4 Synchronisation fidelity

This is the part where "just translate to KGA" fails, and why the shared core
exists:

- Vulkan allows **concurrent use of resources across queues** with explicit
  ownership transfer. KGX encodes ownership transfers and KGC enforces them.
- **Timeline semaphores** are a first-class KGC object, not emulated with
  fences.
- **Binary semaphores** are emulated on timelines with a documented rule for
  reuse, because emulation is exact for the allowed usage patterns.
- Barriers carry stage/access masks that map to the vendor's cache-control
  operations; an unsupported mask combination is a validation error, never a
  silent no-op.

### 5.5 Memory model

Vulkan makes the application responsible for memory types and coherence `[S16]`.
KVK preserves that: type bits are honoured, `HOST_COHERENT` is reported only
when true, and non-coherent flush/invalidate operations map to KGC cache
operations. Suballocation remains the application's responsibility; KVK does not
secretly suballocate because that would break aliasing rules.

### 5.6 Swapchain and WSI

- One presentation model: KWM swapchains over KDS. `VK_KHR_surface`,
  `VK_KHR_swapchain` exist; `VK_KHR_xlib_surface`, `VK_KHR_wayland_surface`,
  `VK_KHR_win32_surface` do not.
- A Linux or Windows application that creates a Vulkan surface through its own
  platform's WSI needs the platform's window system (X11/Wayland/HWND), which is
  a compatibility-layer concern, not a KVK one (§8).
- Presentation modes map to KDS modes; `MAILBOX`/`FIFO_RELAXED` are reported
  only when the display path supports them.

### 5.7 Extensions and features

- Feature bits are computed from KGX capabilities and vendor driver support;
  they are never hardcoded per application name.
- Extensions are implemented only when their semantics can be honoured. A
  commonly requested extension that cannot be honoured is documented as
  unsupported with a reason, rather than partially implemented.
- `VK_KHR_swapchain`, `VK_KHR_maintenance1..3`, `VK_KHR_dynamic_rendering`,
  `VK_KHR_synchronization2`, `VK_EXT_descriptor_indexing` are the first targets.

### 5.8 How KVK is delivered

KVK is an **ICD**: `libvulkan.so` (a Kynox implementation of the loader ABI)
discovers Kynox as a Vulkan implementation. Applications that link the Vulkan
loader work unmodified; applications that link `libvulkan.so.1` directly also
work. This is the one place where Kynox deliberately implements an **external
ABI** as a stable contract — because that API *is* the compatibility target.

## 6. The shared core is not a lowest common denominator

A frequent failure of "translate Vulkan to a simpler API" designs is that the
simpler API cannot express the original semantics, so the translator approximates
and applications break in subtle ways. Kynox avoids this by construction:

1. KGX is specified from the union of the three APIs' *required* semantics
   (§3.2), not from KGA's current feature set.
2. Where KGX cannot express something, the **front-end** emulates it and
   documents the cost; the core never silently drops a guarantee.
3. Every front-end publishes a **deviation table**: behaviour that differs from
   the reference API, with a test or a refusal.

## 7. Security of the graphics compatibility layers

| Risk | Control |
|---|---|
| Malformed command buffers from a foreign API | KGC structural validation + KGX semantic validation in development builds; a hung context is reset, never trusted |
| Shader compiling to malicious IR | SPIR-V validated before lowering; backend IR is a closed instruction set; no JIT of arbitrary machine code |
| Descriptor/buffer out-of-bounds | all accesses bind to resources with recorded extents; validator and (where hardware allows) bounds checks |
| Cross-process GPU memory | per-process GPU address spaces in KGC; no shared handles without an explicit capability |
| GPU-side denial of service | per-process queue quotas and a watchdog; a spinning shader triggers context reset |
| Compatibility layer escaping the sandbox | layers are unprivileged user-space libraries inside the application's process; they hold only the application's capabilities |

A graphics compatibility layer never runs in Ring 0, never receives raw MMIO and
never gains a capability the application did not already have.

## 8. Applications from Linux and Windows

The full matrix is in [`application-ecosystem.md`](application-ecosystem.md) §8
and repeated here for the graphics path:

| Origin | API used by the app | What Kynox must provide | Status |
|---|---|---|---|
| Native | KGA | KGA + KGX + KGC | not started |
| Native | OpenGL | KGL + `libGL`/`libEGL` | not started |
| Native | Vulkan | KVK + `libvulkan` ICD | not started |
| Linux (KLC) | OpenGL | KGL + GLX/EGL shims + X11/Wayland window bridge | not started |
| Linux (KLC) | Vulkan | KVK + WSI for the bridged window system | not started |
| Windows (KWC) | OpenGL | KGL + WGL shim + HWND mapping | not started |
| Windows (KWC) | Vulkan | KVK + `VK_KHR_win32_surface` equivalent | not started |
| Windows (KWC) | Direct3D | D3D front-end (future, §10) | not planned yet |

**ABI compatibility and graphics compatibility are independent.** KLC can run a
static console program with no graphics; KVK can run a Vulkan application with
no Linux ABI. A title needs both layers only when it is a GUI application from
another system. Conflating them is how compatibility projects lose years.

Graphics resources are **not** shared between personalities implicitly. A
window system bridge translates surface creation and input; it does not hand a
Vulkan device from one process to another. Cross-process sharing requires an
explicit exported-memory capability, which is a later phase and a security
decision of its own.

## 9. Performance model

| Path | What is measured | Claim allowed |
|---|---|---|
| KGA submission | CPU ns per `submit`, queue depth | only after the KGA benchmark exists |
| KVK submission | CPU ns per `vkQueueSubmit` vs native vkQuake-class baseline | delta versus KGA measured on the same GPU |
| KGL draw | CPU ns per draw at N state changes | only with the state-tracker benchmark |
| Shader compile | cold/hot pipeline creation time; cache hit rate | measured per phase |
| Presentation | flip-to-vblank, missed frames | KDS counters |
| Compatibility overhead | syscall translation cost in KLC/KWC | measured per syscall family |

Forbidden phrases in project documentation: "zero overhead", "native
performance", "indistinguishable from native". Allowed: a measured number with a
scenario, a baseline and a date.

## 10. Direct3D and future APIs

D3D is **not** in the critical path. It is evaluated in
[`windows-compatibility.md`](windows-compatibility.md) §13 and in
[`COMPATIBILITY_ROADMAP.md`](../roadmap/COMPATIBILITY_ROADMAP.md) §7 with its own
entry criteria. The architectural prerequisite is that KGX exposes a binding and
pipeline model expressive enough for D3D12-class descriptors; that is a
consequence of KVK, not a separate design.

## 11. Phases (summary)

| Phase | Deliverable | Entry condition |
|---|---|---|
| C-G0 | KGX skeleton + KGC submission on virtio-gpu (tier 0) | KDS tier 0 working (S5) |
| C-G1 | KGA revision 0: buffers, images, one queue, clear/draw | KGC submission validated |
| C-G2 | KVK 1.0 subset: instance/device/queue, triangle, swapchain | KGA objects stable |
| C-G3 | KVK 1.1–1.3 features + conformance harness | KVK 1.0 passing its corpus |
| C-G4 | KGL 3.3 core subset | KGX state/pipeline model stable |
| C-G5 | KGL 4.6 core + compatibility-profile study | KGL 3.3 conformance published |
| C-G6 | D3D front-ends (if justified) | KGX descriptor model proven by KVK |

These phases map to compatibility roadmap phases C6–C8.
Details, criteria, tests and risks: [`../roadmap/COMPATIBILITY_ROADMAP.md`](../roadmap/COMPATIBILITY_ROADMAP.md).

## 12. Open questions

1. Does KGX live in its own process (shared by all clients) or in each
   application's process? In-process is faster and simpler; shared enables a
   single shader cache but creates an attack surface and a lifetime problem.
2. Is the KGA shader ingestion format exactly SPIR-V 1.6, or a strict subset
   with a Kynox validation profile? (ADR-0009 direction: subset now, widen by
   revision.)
3. How much of OpenGL's compatibility profile is worth implementing, given that
   the applications that need it are also the ones least likely to run well on
   modern hardware?
4. Does the Linux graphics path need X11 at all, or can Wayland-only coverage
   be published honestly for the first version?
5. What is the cost of the render-pass compatibility object on a
   dynamic-rendering backend, and does it force a resolve on every `LOAD`?
