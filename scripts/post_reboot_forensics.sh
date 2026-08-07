#!/usr/bin/env bash
# Nach Reboot: letzten Boot analysieren (warum Pi nicht mehr reagierte).
set -euo pipefail

OUT="${1:-/tmp/pi-nas-forensics-$(date +%Y%m%d-%H%M%S).txt}"
exec > >(tee "$OUT") 2>&1

echo "=== pi-nas forensics $(date -Is) ==="
echo "Current boot: $(journalctl --list-boots | tail -1)"
echo ""

section() { echo ""; echo "======== $* ========"; }

section "UPTIME / LOAD / RAM"
uptime
free -h

section "PREVIOUS BOOT — OOM / kill"
journalctl -b -1 -k --no-pager 2>/dev/null | grep -iE 'oom|killed process|out of memory' | tail -30 || echo "(kein vorheriger Boot oder keine OOM-Zeilen)"

section "PREVIOUS BOOT — heavy units (letzte 80 Zeilen)"
journalctl -b -1 --no-pager -u backup-pipeline.service \
  -u entropywatcher-nas.service -u entropywatcher-nas-av.service \
  -u entropywatcher-nas-av-weekly.service -u entropywatcher-os-av.service \
  -u monitoring-status-update.service 2>/dev/null | tail -80 || true

section "PREVIOUS BOOT — gleichzeitige Starts (Überlappung?)"
journalctl -b -1 --no-pager -o short-iso 2>/dev/null | \
  grep -E 'Started entropywatcher|Started backup-pipeline|Starting backup|av-scan|rsync_tmbackup' | tail -40 || true

section "TIMER (nächste Läufe)"
systemctl list-timers --no-pager 'backup-pipeline*' 'entropywatcher*' 'monitoring-status*' 2>/dev/null || true

section "AKTIV / LOCK"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "${SCRIPT_DIR}/nas_heavy_ops_lock.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/nas_heavy_ops_lock.sh"
  if nas_heavy_ops_is_busy; then
    echo "NAS heavy-ops lock: BELEGT"
    nas_heavy_ops_holder_hint || true
  else
    echo "NAS heavy-ops lock: frei"
  fi
  echo "Active heavy units:"
  nas_heavy_ops_active_units || echo "(keine)"
fi

pgrep -af 'clamd|clamdscan|entropywatcher|pcloud_push|rsync_tmbackup' || echo "(keine schweren Prozesse)"

section "DISK /srv/nas"
df -h / /srv/nas /mnt/backup 2>/dev/null || df -h

echo ""
echo "Report: $OUT"
