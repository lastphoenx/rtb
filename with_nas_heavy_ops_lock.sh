#!/usr/bin/env bash
# Wrapper für systemd ExecStart: maximal ein schwerer NAS-Job gleichzeitig.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=nas_heavy_ops_lock.sh
source "${SCRIPT_DIR}/nas_heavy_ops_lock.sh"

if (($# < 1)); then
  echo "Usage: $0 <command> [args...]" >&2
  exit 2
fi

if ! nas_heavy_ops_acquire "${NAS_HEAVY_OPS_WAIT_SEC:-7200}"; then
  echo "[heavy-ops] Lock busy (${NAS_HEAVY_OPS_LOCKFILE}) — überspringe: $*" >&2
  nas_heavy_ops_holder_hint >&2 || true
  exit 0
fi

exec "$@"
