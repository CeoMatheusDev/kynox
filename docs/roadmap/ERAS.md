# Kynox generations and eras

> Normative chart of the official names. The same table lives in `version.zig`
> (`generations`); `version-tests` fails if the two disagree.

## 1. Chart

| Major | Official name |
|---|---|
| 0 | Kynox One |
| 1 | Kynox Quark |
| 2 | Kynox Photon |
| 3 | Kynox Atom |
| 4 | Kynox Molecule |
| 5 | Kynox Crystal |
| 6 | Kynox Asteroid |
| 7 | Kynox Comet |
| 8 | Kynox Planet |
| 9 | Kynox Star |
| 10 | Kynox Pulsar |
| 11 | Kynox Nebula |
| 12 | Kynox Galaxy |
| 13 | Kynox Quasar |
| 14 | Kynox Cosmos |

The chart stops at 14. A major above 14 has no name and is rejected; it is not
numbered ahead of a decision.

## 2. Rules

1. **Major `0` is Kynox One.** Every `0.x.y` version belongs to Kynox One, the
   initial generation of development and stabilization of the operating system.
   `0.1.0-alpha.1`, `0.1.0` and `0.7.0` are all Kynox One.
2. **From major `1`, each major is an era** with its own name. The name is
   constant for the whole major: every `1.x.y` is Kynox Quark, every `2.x.y` is
   Kynox Photon.
3. **The name is resolved, never typed.** `version.zig` maps the major to the
   table; components print `Kynox [Generation] [VERSION]` from the module.
4. **A major without a name is an error**, not a new invention. Adding a
   generation means editing the chart here and in `version.zig` in the same
   change, with a test proving they match.
5. **A major is not a milestone checklist.** Moving to the next era is a
   compatibility decision: the previous major's contract is broken on purpose.
   Completing features or fixing bugs inside a major changes MINOR, PATCH or the
   prerelease only.

## 3. State of the chart

| Major | Name | State |
|---|---|---|
| 0 | Kynox One | **current** — `0.1.0-alpha.1`, initial development |
| 1–14 | Kynox Quark … Kynox Cosmos | reserved names, no dates and no promised scope |

Reserving a name is not a roadmap commitment: nothing about the schedule,
features or quality of a future era is implied by the chart.

## 4. Adding a generation

1. A written decision (ADR under `docs/decisions/`) explains why the major is
   being opened and what contract breaks.
2. Add the row to the chart in this file **and** the entry to `generations` in
   `version.zig`, with the same text.
3. `VERSION` moves to the new major only in the release commit that opens the
   era; the tag follows the release procedure in `docs/VERSIONING.md` §7.
4. Run `zig build test`: the chart/document agreement test, the uniqueness test
   and the name-resolution tests must pass.
