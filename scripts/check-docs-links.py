#!/usr/bin/env python3
"""Validate the relative links of the Markdown documentation.

The repository has no site generator: the documentation is read directly on
GitHub (and by the maintainers in an editor). A link to a file that was
deleted, renamed or never existed is invisible until someone clicks it, so
this check resolves every relative Markdown link against the working tree.

Absolute URLs are not fetched (CI has no reason to depend on the network for
a documentation check); they are reported only when they use a scheme the
checker does not understand.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# [text](target) and [text](target "title"); images share the same syntax.
LINK = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
FENCE = re.compile(r"^(```|~~~)")
SKIP_DIRS = {".git", ".zig-cache", "zig-out", ".tools", "node_modules"}


def markdown_files(root: Path):
    for path in sorted(root.rglob("*.md")):
        if any(part in SKIP_DIRS for part in path.relative_to(root).parts):
            continue
        yield path


def strip_code(path: Path, text: str) -> str:
    """Removes fenced blocks; a link inside code is an example, not a link."""
    output, fenced = [], False
    for line in text.splitlines():
        if FENCE.match(line.strip()):
            fenced = not fenced
            output.append("")
            continue
        output.append("" if fenced else line)
    return "\n".join(output)


def check(root: Path) -> list[str]:
    problems: list[str] = []
    for path in markdown_files(root):
        text = strip_code(path, path.read_text(encoding="utf-8", errors="replace"))
        for target in LINK.findall(text):
            if target.startswith(("#", "mailto:")):
                continue
            if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", target):
                continue
            target = target.split("#", 1)[0]
            if not target:
                continue
            resolved = (path.parent / target).resolve()
            if not resolved.exists():
                problems.append(f"{path.relative_to(root)}: broken link -> {target}")
    return problems


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    problems = check(root)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        print(f"docs: {len(problems)} broken link(s)", file=sys.stderr)
        return 1
    print("docs: every relative link resolves")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
