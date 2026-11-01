# Kynox — Market Landscape and Technology Analysis

- Status: **planning document**, not an implementation claim.
- Date: 2026-10-31. All sources were accessed on that date.
- Scope: desktop operating systems, graphics stacks, GPU driver models, gaming, security,
  packaging/update, multimedia and developer tooling.
- Companion documents: [`platform-architecture.md`](../architecture/platform-architecture.md),
  [`graphics-platform.md`](../architecture/graphics-platform.md),
  [`application-ecosystem.md`](../architecture/application-ecosystem.md),
  [`security-architecture.md`](../architecture/security-architecture.md),
  [`PRODUCT_ROADMAP.md`](../roadmap/PRODUCT_ROADMAP.md).

> **How to read this document.** Facts carry a source marker `[S#]` resolved in
> §9. Recommendations are explicitly labelled *Recommendation* or *Opinion* and
> are the project's judgement, not a fact about the market. Nothing here changes
> the implementation status recorded in [`PROJECT_STATUS.md`](../PROJECT_STATUS.md):
> Kynox today has **no GPU driver, no display-controller abstraction, no audio
> stack and no network stack**.

## 1. Why a market analysis exists in an operating-system repository

An operating system is a product decision before it is a kernel. The same kernel
can serve a console-like gaming device, a developer workstation or a managed
enterprise fleet; the difference is which contracts, services and guarantees are
built on top. Writing those contracts down after the fact is how systems end up
with a graphics stack that cannot do HDR, an update mechanism that cannot roll
back, or a permission model that cannot sandbox an application without breaking
it.

This document extracts, from the platforms that already solved (or failed at)
these problems, **what is worth building natively, what is worth adopting as an
open interoperability standard, and where a new system can still be materially
better**. It deliberately does not propose copying any of them: the goal is to
identify unresolved problems, not to re-implement features that already exist
elsewhere.

## 2. Market structure

### 2.1 Desktop operating systems

| Platform | Model | Distribution | Relevant strength | Relevant cost |
|---|---|---|---|---|
| Windows 11 | Proprietary, NT hybrid kernel | OEM, retail, enterprise licensing | Application and game ecosystem, driver coverage, tooling (PIX, WDK), backwards compatibility | Very large legacy surface; kernel-mode display drivers; hardware floor (TPM 2.0, UEFI Secure Boot) excludes older machines `[S11]` |
| macOS | Proprietary, XNU hybrid kernel | Apple hardware only | Tight hardware/software co-design, Metal, energy efficiency, coherent security model (SIP, notarization) | Closed ecosystem; no native Vulkan; limited hardware matrix |
| Linux desktop | Open source, many distributions | Distributions, immutable images, OEMs | Open drivers (AMD/Intel; NVIDIA open kernel modules), full customisation, no vendor lock-in | Fragmentation of desktop stacks, late HDR/colour management, driver quality variance |
| SteamOS 3 | Open source, Arch-based, curated image | Valve devices and selected OEM handhelds | Console-like experience on PC hardware, Proton compatibility, gamescope presentation | Gaming-first; not a general desktop or professional platform |
| ChromeOS | Proprietary with open-source core | OEM devices, education/enterprise | Managed, verified boot, low maintenance | Browser-centric; limited native application model |

Two structural facts shape the market more than any feature list:

1. **The application ecosystem is the moat.** Users choose a platform for the
   applications and games that run on it, not for the kernel. A new system must
   either attract native applications with materially better economics
   (performance, security, tooling) or run existing binaries through a
   compatibility personality — and Kynox treats the latter as an explicit,
   isolated, staged initiative, never as the foundation.
2. **Desktop share is small and measurement is noisy.** StatCounter-derived
   figures put desktop Linux between roughly 3% and 5% depending on month and on
   how the growing "unknown" bucket is handled `[S15]`. The practical lesson is
   not the exact number: it is that **a niche platform can be viable when it
   serves a well-defined segment extremely well** (SteamOS for handheld gaming
   being the clearest recent example).

### 2.2 Where a new platform can still win

| Segment | Incumbent weakness | Kynox opportunity |
|---|---|---|
| Gaming on PC | Windows overhead and driver variance; Linux gaming depends on translation layers and per-title tuning | Predictable frame pacing, explicit scheduling classes, first-class capture/profiling, validated GPU submission |
| Professional creation | Driver and colour-management complexity; HDR/colour pipelines differ per OS | One colour pipeline from display to compositor to application, with HDR and wide gamut as first-class concepts |
| Security-sensitive users | Large legacy attack surface; kernel-mode vendor drivers | Capability-mediated devices, user-space drivers where IOMMU exists, validated command submission |
| Developers | Tooling split across vendors and platforms | Integrated shader compiler, GPU debugger, capture/replay and validation layers in the SDK |
| Managed fleets | Update and rollback semantics vary; policy engines are bolt-ons | Immutable base, atomic updates with rollback, policy as a first-class service |
| Older/varied hardware | Vendor support windows drop hardware quickly | Explicit hardware tiers with an honest, published support matrix and a working software fallback |

## 3. Technology deep dive

Each subsection follows the same structure: the problem, how the technology
solves it architecturally, strengths, costs, the opportunity for Kynox, what to
build natively and what to adopt as an open standard.

### 3.1 Display and compositing

**Problem.** Getting pixels from many applications to one or more displays with
correct colour, timing, scaling and isolation, without letting a client corrupt
the screen or starve the system.

**How the incumbents do it.**
- Windows: a kernel-mode display miniport driver (KMD) plus a user-mode display
  driver (UMD), coordinated by the DirectX graphics kernel subsystem
  (`Dxgkrnl`); the Desktop Window Manager composes in user space on top of the
  kernel's flip/present machinery `[S9][S10]`.
- Linux: DRM/KMS in the kernel owns connectors, CRTCs, planes and framebuffers;
  user-space compositors (KWin, Mutter, wlroots-based) implement the policy and
  the client protocol; presentation is page-flipped with fences.
- SteamOS: gamescope, a purpose-built micro-compositor, sits between games and
  the display to control scaling, frame limiting and HDR `[S4][S8]`.

**Strengths.** The kernel/user split works: the kernel proves *ownership and
timing*, user space decides *layout and policy*. Fences and page flips make
tearing-free presentation measurable and testable.

**Costs.** HDR and colour management arrived late and inconsistently on Linux,
with vendor-specific protocols before a standard one existed `[S4][S5][S6]`.
Fractional scaling and multi-monitor mixed-refresh setups remain a source of
bugs on every platform. A compositor crash must not take the session with it,
which most designs handle only partially.

**Opportunity for Kynox.** Define the colour pipeline (SDR/HDR, transfer
functions, primaries, luminance) **in the display contract itself**, not as an
afterthought in the compositor. Make per-surface colour and per-output colour
capability exchange part of the protocol, so applications never guess. Specify
frame pacing and latency budgets as a contract between compositor and display
service.

**Build natively / adopt as standard.**
- Native: the display-controller abstraction, the surface/fence protocol and the
  compositor service.
- Adopt: EDID/DisplayID parsing rules, CTA-861 colour metadata, and the general
  concept of atomic mode-setting (a public kernel interface pattern, reimplemented,
  not imported).

### 3.2 Graphics APIs

**Problem.** Give applications explicit control of the GPU with low CPU overhead,
predictable performance across vendors, and enough structure that drivers can be
validated.

**How the incumbents do it.**
- Vulkan: explicit objects, command buffers recorded by the application,
  pipelines pre-baked, descriptor sets, explicit synchronisation; the 1.4
  revision (December 2024) promoted many previously optional features and
  streaming requirements into the core `[S1]`.
- Direct3D 12: comparable explicit model with a strong tooling story (PIX),
  driver model integration through WDDM, and OS-level features such as
  DirectStorage for I/O.
- Metal: explicit model tuned for Apple GPUs, with Metal 4 (June 2025) adding a
  unified command-encoder model, tensor types for on-GPU machine learning and
  frame interpolation/denoising in MetalFX `[S2][S3]`.

**Strengths.** All three converge on the same insight: **the application owns
synchronisation and resource lifetime; the driver validates and executes**.
Tooling compatibility (SPIR-V, DXIL, Metal Shading Language) is what makes the
model usable at scale.

**Costs.** The explicitness is a heavy burden for small applications: hundreds of
lines to draw one triangle, and a class of bugs (barriers, layouts, lifetimes)
that only expert tooling reveals. Each API also carries historical baggage.

**Opportunity for Kynox.** Two layers, one core:
1. a low-level API with explicit resources, queues, fences and pipelines —
   conceptually close to Vulkan/D3D12, but with the legacy-free simplifications a
   new system can afford; and
2. an optional higher-level layer (render graph, resource lifetime management,
   default pipelines) that removes the boilerplate for application developers
   without hiding the explicit layer.

**Build natively / adopt as standard.** Native: the API, its object model, its
validation and its tooling. Adopt: **SPIR-V as a shader *input* format** is worth
an explicit ADR, because it buys compiler/tooling interoperability; the internal
IR and the final GPU ISA remain Kynox's own decisions.

### 3.3 GPU driver models

**Problem.** Program increasingly complex GPUs without putting an unbounded,
vendor-supplied binary in the most privileged ring, and without letting one
buggy application hang the machine.

**How the incumbents do it.**
- Windows: split UMD/KMD; the KMD lives in kernel mode and talks to `Dxgkrnl`
  `[S9][S10]`.
- Linux: DRM drivers in the kernel (amdgpu, i915/xe, nouveau, nvidia), with
  substantial firmware blobs; Mesa provides most of the user-space driver.
- NVIDIA: since R515 (2022) an open, dual GPL/MIT kernel-module release exists;
  since R560 (2024) the open modules are the recommended default on Turing and
  newer, and they require the GPU System Processor (GSP) firmware — a RISC-V
  coprocessor on the GPU that runs initialisation and management `[S13]`.
- Apple: a single vendor controls GPU, firmware and driver, which is why Metal's
  model can be tighter than a cross-vendor API.

**Strengths.** The UMD/KMD split allows vendor-specific complexity in user space
while the kernel keeps memory and scheduling control. The GSP model shows that
moving initialisation into firmware can shrink the trusted CPU-side code.

**Costs.** Kernel-mode vendor drivers are a large attack surface and a stability
risk. Firmware blobs are unauditable, non-redistributable in some cases, and
required for modern hardware.

**Opportunity for Kynox.** A **capability-tiered driver model**: the kernel owns
memory objects, page tables, submission rings, fences and reset; vendor logic
runs in a user-space driver process (per device) reached through a narrow,
validated interface, with IOMMU enforcement. Where no IOMMU exists, the driver
stays in the kernel but with a reduced, auditable command interface. The
guarantee to publish is not "secure GPU drivers" but "a documented, testable
trust boundary per tier".

**Build natively / adopt as standard.** Native: the driver interface, the
command-validation model and the reset/recovery protocol. Adopt: PCI/ACPI device
discovery, standard firmware-loading conventions, and vendor-neutral shader
input formats.

### 3.4 Gaming and low latency

**Problem.** Deliver stable frame times and low input-to-photon latency while
other work runs on the same machine.

**How the incumbents do it.** Consoles reserve resources and fix the graphics
pipeline; Windows relies on driver scheduling, Game Mode and increasingly on
DirectStorage; Linux gaming relies on Proton plus a compositor that can bypass
composition for full-screen (gamescope) `[S7][S8]`.

**Strengths.** Direct scanout and frame limiting are the two largest wins.
Compositor bypass removes a full copy and a scheduling hop.

**Costs.** Per-title tuning, anti-cheat compatibility and driver bugs dominate
support cost. HDR, VRR and multi-monitor interactions are fragile.

**Opportunity for Kynox.** Make **frame pacing a scheduler concept**: a
latency-sensitive task class, a display-service deadline model, explicit direct
scanout when the surface matches the mode, and telemetry that attributes missed
deadlines to the responsible stage (application, compositor, driver, display).
Publish the measurement method, not a marketing number.

### 3.5 Security and platform integrity

**Problem.** Prove what booted, isolate applications and drivers, protect
credentials, and recover from compromise.

**How the incumbents do it.** Windows 11 requires TPM 2.0 and UEFI Secure Boot,
and builds Virtualization-Based Security on top `[S11]`. macOS uses SIP,
notarization and per-service privacy permissions. Linux distributions combine
Secure Boot with measured boot (TPM PCRs), LUKS and, increasingly, immutable
images.

**Strengths.** Hardware root of trust plus signed updates is the only chain that
survives an attacker with disk access; measured boot makes remote attestation
possible.

**Costs.** Key management, revocation and recovery flows are where real systems
fail. Secure Boot without a usable recovery path bricks devices; attestation
without privacy design becomes surveillance.

**Opportunity for Kynox.** Design the **verification story** with the feature:
signed boot chain, measured boot, signed packages, atomic rollback, and a
recovery environment that is itself verified. For the graphics stack, define what
a malicious application can do (submit malformed command buffers, map hostile
buffers, attempt screen capture) and prove the boundary with tests.

### 3.6 Updates, packaging and distribution

**Problem.** Deliver software and OS updates safely, atomically and without
breaking user data.

**How the incumbents do it.** Windows uses MSIX/WinGet plus Windows Update;
macOS uses signed app bundles, notarization and system updates; Linux splits
distribution (deb/rpm/Arch), universal formats (Flatpak, Snap, AppImage) and
immutable images (Fedora Silverblue, SteamOS) with atomic updates.

**Strengths.** Atomic, image-based updates with rollback (A/B or snapshot) are
the most robust model for the base system; per-application sandboxes with
mediated portals solve the "application needs my files/screen/microphone"
problem without ambient access `[S12]`.

**Costs.** Flatpak-style portals require a broker per capability and a frontend
per desktop; Snap's centralised store is a governance question; distribution
packaging fragments library versions.

**Opportunity for Kynox.** **One package format, one permission manifest, one
broker.** KPK already exists as a codec; the missing parts are signatures,
dependency metadata, repository protocol and the permission broker. Make
rollback and verification verifiable by test, not by documentation.

### 3.7 Developer tooling

**Problem.** Developers cannot optimise what they cannot see.

**How the incumbents do it.** PIX (Windows/D3D12), Xcode/Metal tools (Apple),
RenderDoc, Vulkan validation layers and GPU vendors' profilers (Linux/Windows).

**Strengths.** A good debugger plus a good capture format creates an ecosystem
faster than documentation does.

**Costs.** Tooling is expensive and vendor-specific; validation layers are often
optional and disabled in production.

**Opportunity for Kynox.** Ship validation **on by default in development
builds**, with a single capture format usable by the debugger, the frame
profiler and the automated regression tests. This is both a developer
convenience and a security mechanism: the same validator that reports a bad
barrier can reject a malformed command buffer.

### 3.8 Multimedia

**Problem.** Route audio and video with low latency, per-application volume and
device hotplug, without a global mixer that blocks.

**How the incumbents do it.** Windows uses the audio engine (WASAPI) with
per-session streams; macOS uses Core Audio with a HAL; Linux has moved to
PipeWire as a graph-based media server replacing PulseAudio and JACK, with
MIDI 2.0 support added in 1.4 (March 2025) `[S14]`.

**Strengths.** A graph model with explicit links handles pro-audio and consumer
use in one server; per-client streams allow routing and privacy controls.

**Costs.** Latency versus power trade-offs; device hotplug and format negotiation
are hard; pro-audio users need deterministic scheduling.

**Opportunity for Kynox.** Design audio as a **user-space graph service** from
the start, with a latency class negotiated per stream and a capture/playback
permission model integrated with the application broker.

### 3.9 Virtualization and enterprise

**Problem.** Run untrusted workloads, manage fleets, and prove compliance.

**How the incumbents do it.** Hyper-V/VBS on Windows, virtualization.framework on
macOS, KVM on Linux, plus MDM/Intune-style management planes.

**Strengths.** Hardware virtualization plus IOMMU is the strongest isolation
primitive available on x86_64.

**Costs.** Management planes are platform-specific and expensive to build; users
resent telemetry that is not transparent.

**Opportunity for Kynox.** Treat virtualization as a consumer of the same
capability model (a VM is a process with memory and device capabilities), and
make telemetry **opt-in, local-first and inspectable**, with no silent upload.

## 4. Cross-platform patterns worth internalising

| Pattern | Where it appears | What it tells Kynox |
|---|---|---|
| Kernel proves ownership and timing; user space decides policy | DRM/KMS + compositors, Dxgkrnl + DWM | Keep the privileged part minimal and mechanical |
| Vendor logic behind a narrow validated interface | UMD/KMD, Mesa Gallium, GSP firmware | Isolate vendor code; validate commands at the boundary |
| Explicit synchronisation wins | Vulkan, D3D12, Metal | Fences/timelines are the contract, not callbacks |
| Colour and HDR belong in the display contract | Late Linux work, Metal/Windows pipelines | Do not bolt colour on later |
| Atomic, image-based updates with rollback | SteamOS, Silverblue, macOS | Make rollback a tested path, not a hope |
| Mediated capabilities instead of ambient access | Flatpak portals `[S12]`, Windows/macOS permissions | A broker per capability is the sandbox model |
| Tooling defines adoption speed | PIX, RenderDoc, validation layers | Build the debugger with the API |
| Firmware is part of the architecture | GSP, AMD/Intel firmware | Treat firmware loading and versioning as a first-class subsystem |

## 5. Where Kynox should not compete

- **Raw hardware coverage at launch.** Supporting every GPU is a decade-long
  effort. A published tier matrix with a working software fallback is honest and
  usable.
- **Re-implementing the Windows or Linux application ecosystems.** These are
  compatibility personalities, staged and isolated, never the foundation.
- **A proprietary store as the only distribution channel.** Signing and
  verification matter; a single gatekeeper contradicts the project's philosophy.
- **Benchmark marketing.** Every performance claim must come with a scenario, a
  baseline and a measurement method.

## 6. Strategic opportunities (ranked)

1. **Security-first graphics submission** — validated command buffers, per-process
   GPU address spaces, IOMMU-backed user-space drivers. No mainstream desktop
   offers this as a *default, documented* contract today.
2. **Colour/HDR/VRR in the display contract** — the area where Linux spent years
   catching up and where Windows/macOS implementations remain opaque.
3. **Frame pacing as a scheduler primitive** — a measurable gaming differentiator
   that also benefits audio and real-time workloads.
4. **Integrated tooling** — validation, capture, profiling and shader inspection
   in one SDK; lowers the cost of writing native applications.
5. **Verified, atomic updates with rollback** — enterprise and consumer trust.
6. **Capability-brokered sandboxing** — applications request files/screen/audio
   through a broker; the kernel enforces, the broker mediates, the user decides.
7. **Honest hardware tiers** — a documented matrix and a software renderer that
   works everywhere, instead of claiming universal support.

## 7. Risks of the strategy

| Risk | Why it matters | Mitigation |
|---|---|---|
| GPU vendor documentation and firmware | Modern GPUs need blobs; open documentation varies by vendor | Start with virtual GPUs (virtio-gpu) and Intel/AMD open stacks; treat NVIDIA as a later, larger effort |
| Anti-cheat and DRM | They depend on Windows-specific behaviour and kernel drivers | Out of scope for the native platform; compatibility is a separate, staged effort |
| API complexity | A Vulkan-class API is a multi-year project | Ship a small core first (2D, textures, one queue), grow by capability tiers |
| Ecosystem gravity | Applications follow users, users follow applications | Native SDK + tooling + compatibility personalities as a bridge |
| Security claims outpacing evidence | A "secure" claim without tests damages credibility | Threat model per subsystem; tests that demonstrate each property |
| Scope explosion | Every subsystem in §3 is itself a project | The roadmap orders by dependency and cuts scope per stage |

## 8. Decisions this analysis recommends (inputs to ADRs)

1. **Graphics split:** minimal kernel graphics core (display, memory objects,
   submission, fences, reset) plus user-space vendor drivers behind a validated
   interface, with IOMMU required for the user-space tier — *ADR-0004*.
2. **Native API shape:** one explicit low-level API with capability tiers, plus
   an optional higher-level layer; SPIR-V as an input format to be decided
   separately — *ADR-0005*.
3. **Compositor:** user-space compositor service with a kernel-mediated
   presentation path; no compositing policy in the kernel — *ADR-0006*.
4. **Distribution:** single signed package format, permission manifest and
   mediation broker, atomic updates with rollback — *ADR-0007*.

## 9. Sources

All URLs accessed **2026-10-31**. "Page date" is the date printed by the source
(publication or last update); where the source is secondary, the primary fact is
marked as such in the text.

| # | Source | URL | Page date | Nature |
|---|---|---|---|---|
| S1 | Khronos / Vulkan 1.4 release announcement (community mirror of the press release) | https://community.khronos.org/t/khronos-releases-vulkan-1-4/111441 | 2024-12-02 | Primary announcement (mirrored) |
| S2 | Metal (API) — version history | https://en.wikipedia.org/wiki/Metal_(API) | 2026-10-30 | Secondary encyclopaedic |
| S3 | Developer-Tech — "Apple fuses AI with graphics in Metal 4 overhaul" | https://www.developer-tech.com/news/apple-fuses-ai-with-graphics-metal-4-overhaul/ | 2025-06-10 | Secondary reporting of WWDC 2025 |
| S4 | ArchWiki — HDR (gamescope, colour protocols) | https://wiki.archlinux.org/title/HDR | 2026-09-11 | Community documentation |
| S5 | Linuxiac — Chromium HDR on Wayland | https://linuxiac.com/linux-gets-hdr-support-in-chromium-on-wayland/ | 2025-08-20 | Secondary reporting |
| S6 | Phoronix — Hyprland 0.47 HDR/colour management | https://www.phoronix.com/news/Hyprland-0.47-Released | 2025-01-27 | Secondary reporting |
| S7 | Steamworks — Steam Deck FAQ (Proton, immutable OS, Linux base) | https://partner.steamgames.com/doc/steamdeck/faq | 2022-10-21 | Primary vendor documentation |
| S8 | PC Guide — SteamOS 3.7.8 stable, Legion Go S support | https://www.pcguide.com/news/valve-makes-steamos-on-legion-go-s-official-and-even-more-handhelds-are-getting-support/ | 2025-05-23 | Secondary reporting |
| S9 | Microsoft Learn — WDDM architecture (UMD/KMD, Dxgkrnl) | https://learn.microsoft.com/en-us/windows-hardware/drivers/display/windows-vista-and-later-display-driver-model-architecture | n/a (living doc) | Primary vendor documentation |
| S10 | Microsoft Learn — Migrating to WDDM | https://learn.microsoft.com/en-us/windows-hardware/drivers/display/migrating-to-the-windows-vista-and-later-display-driver-model | 2024-08-22 | Primary vendor documentation |
| S11 | Microsoft — Windows 10 end of support / Windows 11 requirements | https://www.microsoft.com/en-us/windows/end-of-support | n/a (living page) | Primary vendor page (requirements summarised in §2.1 and §3.5) |
| S12 | XDG Desktop Portal — documentation | https://flatpak.github.io/xdg-desktop-portal/docs/ | n/a (living doc) | Primary project documentation |
| S13 | NVIDIA — open GPU kernel modules (R515 2022, R560 default) | https://github.com/NVIDIA/open-gpu-kernel-modules | n/a (living repo) | Primary vendor repository; release history corroborated by secondary reporting |
| S14 | heise online — PipeWire 1.4 (MIDI 2.0, codecs) | https://www.heise.de/en/news/Linux-multimedia-framework-Pipewire-1-4-MIDI-2-and-new-audio-codecs-10314034.html | 2025-03-12 | Secondary reporting |
| S15 | StatCounter desktop OS share, as summarised by Fosspost | https://fosspost.org/linux-market-share-statistics/ | 2026-05-22 | Secondary aggregation of StatCounter |

### Limits of this analysis

- Vendor documentation changes; a "living doc" has no stable page date.
- Market-share figures measure web traffic, not installed base, and are distorted
  by privacy tooling and the "unknown" bucket `[S15]`.
- Metal, WDDM and D3D12 internals are described from public documentation and
  reporting; no vendor source was consulted.
- No benchmark was executed for this document. Performance statements are
  architectural reasoning, not measurements.
- The analysis covers desktop and workstation use; server, mobile and embedded
  markets were not studied and Kynox makes no claim about them.
