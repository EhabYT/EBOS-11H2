#!/usr/bin/env python3
"""Copy an unpacked .apbx tree into the repo, skipping oversized files.

Writes a markdown report listing every file taken and every file skipped, so
the result can be reviewed from git alone (CI log download is not always
reachable from restricted networks).
"""
import argparse
import os
import shutil
import sys

SKIP_NAMES = {".git", ".github"}


def human(n: int) -> str:
    step = 1024.0
    val = float(n)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if val < step or unit == "GiB":
            return f"{val:.1f} {unit}" if unit != "B" else f"{int(val)} B"
        val /= step
    return f"{val:.1f} GiB"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--dest", default="")
    ap.add_argument("--max-bytes", type=int, default=90_000_000)
    ap.add_argument("--report", default="IMPORT-REPORT.md")
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    repo = os.path.abspath(args.repo)
    dest = os.path.normpath(os.path.join(repo, args.dest)) if args.dest else repo

    taken: list[tuple[int, str]] = []
    skipped: list[tuple[int, str]] = []

    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in SKIP_NAMES]
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, src)
            try:
                size = os.path.getsize(full)
            except OSError:
                continue
            if size > args.max_bytes:
                skipped.append((size, rel))
                continue
            target = os.path.join(dest, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(full, target)
            taken.append((size, rel))

    taken.sort(key=lambda x: -x[0])
    skipped.sort(key=lambda x: -x[0])
    total_taken = sum(s for s, _ in taken)
    total_skipped = sum(s for s, _ in skipped)

    lines = [
        "# APBX import report",
        "",
        f"- Files imported: **{len(taken)}** ({human(total_taken)})",
        f"- Files skipped (over {human(args.max_bytes)}): **{len(skipped)}** ({human(total_skipped)})",
        "",
    ]

    if skipped:
        lines += ["## Skipped (too large for git)", ""]
        lines += [f"- `{rel}` — {human(size)}" for size, rel in skipped[:200]]
        if len(skipped) > 200:
            lines.append(f"- …and {len(skipped) - 200} more")
        lines.append("")

    lines += ["## Largest imported files", ""]
    lines += [f"- `{rel}` — {human(size)}" for size, rel in taken[:100]]
    lines.append("")

    with open(os.path.join(repo, args.report), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    print(f"imported {len(taken)} files ({total_taken} bytes)")
    print(f"skipped  {len(skipped)} files ({total_skipped} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
