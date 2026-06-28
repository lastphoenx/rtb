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
  'pcloud-archive/'
  'pcloud-temp/'
)

# rsync --exclude-from braucht beide Formen (anchored + unanchored)
RTB_TRIGGER_ONLY_EXCLUDE_FILE_PATTERNS=(
  '/pcloud-archive/'
  '/pcloud-temp/'
  'pcloud-archive/'
  'pcloud-temp/'
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
  for pat in "${RTB_TRIGGER_ONLY_EXCLUDE_FILE_PATTERNS[@]}"; do
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
    "trigger_only": ["/pcloud-archive/", "/pcloud-temp/"],
    "never_backup": never,
}, ensure_ascii=False))
PY
}

# Analysiert rsync -ni: echte Trigger-Deltas vs. nur pcloud-archive/temp
# Exit 0 = echte Änderungen, 1 = keine (evtl. nur Pipeline), 2 = rsync hatte keine Zeilen
rtb_analyze_trigger_output() {
  local check_out="$1" script_dir="$2" last="$3"
  if ! echo "$check_out" | grep -qE '^[<>ch*]'; then
    return 1
  fi
  if ! command -v python3 &>/dev/null; then
    return 0
  fi
  local analysis
  analysis=$(echo "$check_out" | python3 "${script_dir}/rtb_check_only_delta.py" \
    --analyze --top-n 10 \
    --trigger-only /pcloud-archive/ --trigger-only /pcloud-temp/ \
    "${last}" 2>/dev/null) || return 0
  if echo "$analysis" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('has_real_trigger') else 1)" 2>/dev/null; then
    return 0
  fi
  return 1
}

rtb_emit_trigger_analysis_json() {
  local check_out="$1" script_dir="$2" last="$3"
  echo "$check_out" | python3 "${script_dir}/rtb_check_only_delta.py" \
    --analyze --top-n 10 \
    --trigger-only /pcloud-archive/ --trigger-only /pcloud-temp/ \
    "${last}" 2>/dev/null || true
}

# rsync -ni gegen RTB latest. Ausgabe in Temp-Datei (nicht $() — große Deltas + stderr).
# Setzt RTB_DELTA_FILE, RTB_DELTA_ERR, RTB_DELTA_RSYNC_RC. Caller räumt Temp-Dateien auf.
rtb_run_delta_rsync_ni() {
  local src="$1" last="$2" excl_file="$3"
  RTB_DELTA_FILE="$(mktemp /tmp/rtb_check_rsync_out.XXXXXX)"
  RTB_DELTA_ERR="$(mktemp /tmp/rtb_check_rsync_err.XXXXXX)"
  set +e
  if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
    sudo -n rsync -ni --delete \
      --links --hard-links --one-file-system --times --recursive \
      --perms --owner --group \
      --exclude-from "${excl_file}" \
      "${src}/" "${last}/" >"$RTB_DELTA_FILE" 2>"$RTB_DELTA_ERR"
  else
    rsync -ni --delete \
      --links --hard-links --one-file-system --times --recursive \
      --perms --owner --group \
      --exclude-from "${excl_file}" \
      "${src}/" "${last}/" >"$RTB_DELTA_FILE" 2>"$RTB_DELTA_ERR"
  fi
  RTB_DELTA_RSYNC_RC=$?
  set -e
}

# Itemize-Zeilen aus rsync -ni (wie rtb_delta_report.sh).
rtb_delta_itemize_lines() {
  grep -E '^[<>ch*.]' "${1:?}" || true
}

# Pre-Check / --check-only: echte Nutzerdaten-Änderungen? (0=ja, 1=nein/pipeline-only, 2=rsync error)
rtb_detect_real_trigger_changes() {
  local src="$1" last="$2" check_excl="$3" script_dir="$4"
  local delta_file delta_err rsync_rc filtered

  rtb_run_delta_rsync_ni "$src" "$last" "$check_excl"
  delta_file="$RTB_DELTA_FILE"
  delta_err="$RTB_DELTA_ERR"
  rsync_rc=$RTB_DELTA_RSYNC_RC

  if [[ $rsync_rc -ne 0 ]]; then
    rm -f "$delta_file" "$delta_err" || true
    return 2
  fi

  if ! rtb_delta_itemize_lines "$delta_file" | grep -q .; then
    rm -f "$delta_file" "$delta_err" || true
    return 1
  fi

  filtered="$(rtb_delta_itemize_lines "$delta_file")"
  rm -f "$delta_file" "$delta_err" || true

  if rtb_analyze_trigger_output "$filtered" "${script_dir}" "${last}"; then
    return 0
  fi
  return 1
}

# --check-only: Trigger-Delta (CHECK_EXCL) + Backup-Scope (nur excludes.txt)
# Gibt Exit-Code des Trigger-Checks zurück (0=no_changes, 1=changes_detected, 2=error)
rtb_check_only_with_scope() {
  local src="$1" last="$2" check_excl="$3" backup_excl="$4" script_dir="$5"
  local delta_file delta_err rsync_rc filtered scope_file scope_err scope_json
  local trigger_rc=0 analysis_json delta_json pipe_json

  rtb_run_delta_rsync_ni "$src" "$last" "$check_excl"
  delta_file="$RTB_DELTA_FILE"
  delta_err="$RTB_DELTA_ERR"
  rsync_rc=$RTB_DELTA_RSYNC_RC

  if [[ $rsync_rc -ne 0 ]]; then
    echo "[RTB Wrapper] error → rsync check failed (exit code: $rsync_rc)"
    if [[ $rsync_rc -eq 1 ]]; then
      echo "[RTB Wrapper] hint: sudo -n rsync failed; ensure NOPASSWD for rsync in service context"
    fi
    if [[ -s "$delta_err" ]]; then
      echo "[RTB Wrapper] rsync stderr:"
      cat "$delta_err"
    fi
    rm -f "$delta_file" "$delta_err" || true
    return 2
  fi

  if rtb_delta_itemize_lines "$delta_file" | grep -q .; then
    filtered="$(rtb_delta_itemize_lines "$delta_file")"
    analysis_json=$(rtb_emit_trigger_analysis_json "$filtered" "${script_dir}" "${last}")
    if rtb_analyze_trigger_output "$filtered" "${script_dir}" "${last}"; then
      echo "[RTB Wrapper] changes_detected → Backup needed (new/changed/deleted files found)"
      trigger_rc=1
      if [[ -n "$analysis_json" ]] && command -v python3 &>/dev/null; then
        delta_json=$(echo "$analysis_json" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['trigger_real']))" 2>/dev/null || true)
        if [[ -n "$delta_json" ]]; then
          echo "[RTB Delta JSON] ${delta_json}"
        fi
      fi
    else
      echo "[RTB Wrapper] no_changes → No backup needed (only pipeline paths changed)"
      if [[ -n "$analysis_json" ]] && command -v python3 &>/dev/null; then
        pipe_json=$(echo "$analysis_json" | python3 -c "import json,sys; d=json.load(sys.stdin)['trigger_pipeline_only']; print(json.dumps(d) if d.get('count') else '')" 2>/dev/null || true)
        if [[ -n "$pipe_json" ]]; then
          echo "[RTB PipelineOnly JSON] ${pipe_json}"
        fi
      fi
    fi
  else
    echo "[RTB Wrapper] no_changes → No backup needed (source == latest snapshot)"
  fi

  rm -f "$delta_file" "$delta_err" || true

  # Backup-Scope: was käme ins Snapshot bei Backup jetzt (ohne trigger-only Excludes)
  if command -v python3 &>/dev/null; then
    scope_file="$(mktemp /tmp/rtb_check_scope_out.XXXXXX)"
    scope_err="$(mktemp /tmp/rtb_check_scope_err.XXXXXX)"
    set +e
    if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
      sudo -n rsync -ni --delete \
        --links --hard-links --one-file-system --times --recursive \
        --perms --owner --group \
        --exclude-from "${backup_excl}" \
        "${src}/" "${last}/" >"$scope_file" 2>"$scope_err"
    else
      rsync -ni --delete \
        --links --hard-links --one-file-system --times --recursive \
        --perms --owner --group \
        --exclude-from "${backup_excl}" \
        "${src}/" "${last}/" >"$scope_file" 2>"$scope_err"
    fi
    set -e
    if rtb_delta_itemize_lines "$scope_file" | grep -q .; then
      scope_json=$(rtb_delta_itemize_lines "$scope_file" | python3 "${script_dir}/rtb_check_only_delta.py" \
        --top-n 15 --kind backup_scope "${last}" 2>/dev/null || true)
      if [[ -n "$scope_json" ]]; then
        echo "[RTB BackupScope JSON] ${scope_json}"
      fi
    fi
    rm -f "$scope_file" "$scope_err" || true
  fi

  rtb_emit_exclude_policy_json "${backup_excl}" | while IFS= read -r line; do
    [[ -n "$line" ]] && echo "[RTB ExcludePolicy JSON] ${line}"
  done

  return "$trigger_rc"
}
