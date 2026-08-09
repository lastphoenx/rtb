#!/usr/bin/env bash
# rtb_staged_backup.sh — Mehrere rsync-Läufe in einen RTB-Snapshot (Wrapper-only).
# rsync_tmbackup.sh bleibt 1:1 Upstream; dieses Skript ersetzt nur den einen Vollbaum-rsync.
#
# RAM: pro Einheit eigener rsync-Prozess (~600 MB Peak für .chunks statt ~5 GB+ gesamt).
# Hardlinks + --link-dest pro Teilpfad wie bei Time Machine.
set -euo pipefail

APPNAME="rtb_staged_backup"

fn_log_info()  { echo "$APPNAME: $1"; }
fn_log_warn()  { echo "$APPNAME: [WARNING] $1" >&2; }
fn_log_error() { echo "$APPNAME: [ERROR] $1" >&2; }

fn_terminate_script() {
  fn_log_info "SIGINT caught."
  exit 1
}
trap 'fn_terminate_script' SIGINT

# --- Retention (lokal, aus rsync-time-backup Logik, nur für DEST_FOLDER auf Pi) ---
fn_parse_date() {
  date -d "${1:0:10} ${1:11:2}:${1:13:2}:${1:15:2}" +%s
}

fn_find_backups() {
  find "$DEST_FOLDER/" -maxdepth 1 -type d -name '????-??-??-??????' -prune 2>/dev/null | sort -r
}

fn_expire_backup() {
  local target="$1"
  if [[ ! -f "$DEST_FOLDER/backup.marker" ]]; then
    fn_log_error "Kein backup.marker unter $DEST_FOLDER — Abbruch."
    exit 1
  fi
  fn_log_info "Expiring $target"
  rm -rf -- "$target"
}

fn_expire_backups() {
  local backup_to_keep="$1"
  local current_timestamp="$EPOCH"
  local last_kept_timestamp=9999999999
  local oldest_backup_to_keep
  oldest_backup_to_keep="$(fn_find_backups | sort | sed -n '1p')"

  local backup_dir backup_date backup_timestamp strategy_token
  for backup_dir in $(fn_find_backups | sort); do
    backup_date=$(basename "$backup_dir")
    backup_timestamp=$(fn_parse_date "$backup_date") || backup_timestamp=""
    if [[ -z "$backup_timestamp" ]]; then
      fn_log_warn "Could not parse date: $backup_dir"
      continue
    fi
    if [[ "$backup_dir" == "$backup_to_keep" ]]; then
      break
    fi
    if [[ "$backup_dir" == "$oldest_backup_to_keep" ]]; then
      last_kept_timestamp=$backup_timestamp
      continue
    fi
    for strategy_token in $(echo "$EXPIRATION_STRATEGY" | tr ' ' '\n' | sort -r -n); do
      IFS=':' read -r -a t <<< "$strategy_token"
      local cut_off_timestamp=$((current_timestamp - t[0] * 86400))
      local cut_off_interval_days=${t[1]}
      if [[ "$backup_timestamp" -le "$cut_off_timestamp" ]]; then
        if [[ "$cut_off_interval_days" -eq 0 ]]; then
          fn_expire_backup "$backup_dir"
          break
        fi
        local last_kept_timestamp_days=$((last_kept_timestamp / 86400))
        local backup_timestamp_days=$((backup_timestamp / 86400))
        local interval_since_last_kept_days=$((backup_timestamp_days - last_kept_timestamp_days))
        if [[ "$interval_since_last_kept_days" -lt "$cut_off_interval_days" ]]; then
          fn_expire_backup "$backup_dir"
          break
        else
          last_kept_timestamp=$backup_timestamp
          break
        fi
      fi
    done
  done
}

# --- Staging units ---
rtb_staged_expand_backup_units() {
  local backup_root="$1"
  local arr_name="$2"
  local -n _units=$arr_name
  local pbs2="$backup_root/pbs2"
  if [[ -d "$pbs2" ]]; then
    [[ -d "$pbs2/vm" ]] && _units+=("Backup/pbs2/vm")
    [[ -d "$pbs2/ct" ]] && _units+=("Backup/pbs2/ct")
    [[ -d "$pbs2/.chunks" ]] && _units+=("Backup/pbs2/.chunks")
    [[ -d "$pbs2/ns" ]] && _units+=("Backup/pbs2/ns")
  fi
  local sub name
  for sub in "$backup_root"/*/; do
    [[ -e "$sub" ]] || continue
    name=$(basename "$sub")
    [[ "$name" == "pbs2" ]] && continue
    _units+=("Backup/$name")
  done
}

# Einträge (Dateien+Ordner) unter root — grobe RAM-Prognose pro rsync-Einheit.
rtb_staged_entry_count() {
  find "$1" -xdev 2>/dev/null | wc -l
}

# Große Bäume (pcloud-archive: ~47k Ordner) nicht als ein Top-Level-rsync.
RTB_STAGED_SPLIT_THRESHOLD=${RTB_STAGED_SPLIT_THRESHOLD:-15000}
RTB_STAGED_TREE_SPLIT=${RTB_STAGED_TREE_SPLIT:-pcloud-archive pcloud-temp}

# excludes.txt gilt auch beim Erzeugen der Staging-Einheiten (nicht nur beim rsync).
RTB_STAGED_EXCLUDE_LINES=()

rtb_staged_load_excludes() {
  RTB_STAGED_EXCLUDE_LINES=()
  [[ -n "$EXCLUSION_FILE" && -f "$EXCLUSION_FILE" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line// /}"
    [[ -z "$line" ]] && continue
    RTB_STAGED_EXCLUDE_LINES+=("$line")
  done < "$EXCLUSION_FILE"
}

# Entspricht rsync --exclude-from für Unit-Pfade (relativ zu SRC_FOLDER).
rtb_staged_rel_excluded() {
  local rel="${1#/}"
  local pat p suffix

  for pat in "${RTB_STAGED_EXCLUDE_LINES[@]}"; do
    if [[ "$pat" == /* ]]; then
      p="${pat#/}"
      p="${p%/}"
      [[ "$rel" == "$p" || "$rel" == "$p"/* ]] && return 0
      continue
    fi
    if [[ "$pat" == */ ]]; then
      suffix="${pat%/}"
      [[ "$rel" == "$suffix" || "$rel" == */"$suffix" || "$rel" == */"$suffix"/* ]] && return 0
      continue
    fi
  done
  return 1
}

rtb_staged_should_tree_split() {
  local name="$1"
  local pat
  for pat in $RTB_STAGED_TREE_SPLIT; do
    [[ "$name" == "$pat" ]] && return 0
  done
  return 1
}

rtb_staged_emit_units() {
  local abs_root="$1"
  local rel_path="$2"
  local arr_name="$3"
  local -n _units=$arr_name
  local total child name child_count=0

  rel_path="${rel_path#/}"
  if rtb_staged_rel_excluded "$rel_path"; then
    fn_log_info "skip (exclude): $rel_path"
    return
  fi

  total=$(rtb_staged_entry_count "$abs_root")
  if [[ "$total" -le "$RTB_STAGED_SPLIT_THRESHOLD" ]]; then
    _units+=("$rel_path")
    return
  fi

  for child in "$abs_root"/*/; do
    [[ -d "$child" ]] || continue
    child_count=$((child_count + 1))
    name=$(basename "$child")
    rtb_staged_emit_units "$child" "$rel_path/$name" "$arr_name"
  done

  if [[ "$child_count" -eq 0 ]]; then
    fn_log_warn "$rel_path: $total Einträge ohne Unterordner — ein Lauf (OOM-Risiko)"
    _units+=("$rel_path")
    return
  fi

  fn_log_info "Split $rel_path ($total Einträge) → $child_count direkte Unterordner"
}

rtb_staged_expand_tree_units() {
  rtb_staged_emit_units "$1" "$2" "$3"
}

rtb_staged_list_units() {
  local src="$1"
  local -n _out=$2
  _out=()
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    [[ "$name" == "lost+found" ]] && continue
    if rtb_staged_rel_excluded "$name"; then
      fn_log_info "skip (exclude): $name"
      continue
    fi
    if [[ "$name" == "Backup" ]]; then
      rtb_staged_expand_backup_units "$src/Backup" _out
    elif rtb_staged_should_tree_split "$name"; then
      rtb_staged_expand_tree_units "$src/$name" "$name" _out
    else
      _out+=("$name")
    fi
  done < <(find "$src" -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%f\n' 2>/dev/null | sort)
}

rtb_unit_done() {
  local unit="$1"
  grep -Fxq "$unit" "$DONE_FILE" 2>/dev/null
}

rtb_mark_unit_done() {
  echo "$1" >>"$DONE_FILE"
}

# --- Args (subset von rsync_tmbackup) ---
SRC_FOLDER=""
DEST_FOLDER=""
EXCLUSION_FILE=""
LOG_DIR="${HOME}/.rsync_tmbackup"
EXPIRATION_STRATEGY="${RTB_STRATEGY:-1:1 30:7 365:30}"
RSYNC_FLAGS="-D --numeric-ids --links --hard-links --one-file-system --times --recursive --perms --owner --group --stats"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      echo "Usage: $APPNAME [--rsync-set-flags FLAGS] <SOURCE> <DEST> [exclude-file]"
      echo "Mehrere rsync-Läufe pro Snapshot-Einheit (Top-Level + Backup/pbs2 split)."
      exit 0
      ;;
    --rsync-set-flags)
      RSYNC_FLAGS="$2"
      shift 2
      ;;
    --rsync-append-flags)
      RSYNC_FLAGS="$RSYNC_FLAGS $2"
      shift 2
      ;;
    --strategy)
      EXPIRATION_STRATEGY="$2"
      shift 2
      ;;
    --log-dir)
      LOG_DIR="$2"
      shift 2
      ;;
    --)
      shift
      SRC_FOLDER="${1:-}"
      DEST_FOLDER="${2:-}"
      EXCLUSION_FILE="${3:-}"
      break
      ;;
    -*)
      fn_log_error "Unknown option: $1"
      exit 1
      ;;
    *)
      SRC_FOLDER="${1:-}"
      DEST_FOLDER="${2:-}"
      EXCLUSION_FILE="${3:-}"
      break
      ;;
  esac
done

SRC_FOLDER="${SRC_FOLDER%/}"
DEST_FOLDER="${DEST_FOLDER%/}"

if [[ -z "$SRC_FOLDER" || -z "$DEST_FOLDER" ]]; then
  fn_log_error "SOURCE und DESTINATION erforderlich."
  exit 1
fi

if [[ ! -d "$SRC_FOLDER" ]]; then
  fn_log_error "Source \"$SRC_FOLDER\" existiert nicht."
  exit 1
fi

if [[ ! -f "$DEST_FOLDER/backup.marker" ]]; then
  fn_log_error "Kein backup.marker in \"$DEST_FOLDER\"."
  exit 1
fi

mkdir -p "$LOG_DIR"

ACTIVE_FILE="$DEST_FOLDER/.rtb_staged_active"
INPROGRESS_FILE="$DEST_FOLDER/backup.inprogress"
EPOCH=$(date +%s)
MYPID=$$

# --- Resume oder neuer Snapshot ---
DEST=""
PREVIOUS_DEST=""
RESUME=0

if [[ -f "$INPROGRESS_FILE" ]]; then
  running_pid=$(cat "$INPROGRESS_FILE" 2>/dev/null || true)
  if [[ -n "$running_pid" ]] && kill -0 "$running_pid" 2>/dev/null; then
    fn_log_error "Anderer Backup-Lauf aktiv (PID $running_pid)."
    exit 1
  fi
  if [[ -f "$ACTIVE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ACTIVE_FILE"
    if [[ -n "${DEST:-}" && -d "$DEST" ]]; then
      RESUME=1
      fn_log_info "Resume Snapshot $DEST (link-dest Basis: $PREVIOUS_DEST)"
    fi
  fi
fi

if [[ "$RESUME" -eq 0 ]]; then
  NOW=$(date +"%Y-%m-%d-%H%M%S")
  DEST="$DEST_FOLDER/$NOW"
  if [[ -L "$DEST_FOLDER/latest" ]]; then
    PREVIOUS_DEST="$(readlink -f "$DEST_FOLDER/latest")"
  else
    PREVIOUS_DEST="$(fn_find_backups | head -n 1)"
  fi
  if [[ -n "$PREVIOUS_DEST" && "$PREVIOUS_DEST" == "$DEST" ]]; then
    PREVIOUS_DEST=""
  fi
  mkdir -p "$DEST"
  fn_log_info "Neuer Snapshot $DEST"
  if [[ -n "$PREVIOUS_DEST" ]]; then
    fn_log_info "Incremental link-dest: $PREVIOUS_DEST"
    fn_expire_backups "$PREVIOUS_DEST"
  else
    fn_log_info "Kein vorheriger Snapshot — Vollbackup."
  fi
  cat >"$ACTIVE_FILE" <<EOF
DEST='$DEST'
PREVIOUS_DEST='$PREVIOUS_DEST'
EOF
  DONE_FILE="$DEST/.rtb_staged_done"
  : >"$DONE_FILE"
else
  DONE_FILE="$DEST/.rtb_staged_done"
  [[ -f "$DONE_FILE" ]] || : >"$DONE_FILE"
fi

echo "$MYPID" >"$INPROGRESS_FILE"
LOG_FILE="$LOG_DIR/$(basename "$DEST").log"

rtb_staged_load_excludes
UNITS=()
rtb_staged_list_units "$SRC_FOLDER" UNITS

if [[ ${#UNITS[@]} -eq 0 ]]; then
  fn_log_error "Keine Staging-Einheiten unter $SRC_FOLDER gefunden."
  exit 1
fi

fn_log_info "Staging: ${#UNITS[@]} Einheiten"
fn_log_info "From: $SRC_FOLDER/"
fn_log_info "To:   $DEST/"

unit_idx=0
for unit in "${UNITS[@]}"; do
  unit_idx=$((unit_idx + 1))
  if rtb_unit_done "$unit"; then
    fn_log_info "[$unit_idx/${#UNITS[@]}] skip (fertig): $unit"
    continue
  fi

  src_path="$SRC_FOLDER/$unit/"
  dest_path="$DEST/$unit/"
  if [[ ! -d "$src_path" ]]; then
    fn_log_warn "[$unit_idx/${#UNITS[@]}] Quelle fehlt, überspringe: $unit"
    rtb_mark_unit_done "$unit"
    continue
  fi

  mkdir -p "$(dirname "$dest_path")"
  link_dest_opt=()
  prev_unit="$PREVIOUS_DEST/$unit"
  if [[ -n "$PREVIOUS_DEST" && -d "$prev_unit" ]]; then
    link_dest_opt=(--link-dest="$prev_unit")
  fi

  exclude_opt=()
  if [[ -n "$EXCLUSION_FILE" && -f "$EXCLUSION_FILE" ]]; then
    exclude_opt=(--exclude-from "$EXCLUSION_FILE")
  fi

  fn_log_info "[$unit_idx/${#UNITS[@]}] rsync $unit"
  unit_log="$LOG_DIR/$(basename "$DEST")-${unit//\//_}.log"

  # shellcheck disable=SC2086
  set +e
  rsync $RSYNC_FLAGS \
    --log-file "$unit_log" \
    "${exclude_opt[@]}" \
    "${link_dest_opt[@]}" \
    -- "$src_path" "$dest_path" >>"$LOG_FILE" 2>&1
  rsync_rc=$?
  set -e
  if [[ "$rsync_rc" -ne 0 ]]; then
    fn_log_error "rsync exit $rsync_rc für $unit — siehe $unit_log"
    fn_log_error "Kurz: grep -E 'rsync:|rsync error:' '$unit_log' | tail -20"
    fn_log_error "Resume: rtb_staged_backup.sh erneut (oder rtb_pool_wrapper.sh --force)"
    exit 1
  fi

  if grep -qE 'rsync error:' "$unit_log" 2>/dev/null; then
    fn_log_error "rsync meldete Fehler in $unit_log"
    exit 1
  fi

  rtb_mark_unit_done "$unit"
  fn_log_info "[$unit_idx/${#UNITS[@]}] ok: $unit"
done

# --- Finalize (wie rsync_tmbackup bei Erfolg) ---
rm -f "$DEST_FOLDER/latest"
ln -s "$(basename "$DEST")" "$DEST_FOLDER/latest"
rm -f "$INPROGRESS_FILE" "$ACTIVE_FILE"

fn_log_info "Backup completed without errors."
fn_log_info "latest -> $(basename "$DEST")"
exit 0
