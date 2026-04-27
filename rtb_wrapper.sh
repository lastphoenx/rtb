#!/usr/bin/env bash
set -euo pipefail

# ===== Konfig =====
SRC=${SRC:-/srv/nas}
RTB=${RTB:-/mnt/backup/rtb_nas}
RTB_SCRIPT=${RTB_SCRIPT:-/opt/apps/rtb/rsync_tmbackup.sh}
RTB_EXCL=${RTB_EXCL:-/opt/apps/rtb/excludes.txt}

# Bei "keine Änderungen": 1 = sofort Exit 0 (Default), 0 = trotzdem Backup fahren
NO_CHANGE_EXIT0=${NO_CHANGE_EXIT0:-1}

# Optionaler Zwangslauf per Flag
FORCE=0
if [[ "${1:-}" == "--force" ]]; then FORCE=1; shift; fi

# ===== UPLOAD-ONLY mode ==============================================
# Upload existing snapshot to pCloud without creating new RTB backup.
# Use case: Re-upload after pCloud issues, or test uploads.
#   /opt/apps/rtb/rtb_wrapper.sh --upload-only /mnt/backup/rtb_nas/2026-04-10-075334
UPLOAD_ONLY_SNAPSHOT=""
if [[ "${1:-}" == "--upload-only" ]]; then
  UPLOAD_ONLY_SNAPSHOT="$2"
  if [[ -z "$UPLOAD_ONLY_SNAPSHOT" || ! -d "$UPLOAD_ONLY_SNAPSHOT" ]]; then
    echo "❌ ERROR: --upload-only requires valid snapshot path"
    echo "Usage: $0 --upload-only /mnt/backup/rtb_nas/SNAPSHOT_NAME"
    exit 1
  fi
  shift 2
fi

# ===== CHECK-ONLY mode ===============================================
# Read-only live dry-run: no lock, no log write, no backup triggered.
# Used by aggregate_status.sh to get current change-detection result.
#   exit 0 + "no_changes"        → source == latest snapshot
#   exit 1 + "changes_detected"  → new/changed/deleted files found
#   exit 0 + "no_baseline"       → no latest snapshot yet (first run)
#   exit 2 + "error"             → rsync failed
if [[ "${1:-}" == "--check-only" ]]; then
  LAST="$(readlink -f "${RTB}/latest" 2>/dev/null || true)"
  if [[ -z "$LAST" || ! -d "$LAST" ]]; then
    echo "[RTB Wrapper] no_baseline → No previous backup snapshot found (first run needed)"
    exit 0
  fi
  set +e
  check_out=$(rsync -ni --delete \
    --links --hard-links --one-file-system --times --recursive \
    --perms --owner --group \
    --exclude-from "${RTB_EXCL}" \
    "${SRC}/" "$LAST/" 2>/dev/null)
  rsync_rc=$?
  set -e
  if [[ $rsync_rc -ne 0 ]]; then
    echo "[RTB Wrapper] error → rsync check failed (exit code: $rsync_rc)"
    exit 2
  fi
  if echo "$check_out" | grep -qE '^[<>ch*]'; then
    echo "[RTB Wrapper] changes_detected → Backup needed (new/changed/deleted files found)"
    exit 1
  else
    echo "[RTB Wrapper] no_changes → No backup needed (source == latest snapshot)"
    exit 0
  fi
fi

# === EntropyWatcher Safety-Gate ===
ENTROPYWATCHER_ENABLE=${ENTROPYWATCHER_ENABLE:-1}
ENTROPYWATCHER_SAFETY_GATE=${ENTROPYWATCHER_SAFETY_GATE:-/opt/apps/entropywatcher/main/safety_gate.sh}
SAFETY_GATE_STRICT=${SAFETY_GATE_STRICT:-1}  # 1 = blockiert auch bei YELLOW (empfohlen)

# Gemeinsames Lock mit pCloud-Sync, damit nichts parallel läuft
LOCKFILE=${LOCKFILE:-/run/backup_pipeline.lock}
WAIT_SEC=${WAIT_SEC:-7200}  # max. 2h auf Lock warten

# ========= Logging =========
RTB_LOG=${RTB_LOG:-/var/log/backup/rtb_wrapper.log}
mkdir -p "$(dirname "$RTB_LOG")"
exec > >(tee -a "$RTB_LOG") 2>&1

log(){ printf "%s %s\n" "$(date '+%F %T')" "$*"; }

# ===== Lock holen =====
exec 9>"$LOCKFILE"
if ! flock -w "$WAIT_SEC" 9; then
  log "[skip] Konnte Lock innerhalb ${WAIT_SEC}s nicht bekommen."
  exit 0
fi

log "[start] RTB"

# ===== Upload-Only Shortcut ==========================================
if [[ -n "$UPLOAD_ONLY_SNAPSHOT" ]]; then
  log "[upload-only] Überspringe RTB-Backup, starte direkt pCloud-Upload"
  log "[upload-only] Snapshot: $UPLOAD_ONLY_SNAPSHOT"
  
  PCLOUD_WRAPPER=${PCLOUD_WRAPPER:-/opt/apps/pcloud-tools/main/wrapper_pcloud_sync_1to1.sh}
  PCLOUD_ENABLE=${PCLOUD_ENABLE:-1}
  
  if [[ "$PCLOUD_ENABLE" -eq 1 && -x "$PCLOUD_WRAPPER" ]]; then
    log "[start] pCloud-Sync (upload-only mode)"
    if BACKUP_PIPELINE_LOCKED=1 bash "$PCLOUD_WRAPPER" "$UPLOAD_ONLY_SNAPSHOT"; then
      log "[done] pCloud-Sync erfolgreich ✓"
      exit 0
    else
      PCLOUD_EXIT=$?
      log "[error] pCloud-Sync fehlgeschlagen (Exit $PCLOUD_EXIT)"
      exit $PCLOUD_EXIT
    fi
  else
    log "[error] pCloud-Sync nicht verfügbar: $PCLOUD_WRAPPER"
    exit 1
  fi
fi

# ===== EntropyWatcher Safety-Check =====
if [[ "$ENTROPYWATCHER_ENABLE" -eq 1 && "$FORCE" -ne 1 ]]; then
  log "[safety] EntropyWatcher Safety-Gate prüft nas + nas-av..."
  if [[ -x "$ENTROPYWATCHER_SAFETY_GATE" ]]; then
    set +e
    if [[ "$SAFETY_GATE_STRICT" -eq 1 ]]; then
      "$ENTROPYWATCHER_SAFETY_GATE" --strict
    else
      "$ENTROPYWATCHER_SAFETY_GATE"
    fi
    STATUS_CODE=$?
    set -e
    
    case $STATUS_CODE in
      0) 
        log "[safety] ✓ GREEN - Backup darf starten" 
        ;;
      1) 
        if [[ "$SAFETY_GATE_STRICT" -eq 1 ]]; then
          log "[ABORT] ⚠ YELLOW - Backup BLOCKIERT (strict mode aktiv)"
          exit 1
        else
          log "[safety] ⚠ YELLOW - Backup läuft mit Warnung"
        fi
        ;;
      2) 
        log "[ABORT] ✗ RED - Backup BLOCKIERT! (Ransomware/Viren-Verdacht)"
        exit 2
        ;;
      *) 
        log "[warning] Unbekannter Status ($STATUS_CODE) - Backup blockiert"
        exit 2
        ;;
    esac
  else
    log "[skip] Safety-Gate nicht verfügbar: $ENTROPYWATCHER_SAFETY_GATE"
  fi
elif [[ "$FORCE" -eq 1 ]]; then
  log "[safety] Safety-Check übersprungen (--force aktiv)"
fi

# ===== Pre-Check: Änderungen seit letztem Snapshot? =====
LAST="$(readlink -f "${RTB}/latest" 2>/dev/null || true)"
SKIP_RTB_BACKUP=0

if [[ -n "$LAST" && -d "$LAST" ]]; then
  log "[check] Prüfe auf Änderungen seit letztem Snapshot..."

  # rsync-Dry-Run analog zu rsync_tmbackup.sh (inkl. --delete für Löschungen)
  if rsync -ni --delete \
       --links --hard-links --one-file-system --times --recursive --perms --owner --group \
       --exclude-from "${RTB_EXCL}" \
       "${SRC}/" "$LAST/" \
       | grep -qE '^[<>ch*]'; then
    log "[info] Änderungen erkannt - starte Backup"
  else
    log "[skip] Keine Änderungen seit letztem Backup - kein neuer Snapshot nötig"
    
    # Prüfe pCloud-Upload-Status für diesen Snapshot
    SNAPSHOT_NAME=$(basename "$LAST")
    log "[check] Prüfe pCloud-Upload-Status für $SNAPSHOT_NAME..."
    
    # MariaDB-Query: War Upload erfolgreich?
    set +e
    PCLOUD_SUCCESS_COUNT=$(MYSQL_PWD="${PCLOUD_DB_PASS:-}" mysql \
      -h "${PCLOUD_DB_HOST:-localhost}" \
      -P "${PCLOUD_DB_PORT:-3306}" \
      -u "${PCLOUD_DB_USER:-pcloud_backup}" \
      -D "${PCLOUD_DB_NAME:-pcloud_backup}" \
      -sN -e "SELECT COUNT(*) FROM backup_runs WHERE snapshot_name='$SNAPSHOT_NAME' AND status='SUCCESS'" 2>/dev/null)
    MYSQL_EXIT=$?
    set -e
    
    if [[ $MYSQL_EXIT -ne 0 || -z "$PCLOUD_SUCCESS_COUNT" ]]; then
      log "[warning] pCloud-Status konnte nicht geprüft werden (MariaDB-Zugriff fehlgeschlagen)"
      PCLOUD_SUCCESS_COUNT=0
    fi
    
    if [[ "$PCLOUD_SUCCESS_COUNT" -gt 0 ]]; then
      log "[skip] ✓ RTB und pCloud beide erfolgreich - nichts zu tun"
      if [[ "$NO_CHANGE_EXIT0" -eq 1 && "$FORCE" -ne 1 ]]; then
        exit 0
      fi
    else
      log "[info] ⚠ RTB ok, aber pCloud-Upload fehlt - Upload wird nachgeholt"
      SKIP_RTB_BACKUP=1  # RTB überspringen, direkt zu pCloud
    fi
  fi
fi

# ===== Backup fahren =====
if [[ "$SKIP_RTB_BACKUP" -eq 1 ]]; then
  log "[skip] RTB-Backup wird übersprungen (Snapshot bereits vorhanden)"
else
  # (optional sanfter: ionice/nice davor setzen)
  set +e
  sudo bash "$RTB_SCRIPT" "$SRC" "$RTB" "$RTB_EXCL"
  RTB_EXIT=$?
  set -e

  if [[ $RTB_EXIT -ne 0 ]]; then
    log "[ABORT] RTB fehlgeschlagen (Exit $RTB_EXIT) - pCloud-Sync wird übersprungen"
    exit $RTB_EXIT
  fi

  log "[done] RTB erfolgreich"
fi

# ===== pCloud-Sync starten =====
PCLOUD_WRAPPER=${PCLOUD_WRAPPER:-/opt/apps/pcloud-tools/main/wrapper_pcloud_sync_1to1.sh}
PCLOUD_ENABLE=${PCLOUD_ENABLE:-1}

if [[ "$PCLOUD_ENABLE" -eq 1 && -x "$PCLOUD_WRAPPER" ]]; then
  log "[start] pCloud-Sync (automatisch nach RTB)"
  if BACKUP_PIPELINE_LOCKED=1 bash "$PCLOUD_WRAPPER" "${RTB}/latest"; then
    log "[done] pCloud-Sync erfolgreich"
    log "[done] Backup-Pipeline komplett ✓"
  else
    PCLOUD_EXIT=$?
    log "[error] pCloud-Sync fehlgeschlagen (Exit $PCLOUD_EXIT)"
    exit $PCLOUD_EXIT
  fi
else
  log "[skip] pCloud-Sync deaktiviert oder nicht verfügbar"
  log "[done] RTB-Pipeline komplett (ohne pCloud)"
fi
