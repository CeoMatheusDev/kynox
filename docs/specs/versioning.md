# Kynox versioning policy

> How Kynox numbers its releases, its ABI and its binary formats, and where each
> number lives. This document is the reference for `version.zig`,
> `shared/syscall_abi.zig` and the format headers.

## 1. Three independent versions

| Version | Single source | Meaning | Example |
|---|---|---|---|
| **System** | `version.zig` | the product release | `0.1.0-alpha.1` |
| **Native ABI** | `shared/syscall_abi.zig` (`version`) | the user/kernel syscall contract | `1` |
| **Binary formats** | one field per format header | layout of a stored/transported structure | handoff `1`, KEX `1`, KPK, KNV |

They change for different reasons and must never be used interchangeably. A
release may ship ABI revision 1 and handoff version 1; the three numbers do not
have to match, and the system version is **not** encoded into any ABI or format
version.

## 2. System version: single source of truth

`version.zig` at the repository root holds the components:

```zig
pub const major: u16 = 0;
pub const minor: u16 = 1;
pub const patch: u16 = 0;
pub const prerelease: []const u8 = "alpha.1";
pub const build_metadata: []const u8 = "";
```

Everything else is **derived** at compile time:

| Derived | Value | Used by |
|---|---|---|
| `string` | `0.1.0-alpha.1` | banners, `CHANGELOG.md`, release notes |
| `tag` | `v0.1.0-alpha.1` | the Git tag created at release |
| `channel` / `channelName()` | `alpha` | release gating and diagnostics |
| `semver` | parsed `std.SemanticVersion` | compile-time validation |
| `banner(component)` | `Kynox 0.1.0-alpha.1 (KNK)` | boot and tool banners |

Consumers (all through the `kynox_version` module in `build.zig`):

- `boot/uefi/main.zig` — loader banner and `[KNB] system version …` line;
- `kernel/main.zig` — kernel banner and `[KNK] system version … abi …` line;
- `sdk/src/root.zig` — `@import("kynox_version")` as `sdk.version`;
- `tools/fatimg.zig` — `kynox-fsimg --version`.

`build.zig.zon` repeats the version because it is package metadata in another
language. The duplication is guarded: `version.zig` contains a test that reads
`build.zig.zon` and fails if the two disagree, so `zig build test` catches a
mismatch. Editing one without the other is a build failure, not a silent drift.

### Rules

1. Never write the system version as a literal anywhere else. If a new component
   needs it, import the module.
2. Change the components in `version.zig` and the line in `build.zig.zon` in the
   same commit.
3. The in-tree version names the release **being prepared**. A tree that is not
   releasable still reports the upcoming prerelease; the tag is what makes it
   real.

## 3. Semantic versioning and channels

`MAJOR.MINOR.PATCH-PRERELEASE`, [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html),
tags prefixed with `v`.

| Channel | Meaning | Exit criteria |
|---|---|---|
| `alpha.N` | architecture and interfaces may change | reproducible build, documented limitations, no runtime claim without a recorded run |
| `beta.N` | planned scope integrated | interfaces stabilized, integration tests executed |
| `rc.N` | scope frozen | no blocking defects, release build and tests approved |
| stable | release | documented validation, published compatibility and limitations |

Planned sequence: `v0.1.0-alpha.1`, `-alpha.2`, `-alpha.3`, `-beta.1`,
`-beta.2`, `-rc.1`, `v0.1.0`. A release never moves forward because of calendar
time or commit count.

## 4. Release procedure

1. `zig build` and `zig build test` pass on a clean tree (**executed**, results
   recorded).
2. The QEMU suites have been executed and their results recorded in the release
   notes (`docs/BUILD.md` §4–5).
3. `version.zig` and `build.zig.zon` carry the version being released.
4. `CHANGELOG.md` has the section for that version with real validation data.
5. `docs/releases/<version>.md` is complete (commit, requirements, results,
   known issues, gate checklist).
6. `docs/PROJECT_STATUS.md` and `.json` reflect the same state.
7. The working tree is clean; the exact commit is recorded in the notes.
8. `git tag -a v<version> -m "Kynox v<version>"` — only with maintainer
   authorization. Pushing the tag and publishing a release also require it.
9. Never force or rewrite a published tag.

`abi_conformance.zig`, the `version.zig` tests and the boot scripts provide the
automatic guards for steps 1, 3 and 4.

## 5. ABI and format versions

- The ABI revision changes only when the **meaning** of a published call
  changes. Adding a number does not bump it. See
  `docs/specs/syscall-abi.md` §0 and §7.
- Format versions live in their own header (`handoff_version`, KEX/KPK/KNV
  headers) and follow a separate compatibility policy: a reader rejects an
  unknown version instead of guessing.
- No component may embed the system version in a wire structure; doing so would
  couple a release number to a persistent format.

## 6. What the tests guarantee

| Guard | Test | Fails when |
|---|---|---|
| Components and string agree | `version.zig` | a component was edited without the string (impossible by construction) or the tag format drifted |
| `build.zig.zon` agrees with `version.zig` | `version.zig` | the manifest was not updated with the module |
| The string is valid SemVer | `version.zig` (`semver` is evaluated at compile time) | an invalid prerelease was typed |
| The channel matches the prerelease | `version.zig` | `alpha.x` typed with a `beta` channel |
| ABI table, dispatch, SDK and spec agree | `abi_conformance.zig` | any of the four lists drifted |
