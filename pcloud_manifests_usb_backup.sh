#!/usr/bin/env bash
# =============================================================================
# pcloud_manifests_usb_backup.sh — Pipeline-Manifeste (SSD2) auf externe USB,
# bewusst NICHT unter /srv/nas (kein RTB-Trigger, kein pCloud-Pool-Backup).
#
# Konfiguration (pi-nas): Environment= in pcloud-manifests-backup.service
# (unter /etc/systemd/system/ nach git pull kopieren)
#
# Erster Lauf: volle ~7 GB. Danach: meist 1 neues JSON pro Backup-Tag (~80 MB).
# Timer: pcloud-manifests-backup.timer (10:30 + 22:15).
# =============================================================================
set -euo pipefail

PCLOUD_ARCHIVE_DIR="${PCLOUD_ARCHIVE_DIR:-/srv/pcloud-archive}"
SRC="${PCLOUD_ARCHIVE_DIR}/manifests"
DEST="${PCLOUD_MANIFESTS_BACKUP_DEST:-}"
LOG="/var/log/backup/pcloud_manifests_backup.log"

log() { printf "%s %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

mkdir -p "$(dirname "$LOG")"

if [[ -z "${DEST}" ]]; then
  log "[skip] PCLOUD_MANIFESTS_BACKUP_DEST nicht gesetzt (Environment in pcloud-manifests-backup.service)"
  exit 0
fi

case "${DEST}" in
  /srv/nas/*)
    log "[error] DEST unter /srv/nas verboten (RTB/pCloud-Backup)"
    exit 1
    ;;
esac

if [[ ! -d "${SRC}" ]]; then
  log "[warn] Quelle fehlt: ${SRC}"
  exit 0
fi

if [[ ! -d "${DEST}" ]]; then
  log "[skip] DEST nicht vorhanden (USB nicht gemountet?): ${DEST}"
  exit 0
fi

if [[ ! -w "${DEST}" ]]; then
  log "[skip] DEST nicht beschreibbar: ${DEST}"
  exit 0
fi

log "[start] rsync ${SRC}/ → ${DEST}/"
if rsync -a --delete "${SRC}/" "${DEST}/" 2>&1 | tee -a "$LOG"; then
  n="$(find "${SRC}" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  log "[done] OK (${n} Manifeste unter ${SRC})"
else
  log "[error] rsync fehlgeschlagen"
  exit 1
fi
