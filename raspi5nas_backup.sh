#!/usr/bin/env bash
# =============================================================================
# raspi5nas_backup.sh — Sichert kritische Raspi5-NAS-Konfigurationen nach
# /srv/nas/Backup/raspi5nas/ (NAS-Samba-Share, von dort ins pCloud-Backup).
#
# Gesichert:
#   - /opt/apps/                                   (Apps, OHNE .env-Dateien)
#   - /etc/systemd/system/                         (nur Custom-Unit-Files)
#   - MariaDB logical dumps (pcloud_backup, entropywatcher, …)
#   - C1 pool index: SQLite hot-backup + content_index_master.json
#
# Pipeline (/srv/pcloud-archive, /srv/pcloud-temp) läuft mit RTB mit, sobald
# Nutzerdaten ein Backup triggern (s. excludes + rtb_check_excludes.sh).
#
# Läuft täglich um 03:00 via raspi5nas-backup.timer, unabhängig von pCloud.
# =============================================================================
set -euo pipefail

DEST="/srv/nas/Backup/raspi5nas"
LOG="/var/log/backup/raspi5nas_backup.log"
PIPELINE_LOCK="${PIPELINE_LOCK:-/run/backup_pipeline.lock}"
PCLOUD_ARCHIVE_DIR="${PCLOUD_ARCHIVE_DIR:-/srv/pcloud-archive}"
MARIADB_DUMP_DATABASES="${MARIADB_DUMP_DATABASES:-pcloud_backup entropywatcher}"

mkdir -p "$(dirname "$LOG")"

log() { printf "%s %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

log "[start] raspi5nas Backup"

RC=0

# --- 1) /opt/apps/ ohne .env-Dateien ---
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

# --- 2) Systemd Custom-Unit-Files (keine Symlinks, keine Standard-Units) ---
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

# --- 3) MariaDB logical dumps (root + unix_socket, kein Passwort nötig) ---
_dump_cmd() {
  if command -v mariadb-dump >/dev/null 2>&1; then
    mariadb-dump
  elif command -v mysqldump >/dev/null 2>&1; then
    mysqldump
  else
    return 127
  fi
}

_dump_db() {
  local db="$1"
  local out="$2"
  if ! mysql -N -e "USE ${db}" 2>/dev/null; then
    log "[mariadb] übersprungen (DB nicht vorhanden): ${db}"
    return 0
  fi
  if ! _dump_cmd --single-transaction --routines --events "$db" 2>/dev/null | gzip -c >"$out"; then
    log "[warn] mariadb dump fehlgeschlagen: ${db}"
    return 1
  fi
  log "[mariadb] dump OK: ${db} ($(du -h "$out" | awk '{print $1}'))"
  return 0
}

DUMP_DIR="$DEST/mariadb-dumps"
mkdir -p "$DUMP_DIR"
STAMP="$(date +%Y%m%d)"
if _dump_cmd --version >/dev/null 2>&1; then
  for db in $MARIADB_DUMP_DATABASES; do
    _dump_db "$db" "$DUMP_DIR/${db}-${STAMP}.sql.gz" || RC=$?
  done
  # Gestern-Tages-Dumps entfernen (heute + gestern behalten)
  find "$DUMP_DIR" -maxdepth 1 -type f -name '*.sql.gz' -mtime +1 -delete 2>/dev/null || true
else
  log "[warn] mariadb-dump/mysqldump nicht gefunden — DB-Dumps übersprungen"
fi

# --- 4) C1 pool index (SQLite hot-backup + Master-JSON Spiegel) ---
IDX_DIR="$PCLOUD_ARCHIVE_DIR/indexes"
DEST_IDX="$DEST/pcloud-archive-indexes"
MASTER_JSON="$IDX_DIR/content_index_master.json"
SQLITE_DB="$IDX_DIR/pool_index.sqlite3"
SQLITE_OUT="$DEST_IDX/pool_index.sqlite3"

mkdir -p "$DEST_IDX"

if [[ -f "$MASTER_JSON" ]]; then
  cp -a "$MASTER_JSON" "$DEST_IDX/content_index_master.json" \
    && log "[index] Master-JSON kopiert ($(du -h "$DEST_IDX/content_index_master.json" | awk '{print $1}'))" \
    || { log "[warn] Master-JSON Kopie fehlgeschlagen"; RC=$?; }
else
  log "[index] kein Master-JSON unter $MASTER_JSON"
fi

if [[ -f "$SQLITE_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
  if flock -n "$PIPELINE_LOCK" \
    sqlite3 "$SQLITE_DB" ".backup '${SQLITE_OUT}'"; then
    log "[sqlite] pool_index hot-backup OK ($(du -h "$SQLITE_OUT" | awk '{print $1}'))"
  else
    log "[sqlite] Lock belegt — versuche backup ohne Lock (kurz)"
    if sqlite3 "$SQLITE_DB" ".backup '${SQLITE_OUT}'" 2>/dev/null; then
      log "[sqlite] pool_index backup OK (ohne Lock)"
    else
      log "[warn] pool_index backup fehlgeschlagen (Pipeline aktiv?)"
      RC=$?
    fi
  fi
elif [[ ! -f "$SQLITE_DB" ]]; then
  log "[sqlite] keine DB (C1 aus oder noch nicht importiert)"
else
  log "[warn] sqlite3 CLI fehlt — pool_index nicht gesichert"
fi

if [[ $RC -eq 0 ]]; then
    log "[done] raspi5nas Backup erfolgreich"
else
    log "[warn] raspi5nas Backup mit Warnungen beendet (RC=$RC)"
fi

exit $RC
