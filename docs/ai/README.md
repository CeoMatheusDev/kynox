# Documentation for agents — start here

This directory exists for one reader: an agent (or a person in a hurry) that has
to work on this repository without reading 50 000 words first. It answers three
questions, in this order:

1. **What is true right now?** → [`context-pack.md`](context-pack.md)
2. **Where do I read the detail?** → [`doc-index.json`](doc-index.json)
3. **What am I not allowed to do?** → the rules below, and
   [`../../AGENTS.md`](../../AGENTS.md), which is binding

The bundle is small on purpose. It is not a summary of the documentation; it is
the index and the entry conditions of it.

## 1. The order to read, and what each step costs

| Step | Document | Why | ~words |
|---|---|---|---:|
| 1 | [`../../AGENTS.md`](../../AGENTS.md) | The contract: toolchain, what counts as validation, the vocabulary of the status, the claims that are prohibited | 3 000 |
| 2 | [`context-pack.md`](context-pack.md) | The state of the tree in one page: commands, counts, matrix, open defects, invariants | 1 500 |
| 3 | [`../PROJECT_STATUS.md`](../PROJECT_STATUS.md) | The evidence-based inventory: per subsystem, what exists, what limits it | 6 000 |
| 4 | The record of the area you are about to touch | What was implemented there, with the command and the result | 1 500–3 000 |
| 5 | The architecture document of the area | The model the code is supposed to follow | 3 000–8 000 |
| 6 | [`../roadmap/KERNEL_COMPLETION_ROADMAP.md`](../roadmap/KERNEL_COMPLETION_ROADMAP.md) | The plan of record for kernel work, stage by stage | 12 000 |

Then work. The remaining documents — the audits, the strategy, the market
research, the ADRs, the compatibility work — are read **when the task names
them**, and `doc-index.json` says which of them are history.

## 2. Authority: what you may do with a document

Every entry of [`doc-index.json`](doc-index.json) carries an `authority` field.
It is the answer to "may I quote this as the state of the tree?".

| Authority | Meaning for an agent |
|---|---|
| `binding` | Rules. A change that violates one is wrong, even if it makes tests pass. |
| `current` | Describes the tree today. Numbers about the tree come from here, and only from here. |
| `record` | What was implemented, dated, with the evidence of each claim. Quote it as history with a date. |
| `audit` | An observation of a past tree. Useful for finding what was wrong then; never a statement about now. |
| `planning` | A plan. **Never** a source of numbers about the tree, and never a claim that something exists. |
| `decision` | An ADR: why a choice was made and what it rules out. Binding on design, not a state claim. |
| `reference` | A specification or a procedure that the code has to satisfy. |

The three status files are the only place where a percentage, a test count or an
"implemented" claim lives, and they must always agree with each other:

- [`../PROJECT_STATUS.md`](../PROJECT_STATUS.md) — human-readable inventory;
- [`../PROJECT_STATUS.json`](../PROJECT_STATUS.json) — the same inventory,
  machine-readable, consumed by tests;
- [`../../README.md`](../../README.md) — the public matrix, a projection of the
  two above.

## 3. Hard rules (the ones an agent breaks first)

1. **A compile is not a run and a host test is not a boot.** With no
   `qemu-system-x86_64` and no OVMF in this environment, every runtime claim is
   `not_executed`. Say `host_tests_passed`, or say nothing.
2. **No number without a command.** "781 tests" is only true with the
   `zig build test --summary all` line that produced it, on the tree you have.
   If you change the tree, the number changes; measure it again.
3. **A percentage moves only with capability, and it moves in all three files at
   once.** Percentages are subsystem engineering maturity, never the share of a
   finished OS.
4. **A planning document is not evidence.** The audits of 2026-10-31 are
   history; the `AUDIT_K3.12.*` reports come from another working copy and carry
   a header that says so. Nothing in them is counted.
5. **Dead code is a claim.** A file that no target reaches, a stub that returns
   success without doing anything, a test that asserts `true` — those are
   defects, and the honest fix is deletion or an explicit error, not a comment.
6. **Documentation is part of the change.** A behaviour change without the
   matching entry in the status files, the CHANGELOG and the architecture
   document is an incomplete change.

## 4. The commands, and what each one proves

| Command | Proves | Cost |
|---|---|---|
| `zig build` | the kernel, the bootloader and the image still compile and link | ~20 s |
| `zig build test --summary all` | every host artifact, the documentation links and the structural guards | ~30 s |
| `zig build docs-check` | every relative Markdown link resolves | <1 s |
| `python3 tools/scripts/gen-doc-index.py --check` | every document is classified and the index matches the tree | <1 s |
| `zig build qemu-test`, `qemu-storage-test`, `qemu-interactive-test` | a real boot | **not available here** |

The toolchain is Zig 0.17.0 exactly; `/tmp/zigdist/ziglang/zig` in the sandbox,
`zig` on a machine that has it. A different version is a different tree.

## 5. Where to add a document

1. Create the file under the right directory — `architecture/` for models,
   `roadmap/` for plans, `audits/` for observations and implementation records,
   `decisions/` for ADRs, `specs/` for contracts, `validation/` for procedures.
2. Start it with `# Title`, and, if it is a plan or a record, a `- Status:` line
   that says which of the two it is.
3. Add it to the `DOCUMENTS` table of
   [`../../tools/scripts/gen-doc-index.py`](../../tools/scripts/gen-doc-index.py)
   with `kind`, `authority` and a one-line `summary`.
4. Run `python3 tools/scripts/gen-doc-index.py`.
5. Run `zig build test`: the index conformance tests fail until step 3 is done,
   which is the point — a new document cannot become invisible.

## 6. What this bundle does not do

It does not summarise the architecture, and it does not replace the documents.
An agent that reads only this directory can say what the tree does today; to
change it, it still has to read the document of the area it touches.
