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


def _normalize_prefix(pat: str) -> str:
    return pat.strip().strip("/")


def is_trigger_only_path(path: str, trigger_only: list[str]) -> bool:
    for raw in trigger_only:
        p = _normalize_prefix(raw)
        if not p:
            continue
        if path == p or path.startswith(p + "/"):
            return True
    return False


def _paths_from_rsync(rsync_output: str) -> list[str]:
    paths: list[str] = []
    for ln in rsync_output.splitlines():
        if not _ITEMIZE_RE.match(ln):
            continue
        p = _path_from_line(ln)
        if p:
            paths.append(p)
    return paths


def _preview_from_paths(paths: list[str], baseline: str, top_n: int, *, kind: str) -> dict:
    tops = Counter(p.split("/")[0] if "/" in p else p for p in paths)
    return {
        "kind": kind,
        "count": len(paths),
        "baseline": baseline,
        "top_dirs": [{"dir": k, "count": v} for k, v in tops.most_common(top_n)],
        "samples": paths[:30],
    }


def analyze_trigger_delta(
    rsync_output: str,
    baseline: str,
    trigger_only: list[str],
    top_n: int = 20,
) -> dict:
    """Split rsync -ni output: echte Trigger vs. nur Pipeline-Pfade (pcloud-*)."""
    paths = _paths_from_rsync(rsync_output)
    real: list[str] = []
    pipeline: list[str] = []
    for p in paths:
        if is_trigger_only_path(p, trigger_only):
            pipeline.append(p)
        else:
            real.append(p)
    return {
        "has_real_trigger": len(real) > 0,
        "trigger_real": _preview_from_paths(real, baseline, top_n, kind="trigger"),
        "trigger_pipeline_only": _preview_from_paths(
            pipeline, baseline, top_n, kind="pipeline_only"
        ),
    }


def build_delta_preview(
    rsync_output: str,
    baseline: str,
    top_n: int = 20,
    *,
    kind: str = "trigger",
) -> dict:
    paths = _paths_from_rsync(rsync_output)
    return _preview_from_paths(paths, baseline, top_n, kind=kind)


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
    parser.add_argument(
        "--kind",
        choices=("trigger", "backup_scope", "pipeline_only"),
        default="trigger",
        help="trigger = Backup-Trigger-Delta; backup_scope = Mitgesichert bei Backup",
    )
    parser.add_argument(
        "--analyze",
        action="store_true",
        help="Split trigger vs. pipeline-only paths (pcloud-archive/temp)",
    )
    parser.add_argument(
        "--trigger-only",
        action="append",
        default=[],
        metavar="PATTERN",
        help="Pipeline path prefix (repeatable), e.g. /pcloud-temp/",
    )
    args = parser.parse_args()

    rsync_output = sys.stdin.read()
    top_n = max(1, args.top_n)

    if args.analyze:
        prefixes = args.trigger_only or ["/pcloud-archive/", "/pcloud-temp/"]
        result = analyze_trigger_delta(rsync_output, args.baseline, prefixes, top_n=top_n)
        print(json.dumps(result, ensure_ascii=False))
        return 0

    preview = build_delta_preview(
        rsync_output,
        args.baseline,
        top_n=top_n,
        kind=args.kind,
    )
    if args.format == "text":
        print(format_text(preview))
    else:
        print(json.dumps(preview, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
