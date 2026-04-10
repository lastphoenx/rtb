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
    if [[ "$NO_CHANGE_EXIT0" -eq 1 && "$FORCE" -ne 1 ]]; then
      exit 0
    else
      log "[info] no-change Override aktiv → starte Backup trotzdem"
    fi
  fi
fi

# ===== Backup fahren =====
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

# ===== pCloud-Sync starten =====
PCLOUD_WRAPPER=${PCLOUD_WRAPPER:-/opt/apps/pcloud-tools/main/wrapper_pcloud_sync_1to1.sh}
PCLOUD_ENABLE=${PCLOUD_ENABLE:-1}

if [[ "$PCLOUD_ENABLE" -eq 1 && -x "$PCLOUD_WRAPPER" ]]; then
  log "[start] pCloud-Sync (automatisch nach RTB)"
  if BACKUP_PIPELINE_LOCKED=1 bash "$PCLOUD_WRAPPER"; then
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
