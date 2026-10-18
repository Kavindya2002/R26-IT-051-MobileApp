#!/usr/bin/env python3
"""
Removes dead/historical commented-out code blocks from .dart (and
.py) files, while KEEPING every real comment attached to the live
code untouched — FIX notes, DOCUMENTED LIMITATION notes, /// doc
comments, everything.

How it detects "dead" vs "live":
This project's edit history re-comments the ENTIRE previous version
of a file every time a new version is written below it, so a file
looks like: [dead version 1][dead version 2]...[dead version N-1]
[LIVE version]. Every single line of a dead version starts with
"//" (one or more times); the live version mixes real code with
normal single-level comments.

The script splits the file into paragraphs (blank-line-separated
chunks). Starting from the top, as long as a paragraph is 100%
comment lines, it's part of dead history and is dropped. The MOMENT
a paragraph contains even one real (non "//") line, that paragraph
and everything after it — comments included, verbatim — is the live
file and is kept exactly as-is.

Usage:
    python3 clean_dead_comments.py <file1.dart> [file2.py ...]
    python3 clean_dead_comments.py --dir lib/        # recurse *.dart
    python3 clean_dead_comments.py --dir app/ --ext py   # recurse *.py

A .bak backup is written next to each changed file.
"""
import sys
from pathlib import Path


def is_comment_line(line: str) -> bool:
    s = line.strip()
    return s == "" or s.startswith("//") or s.startswith("#")


def is_fully_commented_paragraph(paragraph: list[str]) -> bool:
    non_blank = [l for l in paragraph if l.strip() != ""]
    if not non_blank:
        return True
    return all(is_comment_line(l) for l in non_blank)


def split_paragraphs(lines: list[str]) -> list[list[str]]:
    """Split into blank-line-separated chunks, keeping the blank
    separator lines attached to the END of the preceding paragraph so
    rejoining is lossless and order-preserving."""
    paragraphs = []
    current = []
    for line in lines:
        current.append(line)
        if line.strip() == "" and current and any(l.strip() for l in current):
            # blank line ends a paragraph only once we've seen content
            pass
    # Simpler: re-split by run of (content lines) vs (blank lines)
    paragraphs = []
    current = []
    prev_blank = False
    for line in lines:
        blank = line.strip() == ""
        if blank and not prev_blank and current:
            paragraphs.append(current)
            current = [line]
        else:
            current.append(line)
        prev_blank = blank
    if current:
        paragraphs.append(current)
    return paragraphs


def clean_file(path: Path) -> tuple[int, int]:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    paragraphs = split_paragraphs(lines)

    live_start = 0
    for i, para in enumerate(paragraphs):
        if not is_fully_commented_paragraph(para):
            live_start = i
            break
    else:
        live_start = 0  # whole file is comments; don't touch anything

    dead_paragraphs = paragraphs[:live_start]
    live_paragraphs = paragraphs[live_start:]

    removed_lines = sum(len(p) for p in dead_paragraphs)
    if removed_lines == 0:
        return 0, len(lines)

    new_lines = []
    for p in live_paragraphs:
        new_lines.extend(p)
    # trim leading blank lines left over at the very top
    while new_lines and new_lines[0].strip() == "":
        new_lines.pop(0)

    backup = path.with_suffix(path.suffix + ".bak")
    backup.write_text(text, encoding="utf-8")
    path.write_text("".join(new_lines), encoding="utf-8")
    return removed_lines, len(lines)


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)

    if args[0] == "--dir":
        root = Path(args[1])
        ext = "dart"
        if "--ext" in args:
            ext = args[args.index("--ext") + 1]
        files = sorted(root.rglob(f"*.{ext}"))
    else:
        files = [Path(a) for a in args]

    total_removed = 0
    for f in files:
        if not f.is_file():
            print(f"skip (not found): {f}")
            continue
        removed, total = clean_file(f)
        total_removed += removed
        if removed:
            print(f"{f}: removed {removed}/{total} dead lines (backup: {f}.bak)")
        else:
            print(f"{f}: no dead history found, left untouched")

    print(f"\nDone. {total_removed} dead lines removed across {len(files)} file(s).")


if __name__ == "__main__":
    main()
