# Kynox user experiences: one platform, five profiles

- Status: **planning document**. No profile, session policy or requirement below
  is implemented. The tree boots to a software-composited scene with a keyboard
  and a pointer; nothing else in this file exists.
- Date: 2026-10-31.
- Related: [`platform-architecture.md`](platform-architecture.md) §3, §4.15–4.18,
  [`graphics-platform.md`](graphics-platform.md) §9, §12,
  [`application-ecosystem.md`](application-ecosystem.md) §6,
  [`security-architecture.md`](security-architecture.md) §8,
  [`../roadmap/PRODUCT_ROADMAP.md`](../roadmap/PRODUCT_ROADMAP.md) S10–S14.

## 1. The rule that makes profiles safe

Kynox serves home users, gamers, developers, enterprises and professional
applications **from one kernel, one ABI, one graphics stack and one package
format**. A "profile" is a bundle of policy — which services start, how the
session behaves, how often updates land, which capabilities are granted by
default. It is never a different ABI, a different compositor or a different
package format.

| A profile may change | A profile may never change |
|---|---|
| Which services start with the session | The syscall ABI and its revision |
| Session layout, input policy, accessibility defaults | The executable format or package format |
| Update cadence, channels, deferral and rollback policy | The security model, capability semantics, sandbox rules |
| Default capabilities granted to first-party applications | The graphics API surface or its versioning rules |
| Diagnostics verbosity and telemetry defaults (opt-in) | Any persistent on-disk format |

This is what prevents the market's failure mode: separate editions that drift
into incompatible platforms. Any proposal that requires a profile-specific ABI
is rejected and reworked into a policy.

## 2. Profiles at a glance

| Profile | Primary burden | Non-negotiable property | Primary roadmap stages |
|---|---|---|---|
| **Home** | First-hour usability, media, documents | Privacy by default; nothing phones home | S10, S12 |
| **Gaming** | Frame pacing, input latency, driver breadth | Predictability: no scheduler or compositor surprise | S6–S9, S13 |
| **Development** | Build, debug, profile, automate | Reproducibility and observability | S11, S12 |
| **Enterprise** | Fleet control, identity, compliance | Verifiable state, auditable change, fast recovery | S2–S3, S11, S14 |
| **Professional** | Colour, latency, large datasets, GPU compute | Deterministic output and stable performance under load | S7–S9, S14 |

## 3. Home

**Scenario.** Someone installs Kynox on a laptop, signs in, browses, watches
video, writes a document and prints. They never open a terminal.

| ID | Requirement (target, to be measured) | Evidence that would prove it |
|---|---|---|
| HOM-01 | Session reaches the lock screen within 10 s of kernel entry on the reference machine, and the desktop within 15 s | Boot tracer timestamps in the serial log |
| HOM-02 | A cold application start (first `KEX` execution) of a 20 MiB application completes in ≤ 1.5 s including package verification | Session trace with stage marks |
| HOM-03 | 4K video playback at 60 fps with ≤ 5 % dropped frames over a 10-minute sample | Presentation counters from KDS |
| HOM-04 | Sleep/resume returns input within 2 s and leaves no device in a wedged state | Resume log per device, 50-cycle loop |
| HOM-05 | Screen reader and keyboard-only operation cover every first-party surface | Accessibility conformance list per surface |
| HOM-06 | No network traffic leaves the machine without an explicit, recorded consent event | Packet capture + consent log audit |
| HOM-07 | A full-disk-encrypted installation boots without a network and without a vendor account | Installation test matrix |

Concrete architecture consequences: the session must survive compositor restart
(ADR-0006), the package manager must work offline from a local medium (ADR-0007),
and the accessibility layer must live in KWM, not in each application.

## 4. Gaming

**Scenario.** A player runs a modern title at 1440p, 120 Hz, with VRR, a
controller and headphones, while a voice chat application and a browser run in
the background.

| ID | Requirement (target, to be measured) | Evidence |
|---|---|---|
| GAM-01 | Input-to-photon latency p99 ≤ 2 frames at 60 Hz with a single fullscreen window, measured by KGT timestamps | Frame capture with hardware timestamp source |
| GAM-02 | Frame-time 99th percentile within 1.25× of the median over a 5-minute capture | KGT frame profiler export |
| GAM-03 | Scheduler keeps a game's main thread and render thread within 1 ms of wake-up on a busy system | Scheduler trace with 8 background CPU hogs |
| GAM-04 | Direct scanout engages for fullscreen exclusive content, bypassing composition (KDS commit of the client's buffer) | KDS commit log with plane assignment |
| GAM-05 | VRR changes refresh without a visible mode-set or a dropped frame | Display trace |
| GAM-06 | Audio output path reaches ≤ 10 ms round trip in game mode with the low-latency class | Audio service counter |
| GAM-07 | A GPU hang recovers the process in ≤ 2 s without rebooting, and the session survives | Fault-injection test on the driver model |
| GAM-08 | Controller hotplug is detected in ≤ 100 ms and delivered to the focused client | Input trace |

Honest limits: anti-cheat systems that require an unmodified Windows kernel are
**out of scope for the native platform**; they belong to the KWC compatibility
initiative (application-ecosystem §8), which makes no compatibility promise yet.
No "game mode" is claimed to bypass the security model: the game runs sandboxed
like any other application.

## 5. Development

**Scenario.** An engineer clones a repository, builds, runs unit tests, debugs a
crash, profiles a GPU frame and ships a signed package.

| ID | Requirement (target, to be measured) | Evidence |
|---|---|---|
| DEV-01 | SDK installs with one command, needs no network after download, and has zero mandatory runtimes beyond the system libraries | Offline install transcript |
| DEV-02 | A debug build of a mid-size project builds in the same order of magnitude as on Linux on comparable hardware; the ratio is published, not guessed | Reproducible benchmark, both platforms |
| DEV-03 | Every crash produces a symbolized backtrace without debug symbols installed by the user | Crash triage tool run |
| DEV-04 | The SDK ships the KGA validator, KGT capture, a trace viewer and a conformance suite from revision 1 | Tool inventory with test coverage |
| DEV-05 | Builds are reproducible: two clean builds of the same source produce byte-identical outputs | Hash comparison script |
| DEV-06 | A package can be built, signed and installed locally without any store account | End-to-end script |
| DEV-07 | Kernel and service tracing can be enabled per-process at runtime with ≤ 3 % overhead on a measured workload | Trace overhead benchmark |

Concrete consequences: the toolchain is not a service dependency (a developer
environment must survive without the desktop), and `kd`/crash artifacts are
capabilities granted by the developer's own session, not global privileges.

## 6. Enterprise

**Scenario.** An IT team manages 5 000 machines: identity, disk encryption,
policy, staged updates, audit export, remote recovery, and a hypervisor for
legacy workloads.

| ID | Requirement (target, to be measured) | Evidence |
|---|---|---|
| ENT-01 | Device enrolment binds a machine to an identity and a policy set; a machine without policy refuses to join | Enrolment test with an unsigned policy |
| ENT-02 | Full-disk encryption keys are sealed to the measured boot state; changing the boot chain blocks decryption with a recorded reason | Measured-boot tamper test |
| ENT-03 | Updates roll out in rings (canary → 5 % → fleet) with automatic halt on a failed health signal | Update controller test |
| ENT-04 | Rollback to the previous system image completes in ≤ 3 minutes and preserves user data | Recovery test matrix |
| ENT-05 | Every privileged action produces an audit record that survives reboot, exportable without a vendor service | Audit log format + export tool |
| ENT-06 | Application sandbox policy is centrally expressible per package identity, and the local broker enforces it | Policy file → capability grant test |
| ENT-07 | Virtual machines run with hardware-assisted isolation; a guest cannot reach host memory even with a compromised guest kernel | IOMMU/VT-d test with a hostile guest driver |
| ENT-08 | A lost device can be locked and wiped without granting the vendor standing access to the fleet | Enrolment/key escrow design review |

Honest limits: Kynox has no TPM driver, no measured boot, no IOMMU and no
hypervisor today. ENT-02, ENT-07 and ENT-08 are therefore **design targets with
no implementation**, and the security document (§3, §12, §13) lists what would
make each provable.

## 7. Professional applications

**Scenario.** A colourist grades HDR footage, an engineer opens a 20-million
triangle CAD assembly, a researcher runs a compute job on the GPU, a musician
records with a low-latency interface.

| ID | Requirement (target, to be measured) | Evidence |
|---|---|---|
| PRO-01 | End-to-end colour: application → KGA → KDS → panel, with a documented transfer function and no hidden conversion | 10-bit gradient test pattern, measured with a probe |
| PRO-02 | HDR metadata reaches the display or is tone-mapped deterministically, and the policy is visible to the application | HDR toggle test with capture |
| PRO-03 | 10-bit and 16-bit float render targets are supported where the hardware tier allows, and reported honestly by capability query | Format support matrix from KGA |
| PRO-04 | CAD-scale scenes stream without a stall longer than 16 ms during camera motion (allocation policy, residency control) | Frame trace on a 20 M-triangle scene |
| PRO-05 | GPU compute completes with documented memory consistency; a kernel can be cancelled without resetting the device | Compute test suite + cancellation test |
| PRO-06 | Audio capture round trip ≤ 5 ms with a pro interface in the professional audio class | Audio service counter, loopback measurement |
| PRO-07 | A 4-hour render survives a driver reset without losing the job (application-level checkpoint contract) | Reset-injection test |
| PRO-08 | FP64 and large-memory workloads are either supported or explicitly refused by capability query — never silently emulated | Capability report |

## 8. What all profiles share (and must not fork)

| Shared contract | Why it cannot be per-profile |
|---|---|
| Input model and event delivery | A game, an editor and a spreadsheet need the same focus semantics |
| Accessibility tree and assistive API | Retrofitting it per profile is how platforms fail users |
| Colour pipeline and HDR policy | Two paths would produce two different pictures |
| Package format and sandbox | Enterprises must run the same packages home users run |
| Update mechanism and rollback | Recovery is not an enterprise-only feature |
| Power management and thermal policy | Laptops ship to every profile |
| Internationalisation, keyboard layouts, IME | Text input is not a "desktop feature" |

Profiles are expressed as **policy data** consumed by the same services —
session manager, package manager, broker, updater — never as alternate code
paths. The roadmap treats a profile as accepted only when its requirements run
on the same binaries as every other profile.

## 9. Mapping to stages and acceptance

| Profile | Stage where it first becomes testable | Stage that makes it usable |
|---|---|---|
| Home | S10 (desktop/session) | S12 (native applications) |
| Gaming | S9 (compositor) | S13 (gaming features) |
| Development | S11 (SDK/tools) | S12 |
| Enterprise | S3 (capabilities/process model) | S14 |
| Professional | S8 (renderer) | S14 |

A stage is not accepted for a profile until the profile's requirements for that
stage have a measurement method. Requirements without a measurement method stay
in this document and block the profile, visibly.

## 10. Open questions

1. Is "game mode" a session policy or a separate session type with its own
   compositor instance? (Affects direct scanout and input routing.)
2. How does enterprise policy reach the broker without becoming a capability
   that bypasses user consent?
3. Which accessibility APIs must exist in revision 1 of KWM so that third-party
   toolkits do not invent their own?
4. Does the professional audio class require a separate real-time service, or a
   priority class inside one audio graph service?
5. What is the minimum hardware tier a profile may require — and is that tier
   part of the product definition or a documented exception?
