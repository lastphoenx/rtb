# nas_heavy_ops_lock.sh — gemeinsamer Lock für schwere /srv/nas-Jobs.
#
# Halter: RTB-Backup, pCloud-Upload, ClamAV/Entropy-Scans.
# Pfad bewusst = backup_pipeline.lock (bestehende Doku/Graceful-Shutdown).
#
# Usage (sourcen):
#   source .../nas_heavy_ops_lock.sh
#   nas_heavy_ops_acquire          # wartet bis NAS_HEAVY_OPS_WAIT_SEC
#   nas_heavy_ops_try_acquire      # sofort 0=ok 1=busy
#   nas_heavy_ops_is_busy          # 0=busy 1=frei

NAS_HEAVY_OPS_LOCKFILE=${NAS_HEAVY_OPS_LOCKFILE:-/run/backup_pipeline.lock}
NAS_HEAVY_OPS_WAIT_SEC=${NAS_HEAVY_OPS_WAIT_SEC:-7200}
NAS_HEAVY_OPS_LOCK_FD=9

nas_heavy_ops_is_busy() {
  local fd="${NAS_HEAVY_OPS_LOCK_FD}"
  eval "exec ${fd}>\"${NAS_HEAVY_OPS_LOCKFILE}\""
  if flock -n "${fd}"; then
    flock -u "${fd}" 2>/dev/null || true
    eval "exec ${fd}>&-"
    return 1
  fi
  eval "exec ${fd}>&-"
  return 0
}

nas_heavy_ops_holder_hint() {
  if command -v fuser >/dev/null 2>&1; then
    fuser -v "${NAS_HEAVY_OPS_LOCKFILE}" 2>/dev/null || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof "${NAS_HEAVY_OPS_LOCKFILE}" 2>/dev/null || true
  fi
}

nas_heavy_ops_acquire() {
  local wait_sec="${1:-${NAS_HEAVY_OPS_WAIT_SEC}}"
  local fd="${NAS_HEAVY_OPS_LOCK_FD}"
  eval "exec ${fd}>\"${NAS_HEAVY_OPS_LOCKFILE}\""
  flock -w "${wait_sec}" "${fd}"
}

nas_heavy_ops_try_acquire() {
  local fd="${NAS_HEAVY_OPS_LOCK_FD}"
  eval "exec ${fd}>\"${NAS_HEAVY_OPS_LOCKFILE}\""
  flock -n "${fd}"
}

# Units die schwere NAS-IO verursachen (für safety_gate / Forensik).
NAS_HEAVY_SYSTEMD_UNITS=(
  backup-pipeline.service
  entropywatcher-nas.service
  entropywatcher-nas-av.service
  entropywatcher-nas-av-weekly.service
  entropywatcher-os-av.service
  entropywatcher-os-av-weekly.service
)

nas_heavy_ops_active_units() {
  local u active=()
  for u in "${NAS_HEAVY_SYSTEMD_UNITS[@]}"; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then
      active+=("$u")
    fi
  done
  if ((${#active[@]})); then
    printf '%s\n' "${active[@]}"
    return 0
  fi
  return 1
}

# oom_score_adj: -1000..1000 (höher = bei OOM eher gekillt). Kinder erben vom Parent.
apply_oom_score_adj() {
  local adj="${1:-0}"
  if [[ -w /proc/self/oom_score_adj ]]; then
    echo "$adj" > /proc/self/oom_score_adj 2>/dev/null || true
  fi
}
