#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Parse per-unit rsync --stats and emit staged-backup summary JSON + log lines."""
from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any

_SCRIPT_DIR = __import__("os").path.dirname(__import__("os").path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from rtb_buckets import bucket_display_path  # noqa: E402

_RE_FILES = re.compile(
    r"^Number of regular files transferred:\s*([\d,]+)(?:\s+\([^)]+\))?\s*$",
    re.MULTILINE,
)
_RE_BYTES = re.compile(
    r"^Total transferred file size:\s*([\d,]+)\s+bytes\s*$",
    re.MULTILINE,
)


def parse_rsync_stats(text: str) -> tuple[int, int]:
    files = 0
    m = _RE_FILES.search(text)
    if m:
        files = int(m.group(1).replace(",", ""))
    bytes_xferred = 0
    m = _RE_BYTES.search(text)
    if m:
        bytes_xferred = int(m.group(1).replace(",", ""))
    return files, bytes_xferred


def _fmt_bytes(n: int) -> str:
    if n >= 1024**3:
        return f"{n / 1024**3:.2f} GiB"
    if n >= 1024**2:
        return f"{n / 1024**2:.1f} MiB"
    if n >= 1024:
        return f"{n / 1024:.1f} KiB"
    return f"{n} B"


def unit_row(
    unit: str,
    *,
    status: str,
    files_transferred: int = 0,
    bytes_transferred: int = 0,
) -> dict[str, Any]:
    return {
        "unit": unit,
        "path": bucket_display_path(unit),
        "status": status,
        "files_transferred": files_transferred,
        "bytes_transferred": bytes_transferred,
    }


def aggregate_summary(snapshot: str, units: list[dict[str, Any]]) -> dict[str, Any]:
    synced = [u for u in units if u.get("status") == "ok"]
    skipped = [u for u in units if u.get("status") == "skipped"]
    total_files = sum(int(u.get("files_transferred", 0)) for u in synced)
    total_bytes = sum(int(u.get("bytes_transferred", 0)) for u in synced)
    active = [u for u in synced if int(u.get("files_transferred", 0)) > 0]
    return {
        "kind": "backup_summary",
        "snapshot": snapshot,
        "units_total": len(units),
        "units_synced": len(synced),
        "units_skipped": len(skipped),
        "units_changed": len(active),
        "files_transferred": total_files,
        "bytes_transferred": total_bytes,
        "units": units,
    }


def emit_log_lines(summary: dict[str, Any]) -> None:
    snap = summary.get("snapshot", "?")
    print(f"rtb_staged_backup: —— Zusammenfassung Snapshot {snap} ——")
    print(
        f"rtb_staged_backup: {summary.get('units_total', 0)} Einheiten "
        f"({summary.get('units_changed', 0)} mit Transfer, "
        f"{summary.get('units_skipped', 0)} übersprungen)"
    )
    print(
        f"rtb_staged_backup: gesamt {summary.get('files_transferred', 0)} Dateien, "
        f"{_fmt_bytes(int(summary.get('bytes_transferred', 0)))}"
    )
    for row in summary.get("units", []):
        unit = row.get("unit", "?")
        path = row.get("path", bucket_display_path(unit))
        status = row.get("status", "?")
        if status == "skipped":
            print(f"rtb_staged_backup:   {path}  (übersprungen, bereits im Snapshot)")
            continue
        files = int(row.get("files_transferred", 0))
        nbytes = int(row.get("bytes_transferred", 0))
        if files == 0 and nbytes == 0:
            print(f"rtb_staged_backup:   {path}  (keine Änderung)")
        else:
            print(
                f"rtb_staged_backup:   {path}  "
                f"+{files} Dateien, {_fmt_bytes(nbytes)}"
            )
    print(f"[RTB BackupSummary JSON] {json.dumps(summary, ensure_ascii=False)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="RTB staged backup unit stats / summary")
    parser.add_argument("--parse-stats-file", metavar="FILE", help="rsync stdout capture for one unit")
    parser.add_argument("--unit", default="", help="Unit path relative to NAS root")
    parser.add_argument("--status", default="ok", choices=("ok", "skipped"))
    parser.add_argument("--aggregate", action="store_true", help="Read unit JSON lines from stdin")
    parser.add_argument("--snapshot", default="", help="Snapshot directory name")
    args = parser.parse_args()

    if args.parse_stats_file:
        try:
            with open(args.parse_stats_file, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError as exc:
            print(f"rtb_backup_summary: cannot read {args.parse_stats_file}: {exc}", file=sys.stderr)
            return 2
        files, nbytes = parse_rsync_stats(text)
        if args.status == "skipped":
            files, nbytes = 0, 0
        row = unit_row(args.unit, status=args.status, files_transferred=files, bytes_transferred=nbytes)
        print(json.dumps(row, ensure_ascii=False))
        return 0

    if args.aggregate:
        units: list[dict[str, Any]] = []
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            units.append(json.loads(line))
        summary = aggregate_summary(args.snapshot, units)
        emit_log_lines(summary)
        return 0

    if args.unit:
        row = unit_row(args.unit, status=args.status)
        print(json.dumps(row, ensure_ascii=False))
        return 0

    parser.error("use --parse-stats-file, --unit, or --aggregate")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
