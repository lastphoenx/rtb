# rtb_check_excludes.sh — Delta-Check-Excludes (sourcen, nicht ausführen).
# Pipeline-Ordner unter /srv/nas sollen kein Backup triggern; beim echten rsync bleiben sie dabei.

rtb_build_check_excludes() {
  local base="${1:?}"
  TMP_RTB_CHECK_EXCL="$(mktemp /tmp/rtb_excludes_check.XXXXXX)"
  if [[ -f "$base" ]]; then
    cp "$base" "$TMP_RTB_CHECK_EXCL"
  else
    : >"$TMP_RTB_CHECK_EXCL"
  fi
  for pat in '/pcloud-archive/' '/pcloud-temp/'; do
    grep -qF "$pat" "$TMP_RTB_CHECK_EXCL" 2>/dev/null || printf '%s\n' "$pat" >>"$TMP_RTB_CHECK_EXCL"
  done
  chmod 0644 "$TMP_RTB_CHECK_EXCL"
  EFFECTIVE_RTB_CHECK_EXCL="$TMP_RTB_CHECK_EXCL"
}

rtb_cleanup_excludes() {
  [[ -n "${TMP_RTB_EXCL:-}" ]] && rm -f "$TMP_RTB_EXCL"
  [[ -n "${TMP_RTB_CHECK_EXCL:-}" ]] && rm -f "$TMP_RTB_CHECK_EXCL"
}
