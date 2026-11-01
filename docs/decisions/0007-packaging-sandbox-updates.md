# ADR-0007 · Packaging, sandbox and updates: one signed format, one broker, atomic rollback

- Status: **accepted for planning**. No package manager, installer or updater
  exists; KPK is a container codec used for in-image packages.
- Date: 2026-10-31.
- Related: [`application-ecosystem.md`](../architecture/application-ecosystem.md),
  [`security-architecture.md`](../architecture/security-architecture.md) §8–9,
  [`market-landscape.md`](../strategy/market-landscape.md) §3.6.

## Context

A platform lives or dies by how software is installed, updated and contained.
Three market patterns are relevant:

- **Distribution packages** (deb/rpm/Arch): fine-grained but fragmented, weak
  isolation, dependency conflicts.
- **Universal sandboxed packages** (Flatpak/Snap): per-application runtimes and
  mediation through desktop portals `[S12]`; strong isolation, but runtime
  duplication and a centralised store in some cases.
- **Image-based systems** (SteamOS, Silverblue): atomic, rollback-capable base
  system; application distribution is a separate problem.

Kynox needs all three properties: a signed, verifiable package; a base system
that updates atomically and rolls back; and applications that run with the least
authority and ask for more through mediation.

## Options

**A. Adopt an existing package format and store.**
Fast, but ties the platform's trust model and update semantics to an external
project; conflicts with the native-format policy and with the ability to verify
every layer.

**B. Design a native package format with signatures and a permission manifest,
distributed by any signed repository, plus atomic base-image updates.**
Owns the contract, allows local installation, no mandatory gatekeeper.

**C. Ship applications only inside the base image.**
Maximum control, no ecosystem.

## Decision

Adopt **B**, in this order:

1. **Format:** KPK v2 = content-addressed files + signed manifest (Ed25519) +
   declared dependencies + capability requests + entry points. Signatures cover
   the manifest and the content hash; the repository index is signed separately.
2. **Install:** system-wide content-addressed store; packages are immutable once
   installed; running applications are not affected by an update until restart.
3. **Sandbox:** every application starts with no ambient authority; file, screen,
   microphone, camera, input-capture and network access are granted through a
   broker (portal model) with per-request, per-session and persistent grants.
4. **Base updates:** atomic image generation (A/B or snapshot), verified before
   activation, with an automatic rollback after repeated boot failures.
5. **No mandatory store:** any repository signed by a trusted key can be used;
   local installation is a first-class path; the system verifies, it does not
   gatekeep.
6. **Reproducibility:** system components are built reproducibly and their
   provenance is published.

## Consequences

- Positive: one verification chain from boot to application; rollback is a
  tested path; sandboxing is the default rather than a wrapper; no vendor lock-in.
- Negative: the package manager and broker are substantial new components;
  content-addressed storage costs disk space; portal coverage must grow with
  application demand.
- Neutral: Flatpak/portal architecture is a reference, not a dependency.

## Risks

| Risk | Mitigation |
|---|---|
| Sandbox breaks real applications | Portal coverage roadmap; documented escape hatches with user consent |
| Key compromise | Key rotation, revocation list, staged rollout, offline recovery key |
| Rollback loses user data | User data lives outside the system image; backup/restore tested |
| Storage growth | Deduplication, garbage collection of unreferenced versions |

## Reversal criteria

If the broker model cannot cover a class of applications without disabling
isolation globally, add a scoped, auditable policy exception per application
class rather than removing the sandbox. If signature verification cannot be made
reproducible on the target hardware, stop and reassess the signing chain before
shipping updates.
