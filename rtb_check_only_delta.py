#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Parse rsync -ni itemize output for RTB delta preview (JSON or text)."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from rtb_buckets import bucket_dir_rows_from_paths, bucket_dir_rows  # noqa: E402

_ITEMIZE_RE = re.compile(r"^[<>ch*.]")

# Canonical trigger-only prefixes (replicated stores + pipeline paths).
# Bash: rtb_check_excludes.sh RTB_TRIGGER_ONLY_PATTERNS (both anchored/unanchored forms).
RTB_TRIGGER_ONLY_DEFAULTS: tuple[str, ...] = (
    "/pcloud-archive/",
    "/pcloud-temp/",
    "/Backup/pbs2/",
    "/Backup/pve2/",
)


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
    return {
        "kind": kind,
        "count": len(paths),
        "baseline": baseline,
        "top_dirs": bucket_dir_rows_from_paths(paths, top_n),
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
        for row in preview["top_dirs"]:
            label = row.get("path") or row.get("dir", "?")
            if row.get("canonical") and row["canonical"] != label:
                label = f"{label} (Pipeline: {row['canonical']})"
            lines.append(f"  {row['count']:>6}  {label}")
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
        prefixes = args.trigger_only or list(RTB_TRIGGER_ONLY_DEFAULTS)
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
