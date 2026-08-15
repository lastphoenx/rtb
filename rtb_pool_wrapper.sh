#!/usr/bin/env bash
set -euo pipefail

# =====================================================
# RTB + pCloud POOL-MODE Wrapper
# =====================================================
# Orchestriert RTB-Backup + pCloud Pool-Upload.
# POOL-MODE: Files in /_pool/, Snapshots als Stubs.
# =====================================================

# ===== Konfig =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=nas_heavy_ops_lock.sh
source "${SCRIPT_DIR}/nas_heavy_ops_lock.sh"
SRC=${SRC:-/srv/nas}
RTB=${RTB:-/mnt/backup/rtb_nas}
RTB_SCRIPT=${RTB_SCRIPT:-/opt/apps/rtb/rsync_tmbackup.sh}
RTB_STAGED_SCRIPT=${RTB_STAGED_SCRIPT:-/opt/apps/rtb/rtb_staged_backup.sh}
# 1 = mehrere rsync-Einheiten pro Snapshot (RAM ~600 MB/Einheit statt ~5 GB+ monolithisch)
RTB_STAGED=${RTB_STAGED:-1}
RTB_EXCL=${RTB_EXCL:-/opt/apps/rtb/excludes.txt}
RTB_AUTO_EXCLUDE_RESTORE=${RTB_AUTO_EXCLUDE_RESTORE:-1}
RTB_RESTORE_EXCLUDE_PATTERN=${RTB_RESTORE_EXCLUDE_PATTERN:-/restore/}

# Build an effective exclude file so we can prevent backup loops (e.g. /srv/nas/restore)
# without modifying the shared rsync_tmbackup.sh.
EFFECTIVE_RTB_EXCL="$RTB_EXCL"
TMP_RTB_EXCL=""
if [[ "$RTB_AUTO_EXCLUDE_RESTORE" == "1" ]]; then
  TMP_RTB_EXCL="$(mktemp /tmp/rtb_excludes_effective.XXXXXX)"
  if [[ -f "$RTB_EXCL" ]]; then
    cp "$RTB_EXCL" "$TMP_RTB_EXCL"
  fi
  if ! grep -qF "$RTB_RESTORE_EXCLUDE_PATTERN" "$TMP_RTB_EXCL" 2>/dev/null; then
    printf '%s\n' "$RTB_RESTORE_EXCLUDE_PATTERN" >> "$TMP_RTB_EXCL"
  fi
  # Ensure downstream sudo/runas context can always read this temporary file.
  chmod 0644 "$TMP_RTB_EXCL"
  EFFECTIVE_RTB_EXCL="$TMP_RTB_EXCL"
fi

# Delta-Check: Pipeline-Pfade zusätzlich excluden (kein Backup-Trigger bei Upload).
# shellcheck source=rtb_check_excludes.sh
source "${SCRIPT_DIR}/rtb_check_excludes.sh"
TMP_RTB_CHECK_EXCL=""
EFFECTIVE_RTB_CHECK_EXCL="$EFFECTIVE_RTB_EXCL"
rtb_build_check_excludes "$EFFECTIVE_RTB_EXCL"
trap rtb_cleanup_excludes EXIT

# Load pCloud config from .env (for MariaDB credentials)
PCLOUD_MAIN_DIR=${PCLOUD_MAIN_DIR:-/opt/apps/pcloud-tools/main}
ENV_FILE="${PCLOUD_MAIN_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
  while IFS='=' read -r key val; do
    # Skip comments and empty lines
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue
    # Remove inline comments
    val=$(echo "$val" | sed 's/[[:space:]]#.*//')
    # Trim whitespace
    val=$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    # Remove quotes
    if [[ "$val" =~ ^\"(.*)\"$ ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    # Export variable
    export "${key}=${val}"
  done < "$ENV_FILE"
fi

# MariaDB Config (from .env or defaults)
PCLOUD_DB_HOST="${PCLOUD_DB_HOST:-localhost}"
PCLOUD_DB_PORT="${PCLOUD_DB_PORT:-3306}"
PCLOUD_DB_NAME="${PCLOUD_DB_NAME:-pcloud_backup}"
PCLOUD_DB_USER="${PCLOUD_DB_USER:-pcloud_backup}"
PCLOUD_DB_PASS="${PCLOUD_DB_PASS:-}"

# Bei "keine Änderungen": 1 = sofort Exit 0 (Default), 0 = trotzdem Backup fahren
NO_CHANGE_EXIT0=${NO_CHANGE_EXIT0:-1}

# Optionaler Zwangslauf per Flag
FORCE=0
if [[ "${1:-}" == "--force" ]]; then FORCE=1; shift; fi

# ===== UPLOAD-ONLY mode ==============================================
# Upload existing snapshot to pCloud without creating new RTB backup.
# Use case: Re-upload after pCloud issues, or test uploads.
#   /opt/apps/rtb/rtb_pool_wrapper.sh --upload-only /mnt/backup/rtb_nas/2026-04-10-075334
UPLOAD_ONLY_SNAPSHOT=""
if [[ "${1:-}" == "--upload-only" ]]; then
  UPLOAD_ONLY_SNAPSHOT="${2:-}"
  if [[ -z "$UPLOAD_ONLY_SNAPSHOT" || ! -d "$UPLOAD_ONLY_SNAPSHOT" ]]; then
    echo "❌ ERROR: --upload-only requires valid snapshot path"
    echo "Usage: $0 --upload-only /mnt/backup/rtb_nas/SNAPSHOT_NAME"
    exit 1
  fi
  shift 2
fi

# ===== FINALIZE-ONLY mode ============================================
# Integrity-Gate + .upload_complete + Index — wenn Pool+Stubs schon remote sind.
#   /opt/apps/rtb/rtb_pool_wrapper.sh --finalize-only /mnt/backup/rtb_nas/2026-08-12-040144
FINALIZE_ONLY_SNAPSHOT=""
if [[ "${1:-}" == "--finalize-only" ]]; then
  FINALIZE_ONLY_SNAPSHOT="${2:-}"
  if [[ -z "$FINALIZE_ONLY_SNAPSHOT" || ! -d "$FINALIZE_ONLY_SNAPSHOT" ]]; then
    echo "❌ ERROR: --finalize-only requires valid snapshot path"
    echo "Usage: $0 --finalize-only /mnt/backup/rtb_nas/SNAPSHOT_NAME"
    exit 1
  fi
  shift 2
fi

if [[ -n "$UPLOAD_ONLY_SNAPSHOT" && -n "$FINALIZE_ONLY_SNAPSHOT" ]]; then
  echo "❌ ERROR: --upload-only and --finalize-only are mutually exclusive"
  exit 1
fi

# ===== CHECK-ONLY mode ===============================================
# Read-only live dry-run: flock (ein Lauf), Cache bei Überlappung, kein Backup-Log.
# Used by aggregate_status.sh to get current change-detection result.
#   exit 0 + "no_changes"        → source == latest snapshot
#   exit 1 + "changes_detected"  → new/changed/deleted files found
#   exit 0 + "no_baseline"       → no latest snapshot yet (first run)
#   exit 2 + "error"             → rsync failed
#   exit 3 + "check_busy"        → anderer Check läuft, kein frischer Cache
if [[ "${1:-}" == "--check-only" ]]; then
  LAST="$(readlink -f "${RTB}/latest" 2>/dev/null || true)"
  if [[ -z "$LAST" || ! -d "$LAST" ]]; then
    echo "[RTB Wrapper] no_baseline → No previous backup snapshot found (first run needed)"
    exit 0
  fi
  rtb_check_only_run_locked "${SRC}" "${LAST}" "${EFFECTIVE_RTB_CHECK_EXCL}" "${EFFECTIVE_RTB_EXCL}" "${SCRIPT_DIR}"
  exit $?
fi

# === EntropyWatcher Safety-Gate ===
ENTROPYWATCHER_ENABLE=${ENTROPYWATCHER_ENABLE:-1}
ENTROPYWATCHER_SAFETY_GATE=${ENTROPYWATCHER_SAFETY_GATE:-/opt/apps/entropywatcher/main/safety_gate.sh}
SAFETY_GATE_STRICT=${SAFETY_GATE_STRICT:-0}  # 0 = YELLOW erlaubt (wie backup-pipeline.service); 1 = auch YELLOW blockieren

# Gemeinsames Lock mit pCloud-Sync + Entropy/AV (nas_heavy_ops_lock.sh)
LOCKFILE=${LOCKFILE:-${NAS_HEAVY_OPS_LOCKFILE:-/run/backup_pipeline.lock}}
WAIT_SEC=${WAIT_SEC:-${NAS_HEAVY_OPS_WAIT_SEC:-7200}}

# ========= Logging =========
RTB_LOG=${RTB_LOG:-/var/log/backup/rtb_wrapper.log}
mkdir -p "$(dirname "$RTB_LOG")"
# Unter systemd: direkt append (kein tee-Pipe — vermeidet RAM-Backpressure bei viel stdout).
# Manuell/interaktiv: tee für Konsole + Log.
if [[ -n "${INVOCATION_ID:-}" ]]; then
  exec >>"$RTB_LOG" 2>&1
else
  exec > >(tee -a "$RTB_LOG") 2>&1
fi

log(){ printf "%s %s\n" "$(date '+%F %T')" "$*"; }

log "[cfg] Source: $SRC"
log "[cfg] Excludes: $EFFECTIVE_RTB_EXCL"
if [[ "$RTB_AUTO_EXCLUDE_RESTORE" == "1" ]]; then
  log "[cfg] Loop guard exclude active: $RTB_RESTORE_EXCLUDE_PATTERN"
fi

# ===== EntropyWatcher Safety-Check (vor Lock — Gate ist schnell, kein Heavy-Op) =====
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

# ===== Lock holen (Backup + pCloud + exkl. parallele AV/Entropy auf /srv/nas) =====
if [[ "${NAS_HEAVY_OPS_FAIL_FAST:-0}" == "1" ]] && nas_heavy_ops_is_busy; then
  log "[skip] NAS-Heavy-Ops-Lock belegt (pCloud/AV/anderer RTB) — Fail-Fast"
  exit 0
fi
if ! nas_heavy_ops_acquire "$WAIT_SEC"; then
  log "[skip] Konnte NAS-Heavy-Ops-Lock innerhalb ${WAIT_SEC}s nicht bekommen."
  exit 0
fi

log "[start] RTB"

# ===== Upload-Only Shortcut ==========================================
if [[ -n "$UPLOAD_ONLY_SNAPSHOT" ]]; then
  log "[upload-only] Überspringe RTB-Backup, starte direkt pCloud-Upload (POOL-MODE)"
  log "[upload-only] Snapshot: $UPLOAD_ONLY_SNAPSHOT"
  
  PCLOUD_WRAPPER=${PCLOUD_WRAPPER:-/opt/apps/pcloud-tools/main/wrapper_pcloud_pool_sync_1to1.sh}
  PCLOUD_ENABLE=${PCLOUD_ENABLE:-1}
  
  if [[ "$PCLOUD_ENABLE" -eq 1 && -x "$PCLOUD_WRAPPER" ]]; then
    log "[start] pCloud-Sync (upload-only mode)"
    pcloud_out_file="$(mktemp /tmp/rtb_pcloud_upload_only.XXXXXX)"
    set +e
    BACKUP_PIPELINE_LOCKED=1 bash "$PCLOUD_WRAPPER" "$UPLOAD_ONLY_SNAPSHOT" 2>&1 | tee "$pcloud_out_file"
    PCLOUD_EXIT=${PIPESTATUS[0]}
    set -e

    if [[ $PCLOUD_EXIT -eq 0 ]]; then
      if grep -qE 'Sync wird übersprungen|Preflight fehlgeschlagen' "$pcloud_out_file"; then
        log "[skip] pCloud-Sync übersprungen (Preflight nicht OK)"
      else
        log "[done] pCloud-Sync erfolgreich ✓"
      fi
      rm -f "$pcloud_out_file" || true
      exit 0
    fi

    rm -f "$pcloud_out_file" || true
    log "[error] pCloud-Sync fehlgeschlagen (Exit $PCLOUD_EXIT)"
    exit $PCLOUD_EXIT
  else
    log "[error] pCloud-Sync nicht verfügbar: $PCLOUD_WRAPPER"
    exit 1
  fi
fi

# ===== Finalize-Only Shortcut ==========================================
if [[ -n "$FINALIZE_ONLY_SNAPSHOT" ]]; then
  log "[finalize-only] Überspringe RTB-Backup und Upload — nur Integrity + Complete + Index"
  log "[finalize-only] Snapshot: $FINALIZE_ONLY_SNAPSHOT"
  log "[finalize-only] Voraussetzung: Pool-Dateien + Stubs bereits remote (Phase 4 war OK)"

  PCLOUD_WRAPPER=${PCLOUD_WRAPPER:-/opt/apps/pcloud-tools/main/wrapper_pcloud_pool_sync_1to1.sh}
  PCLOUD_ENABLE=${PCLOUD_ENABLE:-1}

  if [[ "$PCLOUD_ENABLE" -eq 1 && -x "$PCLOUD_WRAPPER" ]]; then
    log "[start] pCloud-Finalize (finalize-only mode)"
    pcloud_out_file="$(mktemp /tmp/rtb_pcloud_finalize_only.XXXXXX)"
    set +e
    BACKUP_PIPELINE_LOCKED=1 bash "$PCLOUD_WRAPPER" "$FINALIZE_ONLY_SNAPSHOT" --finalize-only 2>&1 | tee "$pcloud_out_file"
    PCLOUD_EXIT=${PIPESTATUS[0]}
    set -e

    if [[ $PCLOUD_EXIT -eq 0 ]]; then
      if grep -qE 'Sync wird übersprungen|Preflight fehlgeschlagen' "$pcloud_out_file"; then
        log "[skip] pCloud-Finalize übersprungen (Preflight nicht OK)"
      else
        log "[done] pCloud-Finalize erfolgreich ✓"
      fi
      rm -f "$pcloud_out_file" || true
      exit 0
    fi

    rm -f "$pcloud_out_file" || true
    log "[error] pCloud-Finalize fehlgeschlagen (Exit $PCLOUD_EXIT)"
    exit $PCLOUD_EXIT
  else
    log "[error] pCloud-Sync nicht verfügbar: $PCLOUD_WRAPPER"
    exit 1
  fi
fi

# ===== Pre-Check: Änderungen seit letztem Snapshot? =====
LAST="$(readlink -f "${RTB}/latest" 2>/dev/null || true)"
SKIP_RTB_BACKUP=0
STAGED_RESUME=0

if [[ -f "${RTB}/backup.inprogress" && -f "${RTB}/.rtb_staged_active" ]]; then
  STAGED_RESUME=1
  log "[resume] Staged-Backup offen — Delta-Check übersprungen"
fi

if [[ "$STAGED_RESUME" -eq 0 && -n "$LAST" && -d "$LAST" ]]; then
  log "[check] Prüfe auf Änderungen seit letztem Snapshot..."

  set +e
  export RTB_TRIGGER_IN_BACKUP=1
  rtb_backup_trigger_run_locked "${SRC}" "$LAST" "${EFFECTIVE_RTB_CHECK_EXCL}" "${EFFECTIVE_RTB_EXCL}" "${SCRIPT_DIR}"
  trigger_rc=$?
  unset RTB_TRIGGER_IN_BACKUP
  set +e

  log "[check] Delta-Check exit=$trigger_rc"

  if [[ $trigger_rc -eq 2 ]]; then
    log "[error] Delta-Check fehlgeschlagen (rsync) - Backup abgebrochen"
    exit 2
  elif [[ $trigger_rc -eq 1 ]]; then
    log "[info] Änderungen erkannt - starte Backup"
  else
    if [[ $trigger_rc -eq 3 ]]; then
      log "[check] Delta-Check busy (anderer Scan läuft, kein Cache) — überspringe Backup diesmal"
      exit 0
    fi
    log "[skip] Keine Änderungen seit letztem Backup - kein neuer Snapshot nötig"
    
    # Prüfe pCloud-Upload-Status für diesen Snapshot
    SNAPSHOT_NAME=$(basename "$LAST")
    log "[check] Prüfe pCloud-Upload-Status für $SNAPSHOT_NAME..."
    
    # MariaDB-Query: War Upload erfolgreich?
    set +e
    PCLOUD_SUCCESS_COUNT=$(MYSQL_PWD="$PCLOUD_DB_PASS" mysql \
      -h "$PCLOUD_DB_HOST" \
      -P "$PCLOUD_DB_PORT" \
      -u "$PCLOUD_DB_USER" \
      -D "$PCLOUD_DB_NAME" \
      -sN -e "SELECT COUNT(*) FROM backup_runs WHERE snapshot_name='$SNAPSHOT_NAME' AND status='SUCCESS'" 2>/dev/null)
    MYSQL_EXIT=$?
    set -e
    
    if [[ $MYSQL_EXIT -ne 0 || -z "$PCLOUD_SUCCESS_COUNT" ]]; then
      log "[error] pCloud-Status konnte nicht geprüft werden (MariaDB-Fehler: Exit $MYSQL_EXIT)"
      log "[error] Credentials: $PCLOUD_DB_USER@$PCLOUD_DB_HOST:$PCLOUD_DB_PORT/$PCLOUD_DB_NAME"
      log "[abort] Abbruch - DB-Zugriff erforderlich für sichere Operation"
      exit 3
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
  # Upstream-Flags ohne --itemize-changes (RAM/Log nur im Wrapper steuern, nicht im Fork).
  RTB_BACKUP_RSYNC_FLAGS="${RTB_BACKUP_RSYNC_FLAGS:--D --numeric-ids --links --hard-links --one-file-system --times --recursive --perms --owner --group --stats}"
  rtb_backup_out="$(mktemp /tmp/rtb_backup_capture.XXXXXX)"
  set +e
  if [[ "$RTB_STAGED" == "1" && -x "$RTB_STAGED_SCRIPT" ]]; then
    log "[start] rtb_staged_backup (mehrere rsync-Einheiten, RAM-schonend)"
    sudo bash "$RTB_STAGED_SCRIPT" --rsync-set-flags "$RTB_BACKUP_RSYNC_FLAGS" "$SRC" "$RTB" "$EFFECTIVE_RTB_EXCL" >"$rtb_backup_out" 2>&1
  else
    log "[start] rsync_tmbackup (upstream-Skript, Wrapper-Flags ohne itemize)"
    sudo bash "$RTB_SCRIPT" --rsync-set-flags "$RTB_BACKUP_RSYNC_FLAGS" "$SRC" "$RTB" "$EFFECTIVE_RTB_EXCL" >"$rtb_backup_out" 2>&1
  fi
  RTB_EXIT=$?
  grep -E '(rsync_tmbackup|rtb_staged_backup):|\[RTB BackupSummary JSON\]' "$rtb_backup_out" || true
  if [[ $RTB_EXIT -eq 0 && "$RTB_STAGED" == "1" ]]; then
    _snap_name="$(basename "$(readlink -f "${RTB}/latest" 2>/dev/null || echo "")")"
    _staged_log="${HOME:-/root}/.rsync_tmbackup/${_snap_name}.log"
    if [[ -n "$_snap_name" && -f "$_staged_log" ]]; then
      grep -E '(rtb_staged_backup):|\[RTB BackupSummary JSON\]' "$_staged_log" || true
    fi
  fi
  if [[ $RTB_EXIT -ne 0 ]]; then
    log "[error] rsync_tmbackup Ausgabe (Auszug):"
    tail -40 "$rtb_backup_out" || true
  fi
  rm -f "$rtb_backup_out"
  set +e

  if [[ $RTB_EXIT -ne 0 ]]; then
    log "[ABORT] RTB fehlgeschlagen (Exit $RTB_EXIT) - pCloud-Sync wird übersprungen"
    exit $RTB_EXIT
  fi

  log "[done] RTB erfolgreich"
fi

# ===== pCloud-Sync starten (POOL-MODE) =====
PCLOUD_WRAPPER=${PCLOUD_WRAPPER:-/opt/apps/pcloud-tools/main/wrapper_pcloud_pool_sync_1to1.sh}
PCLOUD_ENABLE=${PCLOUD_ENABLE:-1}

if [[ "$PCLOUD_ENABLE" -eq 1 && -x "$PCLOUD_WRAPPER" ]]; then
  log "[start] pCloud-Sync POOL-MODE (automatisch nach RTB)"
  pcloud_out_file="$(mktemp /tmp/rtb_pcloud_pipeline.XXXXXX)"
  set +e
  # Kein tee auf Parent-stdout — voller pCloud-Log nur in Temp, Kurzzeilen ins Wrapper-Log.
  BACKUP_PIPELINE_LOCKED=1 bash "$PCLOUD_WRAPPER" >"$pcloud_out_file" 2>&1
  PCLOUD_EXIT=$?
  grep -E '^\[(INFO|WARN|ERROR|manifest|scan|upload)\]' "$pcloud_out_file" 2>/dev/null | tail -50 || true
  set -e

  if [[ $PCLOUD_EXIT -eq 0 ]]; then
    if grep -qE 'Sync wird übersprungen|Preflight fehlgeschlagen' "$pcloud_out_file"; then
      log "[skip] pCloud-Sync übersprungen (Preflight nicht OK)"
      log "[done] Backup-Pipeline komplett (RTB ok, pCloud übersprungen)"
    else
      log "[done] pCloud-Sync erfolgreich"
      log "[done] Backup-Pipeline komplett ✓"
    fi
    rm -f "$pcloud_out_file" || true
  else
    rm -f "$pcloud_out_file" || true
    log "[error] pCloud-Sync fehlgeschlagen (Exit $PCLOUD_EXIT)"
    exit $PCLOUD_EXIT
  fi
else
  log "[skip] pCloud-Sync deaktiviert oder nicht verfügbar"
  log "[done] RTB-Pipeline komplett (ohne pCloud)"
fi

