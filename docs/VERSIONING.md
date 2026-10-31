# Kynox versioning and identity policy

> How Kynox numbers releases, names generations and keeps the four version lines
> apart. This document is normative for `version.zig`, `VERSION`,
> `shared/syscall_abi.zig` and the binary-format headers.

Current identity: **Kynox One 0.1.0-alpha.1** · technical version `0.1.0-alpha.1` ·
tag `v0.1.0-alpha.1` · channel `alpha`.

## 1. Two forms of the same release

| Form | Shape | Example |
|---|---|---|
| Technical | `MAJOR.MINOR.PATCH-PRERELEASE` (SemVer 2.0.0) | `0.1.0-alpha.1` |
| Public | `Kynox [Generation] [VERSION]` | `Kynox One 0.1.0-alpha.1` |

The technical form is what files, tags, manifests and `VERSION` contain. The
public form is what banners, release titles and user-facing text show. The
public form is never stored: it is generated from the technical version by
resolving the generation name of its major number.

## 2. Single source of truth: `VERSION`

`VERSION` at the repository root contains the technical version and a single
trailing newline:

```
0.1.0-alpha.1
```

Rules:

1. `VERSION` is the only place a human edits the version.
2. `version.zig` embeds the file at compile time and derives everything else:
   parsed SemVer, components, channel, tag, generation, public name, banners.
3. `build.zig.zon` repeats the version because the package manifest is another
   language and the build graph cannot read `VERSION` from it; a test fails when
   the two disagree. This is a guarded mirror, not a second source.
4. No kernel, bootloader, SDK or tool file may spell the version, the tag or the
   generation name. A test inspects those sources and fails if one does.
5. A malformed `VERSION` fails the compilation — there is no build of Kynox with
   an unparseable version.

## 3. Generations and eras

The major number selects the generation. Major `0` is the initial generation,
`Kynox One`; from major `1` each major is its own era. The name stays constant
inside a major and changes only with the major. The normative chart lives in
`version.zig` (`generations`) and in [`docs/roadmap/ERAS.md`](roadmap/ERAS.md);
a test keeps the two identical.

Examples:

| Version | Public name |
|---|---|
| `0.1.0-alpha.1` | Kynox One 0.1.0-alpha.1 |
| `0.1.0` | Kynox One 0.1.0 |
| `0.7.0` | Kynox One 0.7.0 |
| `1.0.0-alpha.1` | Kynox Quark 1.0.0-alpha.1 |
| `1.0.0` | Kynox Quark 1.0.0 |
| `2.0.0` | Kynox Photon 2.0.0 |
| `8.0.0` | Kynox Planet 8.0.0 |
| `14.0.0` | Kynox Cosmos 14.0.0 |

A major without a name in the chart is **rejected**, at compile time for this
tree (`VERSION` with an unnamed major does not build) and at run time for any
lookup (`error.UnnamedGeneration`). The build never invents a name from the
number, and a new generation requires a deliberate edit of the chart in both
places.

## 4. Semantic Versioning 2.0.0

SemVer is preserved in full:

| Field | Changes when |
|---|---|
| `MAJOR` | incompatible change on the stable line; opens a new generation |
| `MINOR` | compatible functionality added |
| `PATCH` | compatible fixes only |
| `PRERELEASE` | `alpha.N`, `beta.N`, `rc.N` cycles before a stable release |

`0.x` versions may still break compatibility, as pre-1.0 SemVer allows. A major
bump is a statement about the compatibility contract, **not** a claim that the
technical goals of a generation are complete; conversely, finishing goals does
not bump the major by itself.

Channels implied by the prerelease identifiers:

| Channel | Meaning | Exit criteria |
|---|---|---|
| `alpha.N` | architecture and interfaces may change | reproducible build, documented limitations, no runtime claim without a recorded run |
| `beta.N` | planned scope integrated | interfaces stabilized, integration tests executed |
| `rc.N` | scope frozen | no blocking defects, release build and tests approved |
| stable | release | documented validation, published compatibility and limitations |

## 5. Four version lines that must not be confused

| Line | Single source | Changes when | Example |
|---|---|---|---|
| **System version** | `VERSION` → `version.zig` | the product is released | `0.1.0-alpha.1` |
| **Generation / era identity** | major of the system version + chart | the major changes | `Kynox One` |
| **Native ABI revision** | `shared/syscall_abi.zig` (`version`) | the meaning of the user/kernel contract changes | `1` |
| **Binary format versions** | one field per format header | a stored/transported layout changes | handoff `1`, KEX v1, KPK, KNV |
| **Internal protocol versions** | the protocol's own header | a kernel-internal exchange changes | virtqueue/KVDI structures, KNB fields |

Consequences:

- The system version is **never** encoded into a wire structure, an ABI field or
  a persistent format. Coupling a release number to a stored layout would make
  every release a format change.
- An ABI revision does not follow the system version: `Kynox One 0.1.0-alpha.1`
  ships ABI revision 1, and ABI revision 2 can ship inside `0.2.0`.
- A generation name is not an ABI or format version either; it is a label
  derived from the major, used for communication.

## 6. Release tags and public names

| Tag | Public name |
|---|---|
| `v0.1.0-alpha.1` | Kynox One 0.1.0-alpha.1 |
| `v0.1.0` | Kynox One 0.1.0 |
| `v1.0.0-alpha.1` | Kynox Quark 1.0.0-alpha.1 |
| `v1.0.0` | Kynox Quark 1.0.0 |
| `v2.0.0` | Kynox Photon 2.0.0 |

Tags are `v` + `VERSION`; the public name is generated with the chart, never
typed by hand in the tag. The tag message is
`Kynox v<VERSION>` (for example `git tag -a v0.1.0-alpha.1 -m "Kynox v0.1.0-alpha.1"`).

## 7. Release procedure

1. `zig build` and `zig build test` pass on a clean tree, results recorded.
2. The QEMU suites were executed and recorded in the release notes
   (`docs/BUILD.md`, `docs/validation/qemu.md`).
3. `VERSION` and the mirror in `build.zig.zon` carry the version being released.
4. `CHANGELOG.md` has the section for that version with real validation data.
5. `docs/releases/<version>.md` is complete.
6. `docs/PROJECT_STATUS.md` and `.json` show the same identity and state.
7. The working tree is clean; the commit is recorded in the notes.
8. `git tag -a v<VERSION> -m "Kynox v<VERSION>"` — only with maintainer
   authorization, as is pushing the tag and publishing the release.
9. Never force or rewrite a published tag.

## 8. What the tests guarantee

Every guard below runs in `zig build test` (`version-tests`).

| Guard | Fails when |
|---|---|
| `VERSION` is canonical (one trailing newline, no padding) | the file was reformatted or edited by hand with extra whitespace |
| `VERSION` is valid SemVer | an invalid version was written (also a compile error) |
| The parsed components, tag, channel and public name agree with `VERSION` | a derived value drifted |
| Major `0` resolves to `Kynox One` | the initial-generation rule was broken |
| All majors `0`–`14` map to the published names, contiguous and unique | the chart was edited inconsistently |
| Majors without a name are rejected | someone tried to resolve `15+` and expected a fallback |
| The public name of arbitrary versions resolves through the chart | the resolution was special-cased to the current version |
| `docs/roadmap/ERAS.md` contains a row for every generation | the document and the chart diverged |
| `docs/VERSIONING.md` states the current identity | the document was not updated |
| `build.zig.zon` agrees with `VERSION` | the mirror was not updated |
| No component source spells the version, tag or generation | a literal was introduced outside the single source |

The ABI side has its own guard: `abi_conformance.zig` compares the contract,
the kernel dispatch, the SDK and `docs/specs/syscall-abi.md`.
