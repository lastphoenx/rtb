#!/usr/bin/env bash
# rtb_delta_report.sh — rsync -ni gegen RTB latest: Delta nach Top-Level-Ordnern.
# Read-only: kein Lock, kein Backup, kein Log-Write im Wrapper.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-/srv/nas}"
RTB="${RTB:-/mnt/backup/rtb_nas}"
RTB_EXCL="${RTB_EXCL:-/opt/apps/rtb/excludes.txt}"
RTB_AUTO_EXCLUDE_RESTORE="${RTB_AUTO_EXCLUDE_RESTORE:-1}"
RTB_RESTORE_EXCLUDE_PATTERN="${RTB_RESTORE_EXCLUDE_PATTERN:-/restore/}"
TOP_N=20
FULL_LISTING=0

usage() {
  cat <<'EOF'
Usage: rtb_delta_report.sh [OPTIONS]

  --source PATH       Quelle (default: /srv/nas)
  --rtb-root PATH     RTB-Verzeichnis (default: /mnt/backup/rtb_nas)
  --top-n N           Top-Level-Ordner in der Übersicht (default: 20)
  --full-listing      Zusätzlich alle rsync-Delta-Zeilen ausgeben
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SRC="$2"; shift 2 ;;
    --rtb-root) RTB="$2"; shift 2 ;;
    --top-n) TOP_N="$2"; shift 2 ;;
    --full-listing) FULL_LISTING=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

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
  chmod 0644 "$TMP_RTB_EXCL"
  EFFECTIVE_RTB_EXCL="$TMP_RTB_EXCL"
fi

# shellcheck source=rtb_check_excludes.sh
source "${SCRIPT_DIR}/rtb_check_excludes.sh"
TMP_RTB_CHECK_EXCL=""
EFFECTIVE_RTB_CHECK_EXCL="$EFFECTIVE_RTB_EXCL"
rtb_build_check_excludes "$EFFECTIVE_RTB_EXCL"

LAST="$(readlink -f "${RTB}/latest" 2>/dev/null || true)"
if [[ -z "$LAST" || ! -d "$LAST" ]]; then
  echo "Baseline: (kein Snapshot — erster RTB-Lauf nötig)"
  exit 0
fi

echo "Baseline: $LAST"
echo "Quelle:   ${SRC}/"
echo "Excludes: ${EFFECTIVE_RTB_CHECK_EXCL} (Delta-Check, inkl. Pipeline)"
echo ""

DELTA_FILE="$(mktemp /tmp/rtb_delta_report.XXXXXX)"
RSYNC_ERR="$(mktemp /tmp/rtb_delta_report_err.XXXXXX)"
trap 'rm -f "$DELTA_FILE" "$RSYNC_ERR"; rtb_cleanup_excludes' EXIT

set +e
sudo -n rsync -ni --delete \
  --links --hard-links --one-file-system --times --recursive \
  --perms --owner --group \
  --exclude-from "${EFFECTIVE_RTB_CHECK_EXCL}" \
  "${SRC}/" "$LAST/" >"$DELTA_FILE" 2>"$RSYNC_ERR"
rsync_rc=$?
set -e

if [[ $rsync_rc -ne 0 ]]; then
  echo "FEHLER: rsync check failed (exit $rsync_rc)" >&2
  if [[ -s "$RSYNC_ERR" ]]; then
    cat "$RSYNC_ERR" >&2
  fi
  exit 2
fi

FILTERED="$(grep -E '^[<>ch*.]' "$DELTA_FILE" || true)"
if [[ -z "$FILTERED" ]]; then
  echo "Keine Änderungen — Quelle entspricht dem latest Snapshot."
  exit 0
fi

if [[ "$FULL_LISTING" == "1" ]]; then
  echo "$FILTERED"
  echo ""
fi

python3 "${SCRIPT_DIR}/rtb_check_only_delta.py" \
  --format text \
  --top-n "$TOP_N" \
  "$LAST" <<<"$FILTERED"

exit 1
