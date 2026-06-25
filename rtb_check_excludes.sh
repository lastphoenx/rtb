# rtb_check_excludes.sh — Delta-Check-Excludes (sourcen, nicht ausführen).
#
# ZWEI SCHICHTEN (siehe excludes.txt + README):
#   excludes.txt          → echtes rsync_tmbackup: Pattern = NIE ins Snapshot
#   rtb_check_excludes.sh → ZUSÄTZLICH nur für rsync -ni (Backup-Trigger):
#                           /pcloud-archive/, /pcloud-temp/
#                           Änderungen dort triggern kein Backup, werden aber
#                           mitgesichert wenn ein anderes Delta das Backup startet.

# Nur Check — nicht in excludes.txt (Mitgesichert bei Backup, triggert nicht)
RTB_TRIGGER_ONLY_PATTERNS=(
  '/pcloud-archive/'
  '/pcloud-temp/'
)

rtb_build_check_excludes() {
  local base="${1:?}"
  TMP_RTB_CHECK_EXCL="$(mktemp /tmp/rtb_excludes_check.XXXXXX)"
  if [[ -f "$base" ]]; then
    cp "$base" "$TMP_RTB_CHECK_EXCL"
  else
    : >"$TMP_RTB_CHECK_EXCL"
  fi
  local pat
  for pat in "${RTB_TRIGGER_ONLY_PATTERNS[@]}"; do
    grep -qF "$pat" "$TMP_RTB_CHECK_EXCL" 2>/dev/null || printf '%s\n' "$pat" >>"$TMP_RTB_CHECK_EXCL"
  done
  chmod 0644 "$TMP_RTB_CHECK_EXCL"
  EFFECTIVE_RTB_CHECK_EXCL="$TMP_RTB_CHECK_EXCL"
}

rtb_cleanup_excludes() {
  [[ -n "${TMP_RTB_EXCL:-}" ]] && rm -f "$TMP_RTB_EXCL"
  [[ -n "${TMP_RTB_CHECK_EXCL:-}" ]] && rm -f "$TMP_RTB_CHECK_EXCL"
}

# JSON für Dashboard: Exclude-Matrix (trigger_only + never_backup aus excludes.txt)
rtb_emit_exclude_policy_json() {
  local excludes_file="${1:-}"
  if ! command -v python3 &>/dev/null; then
    return 0
  fi
  python3 - "$excludes_file" "${RTB_TRIGGER_ONLY_PATTERNS[@]}" <<'PY'
import json, sys
excl = sys.argv[1]
trigger = list(sys.argv[2:])
never = []
if excl:
    try:
        with open(excl, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                never.append(line)
    except OSError:
        pass
print(json.dumps({
    "trigger_only": trigger,
    "never_backup": never,
}, ensure_ascii=False))
PY
}

# --check-only: Trigger-Delta (CHECK_EXCL) + Backup-Scope (nur excludes.txt)
# Gibt Exit-Code des Trigger-Checks zurück (0=no_changes, 1=changes_detected, 2=error)
rtb_check_only_with_scope() {
  local src="$1" last="$2" check_excl="$3" backup_excl="$4" script_dir="$5"
  local rsync_err_file check_out scope_out rsync_rc delta_json scope_json

  rsync_err_file="$(mktemp /tmp/rtb_check_only_rsync_err.XXXXXX)"
  set +e
  check_out=$(sudo -n rsync -ni --delete \
    --links --hard-links --one-file-system --times --recursive \
    --perms --owner --group \
    --exclude-from "${check_excl}" \
    "${src}/" "${last}/" 2>"${rsync_err_file}")
  rsync_rc=$?
  set -e

  local rsync_err=""
  if [[ -s "${rsync_err_file}" ]]; then
    rsync_err="$(cat "${rsync_err_file}")"
  fi
  rm -f "${rsync_err_file}" || true

  if [[ $rsync_rc -ne 0 ]]; then
    echo "[RTB Wrapper] error → rsync check failed (exit code: $rsync_rc)"
    if [[ $rsync_rc -eq 1 ]]; then
      echo "[RTB Wrapper] hint: sudo -n rsync failed; ensure NOPASSWD for rsync in service context"
    fi
    if [[ -n "${rsync_err}" ]]; then
      echo "[RTB Wrapper] rsync stderr:"
      echo "${rsync_err}"
    fi
    return 2
  fi

  local trigger_rc=0
  if echo "$check_out" | grep -qE '^[<>ch*]'; then
    echo "[RTB Wrapper] changes_detected → Backup needed (new/changed/deleted files found)"
    trigger_rc=1
    if command -v python3 &>/dev/null; then
      delta_json=$(echo "$check_out" | python3 "${script_dir}/rtb_check_only_delta.py" \
        --top-n 10 --kind trigger "${last}" 2>/dev/null || true)
      if [[ -n "$delta_json" ]]; then
        echo "[RTB Delta JSON] ${delta_json}"
      fi
    fi
  else
    echo "[RTB Wrapper] no_changes → No backup needed (source == latest snapshot)"
  fi

  # Backup-Scope: was käme ins Snapshot bei Backup jetzt (ohne trigger-only Excludes)
  if command -v python3 &>/dev/null; then
    set +e
    scope_out=$(sudo -n rsync -ni --delete \
      --links --hard-links --one-file-system --times --recursive \
      --perms --owner --group \
      --exclude-from "${backup_excl}" \
      "${src}/" "${last}/" 2>/dev/null)
    set -e
    if echo "$scope_out" | grep -qE '^[<>ch*]'; then
      scope_json=$(echo "$scope_out" | python3 "${script_dir}/rtb_check_only_delta.py" \
        --top-n 15 --kind backup_scope "${last}" 2>/dev/null || true)
      if [[ -n "$scope_json" ]]; then
        echo "[RTB BackupScope JSON] ${scope_json}"
      fi
    fi
  fi

  rtb_emit_exclude_policy_json "${backup_excl}" | while IFS= read -r line; do
    [[ -n "$line" ]] && echo "[RTB ExcludePolicy JSON] ${line}"
  done

  return "$trigger_rc"
}
