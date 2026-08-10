#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Low-RAM backup trigger: compare per top-level bucket stats (no rsync flist)."""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from typing import DefaultDict, Iterable

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from rtb_check_only_delta import RTB_TRIGGER_ONLY_DEFAULTS, is_trigger_only_path  # noqa: E402

# Staged-RTB resume markers: only in snapshot root (rtb_staged_backup.sh), never on live /srv/nas.
# Ignored in signature walks — same idea as pcloud-archive (pipeline artefact), but snapshot-only.
# Note: path_excluded()/top_bucket() use lstrip("./"), so ".rtb_staged_done" becomes bucket "rtb_staged_done".
RTB_SIGNATURE_IGNORE_PATTERNS: tuple[str, ...] = (
    ".rtb_staged_done",
    ".rtb_staged_active",
    "rtb_staged_done",
    "rtb_staged_active",
)


@dataclass(frozen=True)
class BucketStats:
    files: int = 0
    bytes: int = 0
    max_mtime_ns: int = 0

    def as_tuple(self) -> tuple[int, int, int]:
        return (self.files, self.bytes, self.max_mtime_ns)


def _normalize_prefix(pat: str) -> str:
    return pat.strip().strip("/")


def load_patterns(path: str | None) -> list[str]:
    if not path:
        return []
    patterns: list[str] = []
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                patterns.append(line)
    except OSError as exc:
        print(f"rtb_trigger_signature: cannot read exclude file: {exc}", file=sys.stderr)
        raise SystemExit(2)
    return patterns


def matches_exclude(rel: str, pattern: str) -> bool:
    """Approximate rsync --exclude-from matching for walk pruning."""
    pat = pattern.strip()
    if not pat:
        return False
    rel = rel.lstrip("./")
    anchored = pat.startswith("/")
    if anchored:
        pat = pat.lstrip("/")
    if pat.endswith("/"):
        base = pat.rstrip("/")
        if anchored:
            return rel == base or rel.startswith(base + "/")
        return rel == base or rel.startswith(base + "/") or (f"/{base}/" in f"/{rel}/")
    if anchored:
        return fnmatch.fnmatch(rel, pat) or fnmatch.fnmatch(os.path.basename(rel), pat)
    parts = rel.split("/")
    if any(fnmatch.fnmatch(part, pat) for part in parts):
        return True
    return fnmatch.fnmatch(rel, pat)


def path_excluded(rel: str, patterns: Iterable[str]) -> bool:
    rel = rel.lstrip("./")
    if not rel:
        return False
    return any(matches_exclude(rel, pat) for pat in patterns)


@dataclass(frozen=True)
class FileSig:
    size: int
    mtime_ns: int


def walk_file_index(root: str, excludes: list[str]) -> dict[str, FileSig]:
    """Map relative path -> (size, mtime_ns) for files under root."""
    index: dict[str, FileSig] = {}
    if not os.path.isdir(root):
        return index

    for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            rel_dir = ""

        pruned: list[str] = []
        for name in dirnames:
            rel = f"{rel_dir}/{name}" if rel_dir else name
            if path_excluded(rel, excludes) or path_excluded(rel + "/", excludes):
                continue
            pruned.append(name)
        dirnames[:] = pruned

        for name in filenames:
            rel = f"{rel_dir}/{name}" if rel_dir else name
            if path_excluded(rel, excludes):
                continue
            full = os.path.join(dirpath, name)
            try:
                st = os.lstat(full)
            except OSError:
                continue
            if not os.path.isfile(full) and not os.path.islink(full):
                continue
            mtime_ns = int(getattr(st, "st_mtime_ns", int(st.st_mtime * 1e9)))
            index[rel] = FileSig(size=int(st.st_size), mtime_ns=mtime_ns)

    return index


def diff_file_indexes(
    src_index: dict[str, FileSig],
    snap_index: dict[str, FileSig],
    *,
    bucket: str,
    sample_n: int,
) -> dict:
    prefix = "" if bucket == "." else f"{bucket}/"
    src_keys = {p for p in src_index if bucket == "." or p == bucket or p.startswith(prefix)}
    snap_keys = {p for p in snap_index if bucket == "." or p == bucket or p.startswith(prefix)}

    added = sorted(src_keys - snap_keys)
    removed = sorted(snap_keys - src_keys)
    changed: list[str] = []
    for path in sorted(src_keys & snap_keys):
        if src_index[path] != snap_index[path]:
            changed.append(path)

    samples: list[dict] = []

    def _push(path: str, reason: str) -> None:
        if len(samples) >= sample_n:
            return
        entry: dict = {"path": path, "reason": reason}
        if reason == "added" and path in src_index:
            entry["src_size"] = src_index[path].size
        elif reason == "removed" and path in snap_index:
            entry["snap_size"] = snap_index[path].size
        elif reason == "changed" and path in src_index and path in snap_index:
            s, n = src_index[path], snap_index[path]
            entry["src_size"] = s.size
            entry["snap_size"] = n.size
            entry["src_mtime_ns"] = s.mtime_ns
            entry["snap_mtime_ns"] = n.mtime_ns
        samples.append(entry)

    for path in added:
        _push(path, "added")
    for path in removed:
        _push(path, "removed")
    for path in changed:
        _push(path, "changed")

    return {
        "bucket": bucket,
        "src_files": len(src_keys),
        "snap_files": len(snap_keys),
        "added": len(added),
        "removed": len(removed),
        "changed": len(changed),
        "diff_total": len(added) + len(removed) + len(changed),
        "samples": samples,
    }


def bucket_stats_row(name: str, src: BucketStats, snap: BucketStats) -> dict:
    return {
        "bucket": name,
        "src": {"files": src.files, "bytes": src.bytes, "max_mtime_ns": src.max_mtime_ns},
        "snap": {"files": snap.files, "bytes": snap.bytes, "max_mtime_ns": snap.max_mtime_ns},
    }


def top_bucket(rel: str) -> str:
    """Top-level bucket key for signature stats.

    Under ``Backup/`` use second path segment (``Backup/Paperless``, ``Backup/pbs2``)
    so replicated backup stores can be trigger-only without poisoning the whole tree.
    """
    rel = rel.lstrip("./")
    if not rel or rel == ".":
        return "."
    parts = rel.split("/")
    if parts[0] == "Backup" and len(parts) >= 2:
        return f"Backup/{parts[1]}"
    return parts[0]


def walk_bucket_stats(root: str, excludes: list[str]) -> tuple[DefaultDict[str, BucketStats], int]:
    stats: DefaultDict[str, BucketStats] = defaultdict(BucketStats)
    scanned = 0
    if not os.path.isdir(root):
        return stats, scanned

    for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            rel_dir = ""

        pruned: list[str] = []
        for name in dirnames:
            rel = f"{rel_dir}/{name}" if rel_dir else name
            if path_excluded(rel, excludes) or path_excluded(rel + "/", excludes):
                continue
            pruned.append(name)
        dirnames[:] = pruned

        for name in filenames:
            rel = f"{rel_dir}/{name}" if rel_dir else name
            if path_excluded(rel, excludes):
                continue
            full = os.path.join(dirpath, name)
            try:
                st = os.lstat(full)
            except OSError:
                continue
            if not os.path.isfile(full) and not os.path.islink(full):
                continue
            bucket = top_bucket(rel)
            b = stats[bucket]
            size = int(st.st_size)
            mtime_ns = int(getattr(st, "st_mtime_ns", int(st.st_mtime * 1e9)))
            stats[bucket] = BucketStats(
                files=b.files + 1,
                bytes=b.bytes + size,
                max_mtime_ns=max(b.max_mtime_ns, mtime_ns),
            )
            scanned += 1

    return stats, scanned


def diff_buckets(
    src_stats: dict[str, BucketStats],
    snap_stats: dict[str, BucketStats],
    trigger_only: list[str],
) -> tuple[list[str], list[str]]:
    dirty_real: list[str] = []
    dirty_pipeline: list[str] = []
    all_names = sorted(set(src_stats) | set(snap_stats))
    for name in all_names:
        s = src_stats.get(name, BucketStats()).as_tuple()
        n = snap_stats.get(name, BucketStats()).as_tuple()
        if s == n:
            continue
        rel = "." if name == "." else name
        if is_trigger_only_path(rel, trigger_only) or is_trigger_only_path(name, trigger_only):
            dirty_pipeline.append(name)
        else:
            dirty_real.append(name)
    return dirty_real, dirty_pipeline


def preview_buckets(names: list[str], baseline: str, *, kind: str, top_n: int) -> dict:
    tops = Counter(names)
    return {
        "kind": kind,
        "count": len(names),
        "baseline": baseline,
        "top_dirs": [{"dir": k, "count": v} for k, v in tops.most_common(top_n)],
        "samples": names[:30],
    }


def build_result(
    *,
    baseline: str,
    trigger_only: list[str],
    dirty_real: list[str],
    dirty_pipeline: list[str],
    files_src: int,
    files_snap: int,
    duration_sec: float,
    top_n: int,
    bucket_details: list[dict] | None = None,
) -> dict:
    trigger_real = preview_buckets(dirty_real, baseline, kind="trigger", top_n=top_n)
    trigger_real["method"] = "signature"
    if bucket_details:
        trigger_real["bucket_details"] = bucket_details
        file_lines: list[str] = []
        file_count = 0
        for row in bucket_details:
            file_count += int(row.get("diff_total", 0))
            for sample in row.get("samples", []):
                if len(file_lines) >= 30:
                    break
                path = sample.get("path", "")
                reason = sample.get("reason", "?")
                file_lines.append(f"{reason}: {path}")
        if file_count > 0:
            trigger_real["count"] = file_count
        if file_lines:
            trigger_real["samples"] = file_lines

    return {
        "method": "signature",
        "has_real_trigger": len(dirty_real) > 0,
        "dirty_real_buckets": dirty_real,
        "dirty_pipeline_buckets": dirty_pipeline,
        "trigger_real": trigger_real,
        "trigger_pipeline_only": preview_buckets(
            dirty_pipeline, baseline, kind="pipeline_only", top_n=top_n
        ),
        "scan": {
            "files_src": files_src,
            "files_snap": files_snap,
            "duration_sec": round(duration_sec, 2),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="RTB low-RAM trigger signature scan")
    parser.add_argument("--src", required=True, help="Live NAS root (e.g. /srv/nas)")
    parser.add_argument("--snapshot", required=True, help="RTB latest snapshot directory")
    parser.add_argument("--exclude-file", default="", help="rsync exclude-from file")
    parser.add_argument(
        "--trigger-only",
        action="append",
        default=[],
        metavar="PREFIX",
        help="Pipeline prefixes (repeatable)",
    )
    parser.add_argument("--top-n", type=int, default=10)
    parser.add_argument(
        "--file-samples",
        type=int,
        default=25,
        help="Max file-level diff samples per dirty bucket (default: 25)",
    )
    parser.add_argument(
        "--kind",
        choices=("trigger", "backup_scope"),
        default="trigger",
        help="trigger = ignore pipeline-only dirt; backup_scope = any dirty bucket",
    )
    args = parser.parse_args()

    trigger_only = args.trigger_only or list(RTB_TRIGGER_ONLY_DEFAULTS)
    excludes = list(RTB_SIGNATURE_IGNORE_PATTERNS) + load_patterns(args.exclude_file or None)
    t0 = time.monotonic()

    src_stats, files_src = walk_bucket_stats(args.src, excludes)
    snap_stats, files_snap = walk_bucket_stats(args.snapshot, excludes)
    dirty_real, dirty_pipeline = diff_buckets(src_stats, snap_stats, trigger_only)

    src_index = walk_file_index(args.src, excludes)
    snap_index = walk_file_index(args.snapshot, excludes)
    bucket_details: list[dict] = []
    sample_n = max(1, args.file_samples)
    for name in dirty_real:
        detail = diff_file_indexes(src_index, snap_index, bucket=name, sample_n=sample_n)
        detail["stats"] = bucket_stats_row(
            name,
            src_stats.get(name, BucketStats()),
            snap_stats.get(name, BucketStats()),
        )
        bucket_details.append(detail)

    if args.kind == "backup_scope":
        all_dirty = sorted(set(dirty_real) | set(dirty_pipeline))
        result = {
            "method": "signature",
            "kind": "backup_scope",
            "has_changes": len(all_dirty) > 0,
            "dirty_buckets": all_dirty,
            "backup_scope": preview_buckets(all_dirty, args.snapshot, kind="backup_scope", top_n=args.top_n),
            "scan": {
                "files_src": files_src,
                "files_snap": files_snap,
                "duration_sec": round(time.monotonic() - t0, 2),
            },
        }
        print(json.dumps(result, ensure_ascii=False))
        return 0

    result = build_result(
        baseline=args.snapshot,
        trigger_only=trigger_only,
        dirty_real=dirty_real,
        dirty_pipeline=dirty_pipeline,
        files_src=files_src,
        files_snap=files_snap,
        duration_sec=time.monotonic() - t0,
        top_n=max(1, args.top_n),
        bucket_details=bucket_details if dirty_real else None,
    )
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
