#!/usr/bin/env bash
# =============================================================================
# sync_pipeline_export.sh — Pipeline-Artefakte für Offsite-Kopie (raspi5nas)
#
# Kopiert von den LIVE-Pfaden auf SSD2 (/srv/pcloud-archive, /srv/pcloud-temp)
# nach /srv/nas/Backup/raspi5nas/ — damit der tägliche RTB-Lauf sie mitnimmt.
#
# Pipeline lebt auf SSD2 (fstab bind), NICHT unter /srv/nas/pcloud-* (mergerfs).
# RTB excluded /pcloud-archive/ + /pcloud-temp/ unter /srv/nas (excludes.txt) →
# kein Feedback-Loop bei Uploads. Dieses Skript läuft nur via raspi5nas_backup
# (03:00), nicht vor jedem RTB.
# =============================================================================
set -euo pipefail

DEST="${PIPELINE_EXPORT_DEST:-/srv/nas/Backup/raspi5nas}"
PCLOUD_ARCHIVE="${PCLOUD_ARCHIVE_DIR:-/srv/pcloud-archive}"
PCLOUD_TEMP="${PCLOUD_TEMP_DIR:-/srv/pcloud-temp}"
EXCLUDE_TEMP_INDEX="${PIPELINE_EXPORT_EXCLUDE_TEMP_INDEX:-1}"

log() { printf "%s %s\n" "$(date '+%F %T')" "[pipeline-export]" "$*"; }

RC=0

if [[ -d "$PCLOUD_ARCHIVE" ]]; then
  log "archive: $PCLOUD_ARCHIVE → $DEST/pcloud-archive/ (manifests + indexes)"
  mkdir -p "$DEST/pcloud-archive"
  if ! rsync -a --delete \
    --include="manifests/" --include="manifests/**" \
    --include="indexes/" --include="indexes/**" \
    --exclude="*" \
    "$PCLOUD_ARCHIVE/" "$DEST/pcloud-archive/"; then
    log "WARN archive rsync fehlgeschlagen"
    RC=1
  fi
else
  log "WARN archive-Quelle fehlt: $PCLOUD_ARCHIVE"
  RC=1
fi

if [[ -d "$PCLOUD_TEMP" ]]; then
  log "temp: $PCLOUD_TEMP → $DEST/pcloud-temp/"
  mkdir -p "$DEST/pcloud-temp"
  _temp_excludes=()
  if [[ "$EXCLUDE_TEMP_INDEX" == "1" ]]; then
    _temp_excludes+=(--exclude="pcloud_pool_index_*.json")
  fi
  if ! rsync -a --delete "${_temp_excludes[@]}" \
    "$PCLOUD_TEMP/" "$DEST/pcloud-temp/"; then
    log "WARN temp rsync fehlgeschlagen"
    RC=1
  fi
else
  log "temp-Quelle fehlt (optional): $PCLOUD_TEMP"
fi

if [[ $RC -eq 0 ]]; then
  log "OK"
fi

exit $RC
