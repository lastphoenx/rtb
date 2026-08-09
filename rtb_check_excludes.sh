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

rtb_emit_trigger_analysis_from_file() {
  local delta_file="$1" script_dir="$2" last="$3"
  rtb_delta_itemize_lines "$delta_file" | python3 "${script_dir}/rtb_check_only_delta.py" \
    --analyze --top-n 10 \
    --trigger-only /pcloud-archive/ --trigger-only /pcloud-temp/ \
    "${last}" 2>/dev/null || true
}

rtb_analyze_trigger_file() {
  local delta_file="$1" script_dir="$2" last="$3"
  local analysis
  if ! rtb_delta_itemize_lines "$delta_file" | grep -q .; then
    return 1
  fi
  if ! command -v python3 &>/dev/null; then
    return 0
  fi
  analysis=$(rtb_emit_trigger_analysis_from_file "$delta_file" "${script_dir}" "${last}")
  if echo "$analysis" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('has_real_trigger') else 1)" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Backup-Scope-JSON: Nutzerdaten ausser pcloud-archive/temp?
rtb_scope_json_has_user_delta() {
  local scope_json="$1"
  [[ -n "$scope_json" ]] || return 1
  echo "$scope_json" | python3 -c "
import json, sys
skip = {'pcloud-archive', 'pcloud-temp', '.'}
d = json.load(sys.stdin)
n = sum(r['count'] for r in d.get('top_dirs', []) if r.get('dir') not in skip)
sys.exit(0 if n > 0 else 1)
" 2>/dev/null
}

# rsync -ni gegen RTB latest. Ausgabe in Temp-Datei (nicht $() — große Deltas + stderr).
# Setzt RTB_DELTA_FILE, RTB_DELTA_ERR, RTB_DELTA_RSYNC_RC. Caller räumt Temp-Dateien auf.
# RTB_CHECK_MEMORY_MAX_MB: optional prlimit --as=… (0/leer = aus). Schutz in Produktion via systemd MemoryMax.
rtb_invoke_rsync_ni() {
  local limit_mb="${RTB_CHECK_MEMORY_MAX_MB:-0}"
  if command -v prlimit &>/dev/null && [[ "$limit_mb" =~ ^[0-9]+$ ]] && (( limit_mb > 0 )); then
    prlimit --as="$((limit_mb * 1024 * 1024))" "$@"
  else
    "$@"
  fi
}

rtb_run_delta_rsync_ni() {
  local src="$1" last="$2" excl_file="$3"
  RTB_DELTA_FILE="$(mktemp /tmp/rtb_check_rsync_out.XXXXXX)"
  RTB_DELTA_ERR="$(mktemp /tmp/rtb_check_rsync_err.XXXXXX)"
  set +e
  if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
    rtb_invoke_rsync_ni sudo -n rsync -ni --delete \
      --links --hard-links --one-file-system --times --recursive \
      --perms --owner --group \
      --exclude-from "${excl_file}" \
      "${src}/" "${last}/" >"$RTB_DELTA_FILE" 2>"$RTB_DELTA_ERR"
  else
    rtb_invoke_rsync_ni rsync -ni --delete \
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

# Ein rsync -ni (check_excludes) + Python-Filter: 0=keine Änderung, 1=Backup nötig, 2=Fehler
rtb_trigger_delta_core() {
  local src="$1" last="$2" check_excl="$3" script_dir="$4"
  local delta_file delta_err rsync_rc quiet="${RTB_CHECK_QUIET:-0}"
  local analysis_json delta_json pipe_json

  rtb_run_delta_rsync_ni "$src" "$last" "$check_excl"
  delta_file="$RTB_DELTA_FILE"
  delta_err="$RTB_DELTA_ERR"
  rsync_rc=$RTB_DELTA_RSYNC_RC

  if [[ $rsync_rc -ne 0 ]]; then
    [[ "$quiet" != "1" ]] && echo "[RTB Wrapper] error → rsync check failed (exit code: $rsync_rc)"
    if [[ "$quiet" != "1" && $rsync_rc -eq 1 ]]; then
      echo "[RTB Wrapper] hint: sudo -n rsync failed; ensure NOPASSWD for rsync in service context"
    fi
    if [[ "$quiet" != "1" && -s "$delta_err" ]]; then
      echo "[RTB Wrapper] rsync stderr:"
      cat "$delta_err"
    fi
    rm -f "$delta_file" "$delta_err" || true
    return 2
  fi

  if rtb_analyze_trigger_file "$delta_file" "${script_dir}" "${last}"; then
    [[ "$quiet" != "1" ]] && echo "[RTB Wrapper] changes_detected → Backup needed (new/changed/deleted files found)"
    if [[ "$quiet" != "1" ]] && command -v python3 &>/dev/null; then
      analysis_json=$(rtb_emit_trigger_analysis_from_file "$delta_file" "${script_dir}" "${last}")
      if [[ -n "$analysis_json" ]]; then
        delta_json=$(echo "$analysis_json" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['trigger_real']))" 2>/dev/null || true)
        [[ -n "$delta_json" ]] && echo "[RTB Delta JSON] ${delta_json}"
      fi
    fi
    rm -f "$delta_file" "$delta_err" || true
    return 1
  fi

  if rtb_delta_itemize_lines "$delta_file" | grep -q .; then
    [[ "$quiet" != "1" ]] && echo "[RTB Wrapper] no_changes → No backup needed (only pipeline paths changed)"
    if [[ "$quiet" != "1" ]] && command -v python3 &>/dev/null; then
      analysis_json=$(rtb_emit_trigger_analysis_from_file "$delta_file" "${script_dir}" "${last}")
      if [[ -n "$analysis_json" ]]; then
        pipe_json=$(echo "$analysis_json" | python3 -c "import json,sys; d=json.load(sys.stdin)['trigger_pipeline_only']; print(json.dumps(d) if d.get('count') else '')" 2>/dev/null || true)
        [[ -n "$pipe_json" ]] && echo "[RTB PipelineOnly JSON] ${pipe_json}"
      fi
    fi
  else
    [[ "$quiet" != "1" ]] && echo "[RTB Wrapper] no_changes → No backup needed (source == latest snapshot)"
  fi
  rm -f "$delta_file" "$delta_err" || true
  return 0
}

# Produktion (Legacy-Exit): 0=Änderungen, 1=nein, 2=Fehler — nutzt intern nur noch einen Scan.
rtb_detect_real_trigger_changes() {
  local rc
  set +e
  rtb_trigger_delta_core "$1" "$2" "$3" "$5"
  rc=$?
  set -e
  case "$rc" in
    1) return 0 ;;
    0) return 1 ;;
    *) return "$rc" ;;
  esac
}

# Produktion: Lock + Cache (15 min), kein Dashboard-Scope-Scan.
# Exit: 0=keine Änderung, 1=Backup nötig, 2=Fehler, 3=busy (kein frischer Cache)
rtb_backup_trigger_run_locked() {
  local src="$1" last="$2" check_excl="$3" backup_excl="$4" script_dir="$5"
  local lock_file="${RTB_CHECK_ONLY_LOCKFILE:-/run/rtb_check_only.lock}"
  local cache_out="${RTB_CHECK_ONLY_CACHE:-/run/rtb_check_only_cache.out}"
  local cache_meta="${RTB_CHECK_ONLY_CACHE_META:-/run/rtb_check_only_cache.meta}"
  local tmp_out rc

  exec 9>"$lock_file"
  if ! flock -n 9; then
    if rtb_check_only_cache_fresh "$last"; then
      rtb_check_only_serve_cache >/dev/null
      return $?
    fi
    return 3
  fi

  if [[ -f "${script_dir}/nas_heavy_ops_lock.sh" ]]; then
    # shellcheck source=nas_heavy_ops_lock.sh
    source "${script_dir}/nas_heavy_ops_lock.sh"
    if nas_heavy_ops_is_busy; then
      if rtb_check_only_cache_fresh "$last"; then
        rtb_check_only_serve_cache >/dev/null
        return $?
      fi
      return 3
    fi
  fi

  RTB_CHECK_QUIET=1
  export RTB_CHECK_QUIET
  tmp_out="$(mktemp /tmp/rtb_backup_trigger_capture.XXXXXX)"
  set +e
  rtb_trigger_delta_core "$src" "$last" "$check_excl" "$script_dir" | tee "$tmp_out"
  rc=${PIPESTATUS[0]}
  set -e
  unset RTB_CHECK_QUIET

  cp "$tmp_out" "$cache_out"
  printf 'ts=%s\nexit=%s\nbaseline=%s\n' "$(date +%s)" "$rc" "$last" >"$cache_meta"
  chmod 0644 "$cache_out" "$cache_meta" 2>/dev/null || true
  rm -f "$tmp_out"
  return "$rc"
}

# --check-only: flock + optional cache (verhindert parallele Vollbaum-Scans).
RTB_CHECK_ONLY_LOCKFILE=${RTB_CHECK_ONLY_LOCKFILE:-/run/rtb_check_only.lock}
RTB_CHECK_ONLY_CACHE=${RTB_CHECK_ONLY_CACHE:-/run/rtb_check_only_cache.out}
RTB_CHECK_ONLY_CACHE_META=${RTB_CHECK_ONLY_CACHE_META:-/run/rtb_check_only_cache.meta}
RTB_CHECK_ONLY_CACHE_TTL_SEC=${RTB_CHECK_ONLY_CACHE_TTL_SEC:-900}

rtb_check_only_cache_fresh() {
  local expected_baseline="$1"
  local meta="$RTB_CHECK_ONLY_CACHE_META"
  local out="$RTB_CHECK_ONLY_CACHE"
  local ts now ttl cached_baseline
  [[ -f "$meta" && -f "$out" ]] || return 1
  ts=$(grep -m1 '^ts=' "$meta" 2>/dev/null | cut -d= -f2-)
  cached_baseline=$(grep -m1 '^baseline=' "$meta" 2>/dev/null | cut -d= -f2-)
  [[ -n "$ts" && -n "$cached_baseline" && "$cached_baseline" == "$expected_baseline" ]] || return 1
  ttl="${RTB_CHECK_ONLY_CACHE_TTL_SEC:-900}"
  now=$(date +%s)
  [[ $((now - ts)) -lt "$ttl" ]]
}

rtb_check_only_serve_cache() {
  cat "$RTB_CHECK_ONLY_CACHE"
  local rc
  rc=$(grep -m1 '^exit=' "$RTB_CHECK_ONLY_CACHE_META" 2>/dev/null | cut -d= -f2-)
  return "${rc:-2}"
}

# Wrapper um rtb_check_only_with_scope: ein Lauf gleichzeitig, Cache bei Überlappung.
# Exit: 0=no_changes, 1=changes_detected, 2=error, 3=busy (kein Cache)
rtb_check_only_run_locked() {
  local src="$1" last="$2" check_excl="$3" backup_excl="$4" script_dir="$5"
  local lock_file="${RTB_CHECK_ONLY_LOCKFILE:-/run/rtb_check_only.lock}"
  local cache_out="${RTB_CHECK_ONLY_CACHE:-/run/rtb_check_only_cache.out}"
  local cache_meta="${RTB_CHECK_ONLY_CACHE_META:-/run/rtb_check_only_cache.meta}"
  local tmp_out rc

  exec 8>"$lock_file"
  if ! flock -n 8; then
    if rtb_check_only_cache_fresh "$last"; then
      echo "[RTB Wrapper] check_cached → serving cached result (another check still running)"
      rtb_check_only_serve_cache
      return $?
    fi
    echo "[RTB Wrapper] check_busy → another --check-only is still running (no fresh cache)"
    return 3
  fi

  # Kein rsync-Dry-Run während Backup/AV/Entropy (gleicher NAS-Lock)
  if [[ -f "${script_dir}/nas_heavy_ops_lock.sh" ]]; then
    # shellcheck source=nas_heavy_ops_lock.sh
    source "${script_dir}/nas_heavy_ops_lock.sh"
    if nas_heavy_ops_is_busy; then
      if rtb_check_only_cache_fresh "$last"; then
        echo "[RTB Wrapper] check_cached → heavy NAS job running, serving cache"
        rtb_check_only_serve_cache
        return $?
      fi
      echo "[RTB Wrapper] check_busy → backup/scan holds NAS lock (no fresh cache)"
      return 3
    fi
  fi

  tmp_out="$(mktemp /tmp/rtb_check_only_capture.XXXXXX)"
  set +e
  rtb_check_only_with_scope "$src" "$last" "$check_excl" "$backup_excl" "$script_dir" | tee "$tmp_out"
  rc=${PIPESTATUS[0]}
  set -e

  cp "$tmp_out" "$cache_out"
  printf 'ts=%s\nexit=%s\nbaseline=%s\n' "$(date +%s)" "$rc" "$last" >"$cache_meta"
  chmod 0644 "$cache_out" "$cache_meta" 2>/dev/null || true
  rm -f "$tmp_out"
  return "$rc"
}

# --check-only: Trigger-Delta (ein Scan) + optional Backup-Scope (Dashboard)
# Exit: 0=keine Änderung, 1=Backup nötig, 2=Fehler
rtb_check_only_with_scope() {
  local src="$1" last="$2" check_excl="$3" backup_excl="$4" script_dir="$5"
  local trigger_rc=0 analysis_json delta_json pipe_json
  local scope_file scope_err scope_json
  local emit_scope="${RTB_CHECK_EMIT_SCOPE:-1}"

  set +e
  rtb_trigger_delta_core "$src" "$last" "$check_excl" "$script_dir"
  trigger_rc=$?
  set -e

  if [[ "$emit_scope" != "1" ]] || ! command -v python3 &>/dev/null; then
    rtb_emit_exclude_policy_json "${backup_excl}" | while IFS= read -r line; do
      [[ -n "$line" ]] && echo "[RTB ExcludePolicy JSON] ${line}"
    done
    return "$trigger_rc"
  fi

  # Backup-Scope nur für --check-only / Dashboard (zweiter Scan — nicht in Produktion)
  scope_file="$(mktemp /tmp/rtb_check_scope_out.XXXXXX)"
  scope_err="$(mktemp /tmp/rtb_check_scope_err.XXXXXX)"
  set +e
  if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
    rtb_invoke_rsync_ni sudo -n rsync -ni --delete \
      --links --hard-links --one-file-system --times --recursive \
      --perms --owner --group \
      --exclude-from "${backup_excl}" \
      "${src}/" "${last}/" >"$scope_file" 2>"$scope_err"
  else
    rtb_invoke_rsync_ni rsync -ni --delete \
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
    if [[ $trigger_rc -eq 0 ]] && rtb_scope_json_has_user_delta "$scope_json"; then
      echo "[RTB Wrapper] changes_detected → Backup needed (Nutzerdaten laut Backup-Scope)"
      trigger_rc=1
      if rtb_analyze_trigger_file "$scope_file" "${script_dir}" "${last}"; then
        analysis_json=$(rtb_emit_trigger_analysis_from_file "$scope_file" "${script_dir}" "${last}")
        if [[ -n "$analysis_json" ]]; then
          delta_json=$(echo "$analysis_json" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['trigger_real']))" 2>/dev/null || true)
          if [[ -n "$delta_json" ]]; then
            echo "[RTB Delta JSON] ${delta_json}"
          fi
        fi
      fi
    fi
  fi
  rm -f "$scope_file" "$scope_err" || true

  rtb_emit_exclude_policy_json "${backup_excl}" | while IFS= read -r line; do
    [[ -n "$line" ]] && echo "[RTB ExcludePolicy JSON] ${line}"
  done

  return "$trigger_rc"
}
