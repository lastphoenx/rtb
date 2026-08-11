#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Shared RTB bucket keys and display paths (trigger UI + backup summary)."""
from __future__ import annotations

import os
from collections import Counter

NAS_ROOT = os.environ.get("RTB_SRC", "/srv/nas").rstrip("/")

# Pipeline bind-mounts on pi-nas (canonical paths, not under mergerfs).
PIPELINE_CANONICAL: dict[str, str] = {
    "pcloud-archive": "/srv/pcloud-archive",
    "pcloud-temp": "/srv/pcloud-temp",
}


def top_bucket(rel: str) -> str:
    """Bucket key for signature / grouped previews.

    Under ``Backup/`` use second segment (``Backup/Paperless``, ``Backup/pbs2``).
    """
    rel = rel.lstrip("./")
    if not rel or rel == ".":
        return "."
    parts = rel.split("/")
    if parts[0] == "Backup" and len(parts) >= 2:
        return f"Backup/{parts[1]}"
    return parts[0]


def bucket_display_path(bucket: str) -> str:
    """Human path under NAS root (mergerfs mirror for pipeline buckets)."""
    if bucket == ".":
        return f"{NAS_ROOT}/"
    if bucket.startswith("/"):
        return bucket.rstrip("/") or "/"
    return f"{NAS_ROOT}/{bucket}"


def bucket_canonical_path(bucket: str) -> str | None:
    """Pipeline canonical path when it differs from the NAS mirror."""
    return PIPELINE_CANONICAL.get(bucket)


def bucket_dir_rows(names: list[str], top_n: int) -> list[dict]:
    tops = Counter(names)
    rows: list[dict] = []
    for key, count in tops.most_common(max(1, top_n)):
        row: dict = {
            "dir": key,
            "count": count,
            "path": bucket_display_path(key),
        }
        canonical = bucket_canonical_path(key)
        if canonical and canonical != row["path"]:
            row["canonical"] = canonical
        rows.append(row)
    return rows


def bucket_dir_rows_from_paths(paths: list[str], top_n: int) -> list[dict]:
    buckets = [top_bucket(p) for p in paths]
    return bucket_dir_rows(buckets, top_n)
