#!/usr/bin/env python3
"""Generate and check `docs/ai/doc-index.json`, the machine-readable map of the
documentation of the repository.

The repository has 50+ Markdown files written for humans: audits, planning
records, architecture documents, an ADR set and a status inventory. An agent
that enters the tree has to know, before it reads anything, **which document is
authoritative about what, and which one is history**. This script answers that
question once, in JSON, and keeps the answer in step with the tree.

Rules the script enforces (`--check` mode, which `zig build test` runs):

1. every Markdown file of the tree is classified: a new document that nobody
   classified fails the check, instead of silently becoming invisible;
2. every entry points at a file that exists;
3. every entry carries the metadata the guide needs: `kind`, `authority`,
   `summary`, and the date of the record when it has one;
4. the file on disk is exactly what the script would write, so the index cannot
   drift from the classification table below.

The classification table is the source of truth, not the index: edit the table,
run the script without arguments, and commit both.

Usage:
    python3 tools/scripts/gen-doc-index.py           # write docs/ai/doc-index.json
    python3 tools/scripts/gen-doc-index.py --check   # verify, do not write
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INDEX_PATH = ROOT / "docs" / "ai" / "doc-index.json"

SKIP_DIRS = {".git", ".zig-cache", "zig-out", ".tools", "node_modules"}

# Documents that are not Markdown and still have to be in the map.
EXTRA_FILES = ["LICENSE", "VERSION", "llms.txt", "docs/PROJECT_STATUS.json"]

# The authority of a document is what an agent may do with it.
#
#   binding    the rules of the repository; a change that violates it is wrong
#   current    the description of the tree as it is today
#   record     an implementation record: what was done, with its evidence
#   audit      a read-only observation of the tree at a date
#   planning   a plan: no claim about the tree, and never a source of numbers
#   decision   an ADR: why a choice was made, and what it rules out
#   reference  a specification or a procedure that the code must satisfy
DOCUMENTS: dict[str, dict[str, str]] = {
    # ---------------------------------------------------------------- binding
    "AGENTS.md": {
        "kind": "contract",
        "authority": "binding",
        "summary": "The rules of the repository: toolchain, validation discipline, status vocabulary, prohibited claims, and where progress is recorded.",
    },
    "README.md": {
        "kind": "overview",
        "authority": "current",
        "summary": "Public overview, the subsystem maturity matrix, the executed verification table and the known limitations.",
    },
    "CHANGELOG.md": {
        "kind": "changelog",
        "authority": "current",
        "summary": "What changed, dated, with the command and the result for every claim; the newest entry describes the current tree.",
    },
    "KYNOX_NATIVE.md": {
        "kind": "manifesto",
        "authority": "planning",
        "summary": "The intent of the system: what it wants to be, in prose, with no state claim.",
    },
    "strategy.md": {
        "kind": "strategy",
        "authority": "planning",
        "summary": "Product strategy and positioning; the source of the priorities that the roadmaps order.",
    },
    "LICENSE": {
        "kind": "license",
        "authority": "binding",
        "summary": "GPL-3.0-only; the licence of every file of the tree.",
    },
    # ---------------------------------------------------------------- status
    "docs/PROJECT_STATUS.md": {
        "kind": "status",
        "authority": "current",
        "summary": "The evidence-based inventory: per-subsystem maturity, what is implemented, what limits it, the executed validations and the open findings.",
    },
    "docs/PROJECT_STATUS.json": {
        "kind": "status-machine-readable",
        "authority": "current",
        "summary": "The same inventory in JSON: subsystems, percentages, evidence paths, validations and findings; consumed by tests and by tooling.",
    },
    "docs/BUILD.md": {
        "kind": "procedure",
        "authority": "reference",
        "summary": "How to build the image and the tests with the declared toolchain.",
    },
    "docs/VERSIONING.md": {
        "kind": "procedure",
        "authority": "reference",
        "summary": "The single source of the version, the tag scheme and the rules of a release.",
    },
    # ---------------------------------------------------------------- ai bundle
    "docs/ai/README.md": {
        "kind": "ai-entry-point",
        "authority": "current",
        "summary": "How an agent should read this repository: the order, the authority of each document, the token cost and the hard rules.",
    },
    "docs/ai/context-pack.md": {
        "kind": "ai-context-pack",
        "authority": "current",
        "summary": "One condensed brief of the state of the tree: commands, counts, matrix, open defects and invariants.",
    },
    "llms.txt": {
        "kind": "agent-manifest",
        "authority": "current",
        "summary": "Short manifest for agents and crawlers: the documents that are authoritative today, the ones that are history, and the rule that nothing here is a runtime claim.",
    },
    "VERSION": {
        "kind": "version",
        "authority": "current",
        "summary": "The single source of the version string; every other mention is derived from it and guarded by tests.",
    },
    # ---------------------------------------------------------------- records
    "docs/audits/2026-11-01-msix-table.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "MSI-X: the table in device memory, the size field that stores N-1, the BIR/offset of the table and the PBA, the 16-byte entry, and the enable order that fills the table before any interrupt can leave.",
    },
    "docs/audits/2026-11-01-msi-programming.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "MSI: the message a device writes to interrupt, the layout of its registers (32/64-bit, masking), the order of the writes, the refusal that leaves the capability untouched, and the build flag that decides whether it is programmed.",
    },
    "docs/audits/2026-11-01-bda-and-ebda.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "The firmware data below 1 MiB: the EBDA pointer at 0x40E is a segment, the block of the trampoline has to end at or below it, and a failed read says that it was not checked instead of reporting null.",
    },
    "docs/audits/2026-11-01-halt-ipi-and-fatal.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "The halt IPI (vector 67) and the fatal path: the machine stops as one, the report promises what it can (IPIs delivered, not CPUs stopped), and every fatal halt goes through one module that allocates nothing.",
    },
    "docs/audits/2026-11-01-per-cpu-clock.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "The clock of each processor: the per-CPU role of a clock (system or local), the ledger that counts ticks per CPU, the arming of an AP's local timer from the BSP's measurement, and the counter of ignored ticks.",
    },
    "docs/audits/2026-11-01-tlb-shootdown.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "The TLB shootdown: vector 66, the mailbox that carries the page, the generation that makes a late answer harmless, the page-table hook and the timeout that is reported instead of hidden.",
    },
    "docs/audits/2026-11-01-reschedule-ipi.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "The reschedule IPI (vector 65), the decision that is not a tick, the migration of a task to another CPU and the wake that lands on a foreign queue.",
    },
    "docs/audits/2026-11-01-cpu-affinity.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "Which CPU owns a task: the affinity field the choice respects, one idle task per CPU, and the kernel task that an AP adopts when it enters the scheduler.",
    },
    "docs/audits/2026-11-01-ap-trampoline.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "The block of the AP trampoline as data: the copy below 1 MiB, the fields the BSP writes, the order of the ready word, the EFER bits of the AP and one numbering for the CPUs.",
    },
    "docs/audits/2026-11-01-idle-task-and-per-cpu-tss.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "Per-CPU task state segments and tables with their double-fault stacks, and the idle task of ring 3 that halts when nothing else can run.",
    },
    "docs/audits/2026-11-01-scheduler-lock.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "The state lock of the scheduler: per-CPU ownership, re-entries, the generic blocking primitive and the end-to-end mutex test.",
    },
    "docs/audits/2026-11-01-task-subsystem.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "Policy split, wait queue and mutex: what was implemented, the tests that prove it and what is still open.",
    },
    "docs/audits/2026-11-01-scheduler-tests.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "The host tests of the scheduler policy, and the three preemption defects that writing them exposed.",
    },
    "docs/audits/2026-11-01-kernel-core-fixes.md": {
        "kind": "implementation-record",
        "authority": "record",
        "summary": "The defects of the 2026-10-31 audit that were closed without a hypervisor, with the evidence of each.",
    },
    "docs/audits/2026-10-31-kernel-core-audit.md": {
        "kind": "audit",
        "authority": "audit",
        "summary": "Read-only audit of the kernel and core systems at 343e9fb: classification, ranked defects, evidence level.",
    },
    "docs/audits/2026-10-31-audit.md": {
        "kind": "audit",
        "authority": "audit",
        "summary": "Audit of the tree, the governance and the alpha gate at 343e9fb.",
    },
    "AUDIT_K3.12.3_REPORT.md": {
        "kind": "unverified-report",
        "authority": "audit",
        "summary": "Report from another working copy: kept for the record, carries no evidence and is counted by nothing.",
    },
    "AUDIT_K3.12.4_REPORT.md": {
        "kind": "unverified-report",
        "authority": "audit",
        "summary": "Report from another working copy: kept for the record, carries no evidence and is counted by nothing.",
    },
    "AUDIT_K3.12.5_REPORT.md": {
        "kind": "unverified-report",
        "authority": "audit",
        "summary": "Report from another working copy; its header says that its QEMU passes were never reproduced here.",
    },
    "docs/validation/qemu.md": {
        "kind": "validation-procedure",
        "authority": "reference",
        "summary": "How a QEMU run is performed and recorded, and the table of the attempts that failed in this environment.",
    },
    "docs/releases/0.1.0-alpha.1.md": {
        "kind": "release",
        "authority": "current",
        "summary": "The alpha release record: what it contains, what was executed, and what it explicitly does not claim.",
    },
    # ---------------------------------------------------------------- architecture
    "docs/architecture/platform-architecture.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "The platform as a whole: layers, public and internal interfaces per subsystem, updates and virtualisation.",
    },
    "docs/architecture/kernel-internals.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "The structure of the kernel: boot, memory, tasks, drivers, and the contracts between them.",
    },
    "docs/architecture/memory-management.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "Physical and virtual memory: the frame manager, the page tables, what unmap returns, and the invariants.",
    },
    "docs/architecture/execution-model.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "Processes, threads, scheduling, synchronisation, time and the user/kernel transition: the model and its state today.",
    },
    "docs/architecture/device-driver-model.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "The driver model: discovery, KVDI, ownership of a device, and the interfaces a driver may use.",
    },
    "docs/architecture/security-architecture.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "Capabilities, subjects, revocation, W^X and the security invariants of the system.",
    },
    "docs/architecture/k4-process-model.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "The K4 process and thread model as designed; its 'missing' list is history, not the current state.",
    },
    "docs/architecture/k4-process-lifecycle.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "Lifecycle of a process: create, run, exit, reap, join, and the rules of each transition.",
    },
    "docs/architecture/k4-security-process.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "The intersection of the process model and the security model.",
    },
    "docs/architecture/k4-userspace-transition.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "The ring 3 transition: segments, TSS, syscall entry and the return path.",
    },
    "docs/architecture/graphics-platform.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "The graphics stack: display, GPU model, KGC, KGA, renderer, compositor and tools.",
    },
    "docs/architecture/graphics-compatibility.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "KGA, KGX, KGL and KVK over one shared core; nothing in it is implemented.",
    },
    "docs/architecture/application-ecosystem.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "Packaging, sandboxing, updates and the SDK that applications use.",
    },
    "docs/architecture/user-experiences.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "The five user profiles and what each one requires from the system.",
    },
    "docs/architecture/linux-compatibility.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "The KLC personality: seven separated contracts, syscall translation, signals, TLS; runs nothing today.",
    },
    "docs/architecture/windows-compatibility.md": {
        "kind": "architecture",
        "authority": "planning",
        "summary": "The KWC personality: PE32+, NT objects, Win32; runs nothing today.",
    },
    # ---------------------------------------------------------------- planning
    "docs/roadmap/PRODUCT_ROADMAP.md": {
        "kind": "roadmap",
        "authority": "planning",
        "summary": "The product roadmap and its evidence ladder; states that it raises no maturity percentage.",
    },
    "docs/roadmap/KERNEL_COMPLETION_ROADMAP.md": {
        "kind": "roadmap",
        "authority": "planning",
        "summary": "The fourteen stages of the kernel, K0 to K13, with the required work and completion criteria of each; the plan of record for kernel work.",
    },
    "docs/roadmap/COMPATIBILITY_ROADMAP.md": {
        "kind": "roadmap",
        "authority": "planning",
        "summary": "The compatibility phases C0 to C11 and the non-promises of the personality work.",
    },
    "docs/roadmap/K4_PROCESS_ROADMAP.md": {
        "kind": "roadmap",
        "authority": "planning",
        "summary": "The sub-stages of K4, the process and thread work.",
    },
    "docs/roadmap/ERAS.md": {
        "kind": "roadmap",
        "authority": "planning",
        "summary": "The generation chart: what the name of each era means.",
    },
    "docs/strategy/market-landscape.md": {
        "kind": "research",
        "authority": "planning",
        "summary": "Nine dated market deep dives, with sources, that justify the chosen opportunities.",
    },
    # ---------------------------------------------------------------- decisions
    "docs/decisions/README.md": {
        "kind": "adr-index",
        "authority": "decision",
        "summary": "The index of the architecture decision records.",
    },
    "docs/decisions/0001-boot-probes-out-of-kernel-main.md": {
        "kind": "adr",
        "authority": "decision",
        "summary": "Boot probes leave kernel/main.zig; deferred until a boot can be compared before and after.",
    },
    "docs/decisions/0002-single-virtio-transport.md": {
        "kind": "adr",
        "authority": "decision",
        "summary": "One VirtIO transport: KVDI is the implementation, the legacy copy is scheduled for removal.",
    },
    "docs/decisions/0003-legacy-virtio-blk-stub.md": {
        "kind": "adr",
        "authority": "decision",
        "summary": "The legacy virtio_blk stub is dead code; removal decided, not executed.",
    },
    "docs/decisions/0004-graphics-stack-split.md": {
        "kind": "adr",
        "authority": "decision",
        "summary": "The graphics stack is split into display, core, API and compositor.",
    },
    "docs/decisions/0005-native-graphics-api.md": {
        "kind": "adr",
        "authority": "decision",
        "summary": "KGA is the native API; compatibility sits on top of it and never below.",
    },
    "docs/decisions/0006-userspace-compositor.md": {
        "kind": "adr",
        "authority": "decision",
        "summary": "The compositor lives in user space; the kernel only presents.",
    },
    "docs/decisions/0007-packaging-sandbox-updates.md": {
        "kind": "adr",
        "authority": "decision",
        "summary": "Packages, sandbox and updates are one design, not three.",
    },
    "docs/decisions/0008-shared-graphics-core.md": {
        "kind": "adr",
        "authority": "decision",
        "summary": "One shared graphics core (KGX) under every API.",
    },
    "docs/decisions/0009-spirv-ingestion.md": {
        "kind": "adr",
        "authority": "decision",
        "summary": "SPIR-V is the ingestion format of the shader pipeline.",
    },
    "docs/decisions/0010-compatibility-execution-model.md": {
        "kind": "adr",
        "authority": "decision",
        "summary": "Compatibility runs in isolated personalities, never inside the native ABI.",
    },
    "docs/decisions/ADR-K4-001-process-architecture.md": {
        "kind": "adr",
        "authority": "decision",
        "summary": "The process architecture of K4; its 'missing files' list predates the 2026-11-01 implementation.",
    },
    "sdk/README.md": {
        "kind": "reference",
        "authority": "reference",
        "summary": "The public boundary of the native SDK: what an application may import, and the ABI it targets.",
    },
    # ---------------------------------------------------------------- specs
    "docs/specs/syscall-abi.md": {
        "kind": "specification",
        "authority": "reference",
        "summary": "The syscall ABI: numbers, arguments, results and the revision of the table.",
    },
    "docs/specs/acpi-platform.md": {
        "kind": "specification",
        "authority": "reference",
        "summary": "What the kernel requires from ACPI: tables, overrides, the interrupt model.",
    },
    "docs/specs/boot-handoff-spec.md": {
        "kind": "specification",
        "authority": "reference",
        "summary": "The handoff between the UEFI bootloader and the kernel: memory map, framebuffer, markers.",
    },
}

# The order the guide recommends; a document not listed here is still indexed.
READING_ORDER = [
    "AGENTS.md",
    "docs/ai/context-pack.md",
    "docs/PROJECT_STATUS.md",
    "docs/audits/2026-11-01-task-subsystem.md",
    "docs/architecture/execution-model.md",
    "docs/architecture/memory-management.md",
    "docs/roadmap/KERNEL_COMPLETION_ROADMAP.md",
    "CHANGELOG.md",
]

DATE = re.compile(r"(\d{4}-\d{2}-\d{2})")
TITLE = re.compile(r"^#\s+(.+)$", re.M)
STATUS = re.compile(r"^-\s+Status:\s*\*{0,2}([^*\n]+)", re.M)


def markdown_files() -> list[Path]:
    found = []
    for path in sorted(ROOT.rglob("*.md")):
        parts = path.relative_to(ROOT).parts
        if any(part in SKIP_DIRS for part in parts):
            continue
        found.append(path)
    for extra in EXTRA_FILES:
        path = ROOT / extra
        if path.exists() and path not in found:
            found.append(path)
    return found


def classify(path: Path) -> dict[str, str]:
    relative = path.relative_to(ROOT).as_posix()
    if relative not in DOCUMENTS:
        raise SystemExit(
            f"unclassified document: {relative}\n"
            "Add it to the DOCUMENTS table of tools/scripts/gen-doc-index.py with its "
            "kind, authority and summary, then regenerate the index."
        )
    return DOCUMENTS[relative]


def entry_for(path: Path) -> dict[str, object]:
    relative = path.relative_to(ROOT).as_posix()
    metadata = classify(path)
    text = path.read_text(encoding="utf-8")

    title_match = TITLE.search(text)
    title = title_match.group(1).strip() if title_match else path.stem
    status_match = STATUS.search(text)
    date_match = DATE.search(relative) or DATE.search(status_match.group(1) if status_match else "")

    entry: dict[str, object] = {
        "path": relative,
        "title": title,
        "kind": metadata["kind"],
        "authority": metadata["authority"],
        "summary": metadata["summary"],
        "words": len(text.split()),
    }
    if date_match:
        entry["date"] = date_match.group(1)
    if status_match:
        entry["declared_status"] = status_match.group(1).strip()
    return entry


def build() -> dict[str, object]:
    files = markdown_files()
    on_disk = {path.relative_to(ROOT).as_posix() for path in files}

    missing = sorted(set(DOCUMENTS) - on_disk)
    if missing:
        raise SystemExit(
            "the classification table names documents that do not exist: "
            + ", ".join(missing)
        )

    entries = [entry_for(path) for path in files]
    entries.sort(key=lambda entry: str(entry["path"]))

    by_authority: dict[str, int] = {}
    for entry in entries:
        key = str(entry["authority"])
        by_authority[key] = by_authority.get(key, 0) + 1

    return {
        "schema": 1,
        "generated_by": "tools/scripts/gen-doc-index.py",
        "note": (
            "Machine-readable map of the documentation. `authority` says what an agent may do "
            "with a document: binding rules, the current state, an implementation record, an "
            "audit of a past tree, a plan, a decision or a reference. Only `current` documents "
            "carry numbers about today; `planning` documents never do."
        ),
        "authorities": {
            "binding": "rules of the repository; violating them is a defect",
            "current": "describes the tree as it is today",
            "record": "what was implemented, with the command and the result",
            "audit": "an observation of the tree at a date; history",
            "planning": "a plan, never a claim about the tree",
            "decision": "an ADR: the reason of a choice and what it rules out",
            "reference": "a specification or a procedure the code must satisfy",
        },
        "counts": {"documents": len(entries), "by_authority": by_authority},
        "reading_order": READING_ORDER,
        "documents": entries,
    }


def render(index: dict[str, object]) -> str:
    return json.dumps(index, indent=2, ensure_ascii=False) + "\n"


def main(argv: list[str]) -> int:
    check = "--check" in argv[1:]
    index = build()
    rendered = render(index)

    if check:
        if not INDEX_PATH.exists():
            print(f"missing index: {INDEX_PATH.relative_to(ROOT)}")
            return 1
        current = INDEX_PATH.read_text(encoding="utf-8")
        if current != rendered:
            print(
                "docs/ai/doc-index.json is out of step with the documentation.\n"
                "Run: python3 tools/scripts/gen-doc-index.py"
            )
            return 1
        print(f"doc index: {index['counts']['documents']} documents, every one classified")
        return 0

    INDEX_PATH.parent.mkdir(parents=True, exist_ok=True)
    INDEX_PATH.write_text(rendered, encoding="utf-8")
    print(f"wrote {INDEX_PATH.relative_to(ROOT)}: {index['counts']['documents']} documents")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
