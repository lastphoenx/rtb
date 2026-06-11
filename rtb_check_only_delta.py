#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Parse rsync -ni itemize output for RTB delta preview (JSON or text)."""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter

_ITEMIZE_RE = re.compile(r"^[<>ch*.]")


def _path_from_line(line: str) -> str | None:
    line = line.rstrip("\n")
    if line.startswith("*deleting"):
        rest = line[len("*deleting") :].strip()
        return rest or None
    m = re.match(r"^.{11} (.+)$", line)
    return m.group(1).strip() if m else None


def build_delta_preview(rsync_output: str, baseline: str, top_n: int = 20) -> dict:
    lines = [ln for ln in rsync_output.splitlines() if _ITEMIZE_RE.match(ln)]
    paths: list[str] = []
    for ln in lines:
        p = _path_from_line(ln)
        if p:
            paths.append(p)
    tops = Counter(p.split("/")[0] if "/" in p else p for p in paths)
    return {
        "count": len(lines),
        "baseline": baseline,
        "top_dirs": [{"dir": k, "count": v} for k, v in tops.most_common(top_n)],
        "samples": paths[:30],
    }


def format_text(preview: dict) -> str:
    lines = [
        f"--- Anzahl Delta-Zeilen: {preview['count']} ---",
        "",
        "Top-Level-Ordner (gruppiert):",
    ]
    if not preview["top_dirs"]:
        lines.append("  (keine)")
    else:
        width = max(len(row["dir"]) for row in preview["top_dirs"])
        for row in preview["top_dirs"]:
            lines.append(f"  {row['count']:>6}  {row['dir']:<{width}}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="RTB rsync -ni delta preview")
    parser.add_argument("baseline", nargs="?", default="", help="RTB latest snapshot path")
    parser.add_argument("--top-n", type=int, default=20, help="Top dirs in summary (default: 20)")
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="Output format (default: json for --check-only wrapper)",
    )
    args = parser.parse_args()

    preview = build_delta_preview(sys.stdin.read(), args.baseline, top_n=max(1, args.top_n))
    if args.format == "text":
        print(format_text(preview))
    else:
        print(json.dumps(preview, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
