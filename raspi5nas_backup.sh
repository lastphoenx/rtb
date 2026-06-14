#!/usr/bin/env bash
# =============================================================================
# raspi5nas_backup.sh — Sichert kritische Raspi5-NAS-Konfigurationen nach
# /srv/nas/Backup/raspi5nas/ (NAS-Samba-Share, von dort ins pCloud-Backup).
#
# Gesichert:
#   - Pipeline-Export: manifests/, indexes/, temp/ (sync_pipeline_export.sh)
#   - /opt/apps/                                   (Apps, OHNE .env-Dateien)
#   - /etc/systemd/system/                         (nur Custom-Unit-Files)
#
# Läuft täglich um 03:00 via raspi5nas-backup.timer, unabhängig von pCloud.
# =============================================================================
set -euo pipefail

DEST="/srv/nas/Backup/raspi5nas"
LOG="/var/log/backup/raspi5nas_backup.log"
mkdir -p "$(dirname "$LOG")"

log() { printf "%s %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

log "[start] raspi5nas Backup"

RC=0

# --- 1) pCloud-Pipeline-Export (manifests, indexes, temp) ---
SYNC_SCRIPT="${SCRIPT_DIR}/sync_pipeline_export.sh"
if [[ -x "$SYNC_SCRIPT" ]]; then
  log "[pipeline-export] via $SYNC_SCRIPT"
  bash "$SYNC_SCRIPT" 2>&1 | tee -a "$LOG" || RC=$?
else
  log "[warn] $SYNC_SCRIPT nicht ausführbar — überspringe Pipeline-Export"
fi

# --- 2) /opt/apps/ ohne .env-Dateien ---
log "[rsync] /opt/apps/ → $DEST/opt-apps/ (ohne .env)"
mkdir -p "$DEST/opt-apps"
rsync -a --delete \
  --exclude="*.env" \
  --exclude=".env" \
  --exclude="**/.env" \
  --exclude="**/venv/" \
  --exclude="**/__pycache__/" \
  --exclude="**/*.pyc" \
  --exclude="**/.git/" \
  /opt/apps/ "$DEST/opt-apps/" 2>&1 | tee -a "$LOG" || RC=$?

# --- 3) Systemd Custom-Unit-Files (keine Symlinks, keine Standard-Units) ---
log "[rsync] /etc/systemd/system/ → $DEST/systemd/ (nur Custom-Files)"
mkdir -p "$DEST/systemd"
rsync -a --delete \
  --exclude="*.wants/" \
  --exclude="*.requires/" \
  --exclude="*.d/" \
  --filter="- *" \
  --filter="+ *.service" \
  --filter="+ *.timer" \
  --filter="+ *.socket" \
  --filter="+ *.mount" \
  /etc/systemd/system/ "$DEST/systemd/" 2>&1 | tee -a "$LOG" || RC=$?

if [[ $RC -eq 0 ]]; then
    log "[done] raspi5nas Backup erfolgreich"
else
    log "[warn] raspi5nas Backup mit Warnungen beendet (RC=$RC)"
fi

exit $RC
