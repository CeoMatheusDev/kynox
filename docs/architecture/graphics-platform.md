# Kynox — Graphics Platform Architecture

- Status: **planning document**. Kynox today has a software rasteriser, an
  in-kernel compositor/window manager and a firmware framebuffer bridge; it has
  **no GPU driver, no display-controller abstraction and no GPU API**. Everything
  below is the target design.
- Date: 2026-10-31.
- Related: [`platform-architecture.md`](platform-architecture.md),
  [`market-landscape.md`](../strategy/market-landscape.md),
  [`application-ecosystem.md`](application-ecosystem.md),
  [`security-architecture.md`](security-architecture.md),
  [`PRODUCT_ROADMAP.md`](../roadmap/PRODUCT_ROADMAP.md).
- Decisions referenced: [ADR-0004](../decisions/0004-graphics-stack-split.md),
  [ADR-0005](../decisions/0005-native-graphics-api.md),
  [ADR-0006](../decisions/0006-userspace-compositor.md).

## 1. Scope and non-goals

**Scope.** A complete graphics platform: display control, GPU driver model,
graphics core, native API, renderer, window system/compositor, and tools.

**Not a framebuffer with a blitter.** The platform must support desktop use,
games, CAD, scientific visualisation, video and GPU compute on the same
foundations, with explicit resource control and predictable performance.

**Non-goals for the first version.** Universal hardware support, hardware ray
tracing on day one, a Vulkan-compatible implementation, a full shader language
toolchain shipped before the API is stable, and any claim of performance
superiority without measurements.

**Naming.** `KDS` (display system), `KGC` (graphics core), `KGA` (graphics API),
`KWM` (window manager/compositor), `KSC` (shader compiler), `KGT` (graphics
tools) are **proposals** and must be registered per
[`KYNOX_NATIVE.md`](../../KYNOX_NATIVE.md) §8 before becoming official.

## 2. Design principles

1. **Explicit ownership.** Every buffer, image, queue and fence has an owner and
   a lifetime; nothing is created implicitly by a draw call.
2. **Explicit synchronisation.** Fences and timelines are the only ordering
   primitive across queues and processes. No hidden "flush" semantics.
3. **Capability tiers.** Hardware advertises what it can do; the API exposes
   optional capabilities instead of assuming a lowest common denominator or a
   universal feature set.
4. **Minimal privilege.** The kernel owns memory, address spaces, submission and
   reset. Vendor code runs behind a validated interface in user space when an
   IOMMU is present.
5. **Validate at the boundary.** Command buffers, descriptors and shader modules
   are structurally validated before reaching the device; validation is on by
   default in development.
6. **Restartable services.** A crashed compositor or GPU driver must not take the
   kernel or the session with it.
7. **Measure frame pacing, not averages.** Every stage reports its own timing so
   a missed deadline can be attributed.

## 3. Layered architecture

```text
┌────────────────────────────────────────────────────────────────────────┐
│ Applications: games, editors, CAD, browsers, desktop apps              │
├────────────────────────────────────────────────────────────────────────┤
│ KGA-H  higher-level graphics (render graph, resource lifetime)         │
│ KGA-UI 2D/UI layer (surfaces, text, effects)                           │
├────────────────────────────────────────────────────────────────────────┤
│ KGA    native low-level API: devices, queues, command buffers,         │
│        pipelines, descriptor sets, images, buffers, fences             │
├────────────────────────────────────────────────────────────────────────┤
│ KWM    compositor + window manager service (user space)                │
│ DS     display settings/colour service (user space)                    │
├────────────────────────────────────────────────────────────────────────┤
│ KGC    kernel graphics core: GPU memory objects, GPU VA per process,   │
│        queues/rings, submission, fences/timelines, hang detection       │
│ KDS-K  kernel display core: connectors, CRTCs, planes, atomic commit,   │
│        page flip + fence, VRR/HDR metadata, hotplug, DPMS               │
├────────────────────────────────────────────────────────────────────────┤
│ GPU driver host: user-space vendor driver (IOMMU) or in-kernel driver  │
│ (no IOMMU), plus the transport drivers (PCI, virtio-gpu, display link) │
├────────────────────────────────────────────────────────────────────────┤
│ Hardware: display controllers, GPUs, firmware, IOMMU                   │
└────────────────────────────────────────────────────────────────────────┘
```

The vertical split matters: **KDS-K and KGC are mechanism; KWM, DS and the
vendor drivers are policy and device-specific logic.** A change to window layout
must never require a kernel change; a change to memory protection must never
depend on the compositor.

## 4. Display System (KDS)

### 4.1 Model

KDS follows the proven object model of modern display stacks, reimplemented for
Kynox:

| Object | Meaning | Owned by |
|---|---|---|
| **Device** | A display controller (one per GPU/connector group) | Kernel |
| **Connector** | A physical output (DP, HDMI, eDP, virtual) with its capabilities | Kernel |
| **CRTC** | A scanout engine with its pixel clock and mode | Kernel |
| **Plane** | A layer composed by the controller (primary, overlay, cursor) | Kernel |
| **Framebuffer** | A memory object plus format/modifier/colour info | Client, pinned during use |
| **Mode** | Resolution, refresh, flags, colour format | Kernel, validated |
| **Commit** | Atomic state change (modes, planes, colour, VRR) | Client via service |

The kernel exposes this model through a small interface; the display service
(`DS`) computes policy (which monitor is primary, arrangement, scaling, HDR
preference) and submits commits.

### 4.2 Discovery

1. Enumerate display controllers through PCI + ACPI (`_DOD`/`_DCS` equivalents
   are vendor-specific; the driver reports connectors).
2. Read EDID/DisplayID over DDC (I2C-over-AUX for DP, DDC for HDMI). Validate
   header, checksum, descriptor bounds and extension blocks. Reject silently
   corrupt data and fall back to a conservative mode list.
3. Build a capability record per connector: max pixel clock, HDR metadata
   support, VRR range, DSC availability, audio support, max bpp.
4. Publish the record to user space; **the kernel never decides which monitor is
   "main"**.

### 4.3 Modes and validation

A mode is accepted only if it satisfies: pixel clock within the controller and
connector limits, timing totals consistent, refresh within the VRR range when
VRR is requested, and memory bandwidth available for the selected format. Invalid
modes return an error; the kernel never "rounds" a mode silently.

Fallback ladder: requested mode → nearest supported mode → safe boot mode →
firmware framebuffer (GOP) handoff, which is always available.

### 4.4 Atomic commit

A commit is a set of property changes applied together or not at all:

```text
commit(device, { connector: {crtc, mode, vrr, colour},
                 planes: [{crtc, fb, src_rect, dst_rect, z, alpha, blend}],
                 fence_out })
```

Rules:
- plane geometry and format must be supported by the controller;
- a framebuffer is pinned until the flip fence signals;
- tearing-free commit requires the fence; immediate commit is a separate,
  explicitly requested property;
- a failed commit leaves the previous state intact and returns the failing
  property, not just an error code.

### 4.5 VRR, HDR and colour

- **VRR:** per-connector range from EDID/DisplayID; the service may enable it for
  a surface or a fullscreen app; the kernel reports delivered refresh per frame
  for verification.
- **HDR:** per-surface transfer function (SDR sRGB, PQ/ST.2084, HLG, scRGB
  linear), primaries, luminance range and content metadata; the kernel passes
  metadata to the connector and reports the connector's capabilities. Tone
  mapping is a **policy** decision in the service/compositor, not in the kernel.
- **Colour management:** the compositor owns conversion between surface and
  output colour spaces; ICC profiles are an interchange format (input/output),
  not the internal representation.

### 4.6 Hotplug and power

- Connector status changes are events with a generation counter; the service
  re-reads EDID, re-validates modes and re-commits.
- Unplugging a connector with a bound CRTC triggers a defined fallback: move the
  content to another output or mark the surface as not presented. No crash.
- DPMS states (on, standby, suspend, off) are per-device properties; wake-up is
  bounded by a timeout and reports failure.
- Multi-GPU: an output belongs to one device; rendering may happen on another
  (render node/display node split) with explicit copies and fences. This is the
  "offload" case and must be modelled, not simulated.

### 4.7 Failure handling

| Failure | Behaviour |
|---|---|
| EDID unreadable | Safe mode list, event logged, no retry loop |
| Mode invalid | Error to caller; previous mode kept |
| Flip timeout | Fence fails; the buffer is unpinned; the surface is marked not presented |
| Link training failure | Retry twice, then fall back to a lower rate/mode |
| Engine hang (flip never completes) | Reset the display engine; if it fails, fall back to GOP framebuffer |
| Device removal | Unbind, notify service, keep the compositor alive with the remaining outputs |

## 5. GPU driver model

### 5.1 Split

| Layer | Runs in | Responsibility |
|---|---|---|
| **KGC** | Kernel | GPU memory objects, per-process GPU address spaces, rings/queues, submission, fences, hang detection, reset, power transitions |
| **Transport driver** | Kernel | PCI BAR mapping, MSI/MSI-X, firmware loading, IOMMU attachment |
| **Vendor driver (UMD)** | User space | Register programming, command generation, shader/pipeline translation, memory placement decisions |
| **Validation** | Kernel + user space | Structural validation in the kernel; detailed validation in development builds |

The kernel interface to a user-space driver is deliberately narrow:

```text
device_info() -> caps, register windows, irq, iommu_group
map_bar(bar) -> capability
alloc_object(size, flags, alignment) -> gpu_object
map_object(object, va_range, permissions)
submit(queue, commands[], fence_in, fence_out)
wait(fence, timeout)
reset(context) / reset(device)
```

The driver never receives direct access to another process's GPU memory, and the
kernel never trusts a command stream blindly: it validates object references,
offsets, lengths and queue ownership before the ring is written.

### 5.2 Hardware tiers

| Tier | Hardware | What works | Status |
|---|---|---|---|
| 0 | No GPU, GOP framebuffer | Software rasteriser, compositor, 2D UI | Exists (rasteriser + bridge), no KDS |
| 1 | GPU with modes only | KDS modes, page flips, cursor plane, software rendering into scanout | Planned |
| 2 | 2D/overlay capable | GPU blits, overlay planes, damage rect composition on GPU | Planned |
| 3 | 3D/compute | KGA, queues, shaders, renderer | Planned |
| 4 | Advanced | Ray tracing, mesh shaders, VRR+HDR+compute concurrently | Long term |

A device's tier is published in the support matrix. Applications query
capabilities and degrade gracefully; KGA must make the query cheap and explicit.

### 5.3 Vendors (honest status)

| Vendor family | Documentation reality | Kynox plan |
|---|---|---|
| Virtual (virtio-gpu) | Open specification (OASIS), simple command model, ideal first target | **First GPU driver**, because it can be validated in QEMU with no firmware |
| Intel (Gen9+) | Public programming documentation for many generations; open Linux driver as reference | Second target; start with display (KDS) then 3D |
| AMD (GCN/RDNA) | Public ISA and register documentation; open Linux driver as reference | Third target; display then compute, then 3D |
| NVIDIA (Turing+) | Open kernel modules exist but require GSP firmware; userspace stacks are complex | Later; requires firmware packaging and a large driver effort |
| Legacy/VESA | Not usable under UEFI beyond GOP | Not supported beyond Tier 0 |

**No fictional support.** The table states intent and prerequisites; it does not
claim any driver exists.

### 5.4 Firmware

- Firmware blobs are loaded through a signed, versioned package; the kernel
  requires an exact match of device ID and firmware version.
- A missing or incompatible blob is a clean failure (`UnsupportedDevice`), never a
  hang.
- Redistribution terms are recorded per package; the support matrix says which
  devices need a blob the project cannot ship.

## 6. Graphics core (KGC)

### 6.1 Memory

- **Heaps:** device-local (VRAM), host-visible, and a system heap for staging.
- **Objects:** typed (`buffer`, `image`, `sampler`, `query`), immutable size,
  flags for tiling/compression/caching, alignment guarantee.
- **Residency:** the application states required residency before submission;
  KGC may evict to the system heap under pressure and reports it.
- **GPU address spaces:** per process, isolated; a context cannot reference
  another process's object.
- **Mapping:** CPU mapping is explicit and scope-limited; write-combining for
  uploads, cached for readback.

### 6.2 Queues and submission

- Queue families: `graphics`, `compute`, `transfer` (a device may expose fewer).
- Command buffers are recorded by the application, validated, then submitted
  with input/output fences.
- A submission is a batch of command buffers; the CPU cost per submission is a
  measured metric.
- Queue priorities exist only where hardware supports preemption; otherwise the
  scheduler time-slices at submission boundaries and says so.

### 6.3 Synchronisation

- **Binary fences** for completion.
- **Timeline semaphores** for cross-queue and cross-process ordering.
- No implicit barriers: the application records them; validation reports missing
  ones in development.
- Fences are waitable objects that integrate with the scheduler (blocking wait
  does not spin).

### 6.4 Pipelines and shaders

- Pipeline state objects are immutable after creation (graphics and compute).
- Shader modules are validated on load; compile errors are returned with
  diagnostics, not crashes.
- Pipeline caches are per-application and content-addressed, so a driver update
  invalidates them explicitly.
- Shader IR and backend are decided in ADR-0005 (SPIR-V as an *input* is the
  leading option for tooling interoperability).

### 6.5 GPU scheduling and recovery

- Per-engine ring with a GPU scheduler choosing the next context by priority and
  fairness.
- Hang detection: a submission that exceeds its fence timeout (default
  configurable, no infinite waits) triggers:
  1. context reset (fast, preserves other contexts where hardware allows),
  2. device reset (all contexts lost, reported to their owners),
  3. device rebind, and a diagnostic with the last submitted commands.
- Reset is a tested path: a fault-injection mode hangs a context on purpose.

### 6.6 Isolation and command validation

| Level | Checked by | Examples |
|---|---|---|
| Structural | Kernel | Buffer bounds, object handles, queue ownership, packet length |
| Resource | Kernel | GPU VA range validity, object residency, format/usage compatibility |
| Semantic | Development build | Barriers, layout transitions, descriptor consistency |
| Shader | Compiler + validator | Bounds on loops, memory access classes |

The kernel never executes a pointer from the command stream. The GPU's page
tables, not the driver, enforce memory isolation; the IOMMU backs that up for
device-originated access.

## 7. Native graphics API (KGA)

### 7.1 Goals

Games, engines, desktop apps, CAD, visualisation and compute; low CPU overhead;
predictable performance; explicit synchronisation; multithreading; optional
capabilities; versioned compatibility; first-class debug tooling.

### 7.2 Object model

| Object | Created by | Lifetime |
|---|---|---|
| `Device` | Application | Until close; backed by a capability |
| `Queue` | Application | Device lifetime |
| `Buffer`, `Image` | Application | Explicit destroy; refcounted internally |
| `ShaderModule` | Application | Explicit destroy; cached compiled form |
| `Pipeline` | Application | Immutable; cacheable |
| `DescriptorSet` | Application | Explicit destroy; layout validated |
| `CommandBuffer` | Application | Pool-based; reset by the application |
| `Fence`, `Semaphore` | Application | Explicit; timelines for cross-queue order |
| `Swapchain` | Application + compositor | Until reconfigure |

### 7.3 Execution model

```text
record(cmd, [bind pipeline, bind descriptors, draw/dispatch, barrier])
submit(queue, cmds, wait=[sem], signal=[sem])
present(swapchain, image, wait=[sem])   // goes through the compositor
```

The API is explicit but smaller than Vulkan: no render passes as objects (dynamic
rendering model), no legacy image layouts beyond the declared usage, no
per-platform WSI split (Kynox has one display model).

### 7.4 Versioning and capabilities

- The API has a revision number and a capability query per device.
- Extensions are opt-in, enumerated as strings, and never change existing
  behaviour.
- The application must check a capability before using it; the validator reports
  unchecked usage in development.
- Binary compatibility is guaranteed within a major revision; removal requires a
  new revision and a deprecation window.

### 7.5 Higher layers

- **KGA-H:** render graph, automatic barriers and transient allocation,
  multi-threaded command recording, default pipelines for PBR/HDR/post.
- **KGA-UI:** 2D layer for desktop applications (surfaces, rounded rects, text
  runs, blur, shadows) implemented on KGA, used by the shell and native apps.

Both are optional: an engine may use KGA directly, and a small app may use only
KGA-UI.

### 7.6 What is borrowed and what is not

| Reference | Borrowed | Not borrowed |
|---|---|---|
| Vulkan | Explicitness, pipelines, descriptor model, SPIR-V *input* consideration | Instance/extension sprawl, render-pass complexity, platform-specific WSI |
| D3D12 | Descriptor heaps, root-signature-like binding, tooling expectations | COM object model, DXIL dependency, Windows-specific residency model |
| Metal | Unified encoder model, argument buffers, tight integration with the OS | Objective-C/Swift-only tooling, Apple-specific memory model |

## 8. Renderer (KGR)

### 8.1 Two renderers, one scene description

1. **Software reference renderer** — required for Tier 0 and for golden-image
   tests. Deterministic, slow, complete enough to validate the scene model.
2. **GPU renderer** — built on KGA, feature-gated by capability tier.

The scene description (meshes, materials, lights, camera, post chain) is shared
so both renderers can be compared on the same input.

### 8.2 Feature matrix

| Feature | Complexity | Depends on | Strategic value | Phase |
|---|---|---|---|---|
| Rasterisation, textures, instancing | Low | KGA core | Required baseline | 1 |
| PBR materials, image-based lighting | Medium | Shader pipeline, mipmaps | Desktop/game quality | 1 |
| HDR pipeline, tone mapping | Medium | Colour in KDS, KGA formats | Differentiator | 1 |
| Shadow mapping (CSM) | Medium | Depth formats, samplers | Quality | 2 |
| Forward+ / clustered forward | High | Compute or many lights | Scalable lighting | 2 |
| Deferred rendering | Medium | MRT, G-buffer formats | Complex scenes | 2 |
| Temporal AA / upscaling | High | Motion vectors, history | Performance/quality | 3 |
| Compute post-processing (bloom, SSAO) | Medium | Compute queues | Quality | 2 |
| GPU particles | Low | Compute | Polish | 2 |
| Occlusion culling (GPU-driven) | High | Indirect draw, compute | Large scenes | 3 |
| Hardware ray tracing | Very high | Vendor support, BVH | Professional/visualisation | 4 |
| Multi-threaded command recording | Medium | Command pools per thread | CPU scalability | 2 |

No feature above is implemented. The matrix exists so scope is explicit.

### 8.3 Renderer contracts

- Frame graph declared by the application or by KGA-H; transient resources
  aliased by the render graph, with barriers derived automatically.
- Frame timing per stage (shadow, main, post, UI, present) exposed to KGT.
- Deterministic replay: same scene + same GPU = same frame (within documented
  floating-point tolerances), which is what makes golden-image tests possible.

## 9. Window system and compositor (KWM)

### 9.1 Placement

KWM is a **user-space service**, not part of the kernel (ADR-0006). It owns:

- the scene (windows, z-order, decorations, effects, animations);
- the client protocol (surface creation, buffer attach, damage, frame callbacks);
- input routing (focus, pointer capture, keyboard grabs with policy);
- output layout (via the display service), scaling and multi-monitor;
- presentation to KDS through atomic commits and fences.

It does **not** own: scanout memory, mode setting, or the GPU rings. Those are
kernel services.

### 9.2 Client protocol (target)

```text
create_surface(role, size, scale, colour) -> surface
attach(surface, buffer, damage[])
commit(surface) -> frame_callback(fence)
set_input_region(surface, rects)
set_title/role/app_id
```
- Buffers are shared memory (software) or KGA images (GPU), never raw scanout.
- The compositor answers with a frame callback (a waitable fence) so clients can
  pace themselves; this is the contract that makes frame pacing measurable.
- Damage tracking is required for incremental composition; a client that cannot
  describe damage simply reports the full surface.

### 9.3 Composition path

```text
client buffer → (GPU or CPU) composition → output framebuffer → KDS flip → vblank
```

Rules:
- fullscreen direct scanout when the surface matches the mode, the format and the
  colour space, and no overlay is above it;
- otherwise compose into a back buffer and flip with a fence;
- effects (blur, transparency, rounded corners) are GPU work when Tier ≥ 2 and
  CPU fallback otherwise;
- every stage records timing so a dropped frame can be attributed.

### 9.4 Multi-monitor, scaling, VRR, HDR

- Outputs are independent CRTCs; a window spans outputs only through composition
  (mixed-refresh spans are documented as a known limitation).
- Fractional scaling uses a render scale plus a present filter; the policy is in
  KWM, the capability in KDS.
- VRR is requested per output when the focused window is fullscreen and the
  surface rate is within range.
- HDR: KWM converts the scene colour space to the output's, applying tone mapping
  with a documented operator; SDR outputs get an SDR conversion.

### 9.5 Input, accessibility and security

- Input devices produce normalized events; KWM routes them by focus and
  hit-testing. Input capture (games) is a capability granted per window.
- Accessibility is a protocol, not a library: a client can expose a semantic tree
  and actions; screen readers are ordinary clients with an explicit capability.
- Screen capture requires an explicit portal grant (see
  [`security-architecture.md`](security-architecture.md)); nothing can read
  another window's pixels silently.

### 9.6 Failure and recovery

- KWM crash: the supervisor restarts it; clients receive a `compositor_lost`
  event; buffers are recreated. The kernel keeps the last committed framebuffer,
  so the screen freezes instead of going black.
- GPU context loss: KWM recreates its context and re-uploads textures; clients
  with GPU buffers are notified.
- A hung client cannot block composition: buffers are validated and fenced.

## 10. Graphics tools (KGT)

| Tool | Purpose | Notes |
|---|---|---|
| **KSC** shader compiler | HLSL-like/Slang-like front end → Kynox IR → GPU | SPIR-V input decision in ADR-0005 |
| Shader inspector | Disassembly, register pressure, occupancy estimate | Uses compiler output |
| Command validator | Structural + semantic checks, on by default in dev | Same code as the kernel's structural checks where possible |
| Frame capture/replay | Record a frame's API calls and resources, replay deterministically | Single capture format shared with the profiler |
| Frame profiler | Per-stage GPU/CPU timing, queue occupancy | Integrates with KWM timing |
| GPU memory profiler | Allocations, residency, evictions, leaks | Uses KGC accounting |
| Driver diagnostics | Ring dumps, hang analysis, firmware version | Produced on reset |
| Resource inspector | Textures, buffers, descriptors, pipelines | Capture-file based |

Tooling is part of the SDK deliverable, not an afterthought: a graphics platform
without a debugger is not usable by engine developers.

## 11. Security of the graphics stack

| Threat | Mitigation | How it is proven |
|---|---|---|
| Malformed command buffer | Kernel structural validation; ring bounds; object handle checks | Fuzzing the validator with a corpus of malformed streams |
| Cross-process GPU memory access | Per-process GPU page tables; validated VA ranges | Negative tests that submit a foreign handle |
| Hostile shader | Compiler bounds; GPU hang detection; time limits | Shader fuzz corpus + watchdog tests |
| DMA from GPU to arbitrary memory | IOMMU enforced for the device; no identity mapping of device memory | IOMMU fault injection tests |
| Screen capture abuse | Portal grant; compositor-mediated capture | Tests that an app without a grant receives no pixels |
| Compositor compromise | Runs unprivileged; kernel keeps last framebuffer; restart | Fault-injection of the compositor |
| Driver crash | User-space driver isolation; device reset | Driver kill/restart test |

No property above is claimed today; each requires the listed test before it is
documented as a guarantee.

## 12. Performance model

| Metric | Definition | Target (to be validated) |
|---|---|---|
| Input-to-photon | Timestamp of input event → vblank of the frame showing its effect | Measured per scenario; no universal number |
| Frame time | CPU + GPU per stage | Distribution, p99, not mean |
| Submission CPU cost | Time in `submit` per command buffer | Compared against a captured baseline |
| Missed vblanks | Flips that miss their deadline | Counted per second and per app |
| Composition cost | Time to compose a scene at a given damage ratio | Measured on reference hardware |

A "120 Hz" claim is only made for a named device, a named scene and a recorded
measurement.

## 13. Roadmap within the graphics platform

| Step | Deliverable | Depends on |
|---|---|---|
| G0 | KDS model + GOP framebuffer fallback + software composition unchanged | none |
| G1 | virtio-gpu driver, KDS modes, page flip with fence (Tier 1) | IOMMU-less safe path, QEMU validation |
| G2 | KGC memory objects, one queue, fences; KGA `device/queue/buffer/submit` | G1, VMM, interrupts |
| G3 | KWM user-space compositor with damage + frame callbacks (software) | G0, IPC, shared memory |
| G4 | KGA pipeline + shader modules; software renderer parity tests | G2 |
| G5 | 2D/UI layer (KGA-UI) and native desktop shell on KWM | G3, G4 |
| G6 | Intel/AMD display drivers (Tier 1/2) | hardware access, documentation |
| G7 | Vendor 3D drivers, KGA-H, GPU renderer | G2–G4, IOMMU |
| G8 | Profiler, capture, validator, shader inspector | G2 onward |
| G9 | Advanced rendering (RT, GPU-driven) | G7, vendor support |

Each step has acceptance criteria in the
[product roadmap](../roadmap/PRODUCT_ROADMAP.md).

## 14. Open questions

1. SPIR-V as input: adopt, adapt, or define an independent IR first? (ADR-0005)
2. Tile-based vs immediate-mode GPU assumptions in KGA: what is the abstraction
   that does not leak either model?
3. Display colour pipeline: where exactly does tone mapping live when HDR and SDR
   windows share an output?
4. Direct scanout policy: who decides, the compositor or the display service?
5. Multi-GPU offload: explicit copies only, or a transparent render-node model?
6. GPU memory pressure: application-managed residency or compositor-driven?
7. Virtual displays: supported as connectors, and with what capture semantics?
