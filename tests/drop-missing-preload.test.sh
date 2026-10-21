#!/usr/bin/env bash
# The user environment generator that drops LD_PRELOAD entries whose library
# is gone (a stale Wayland Scroll Factor line after moving from Margine).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
gen="$here/lucciola/system_files/usr/lib/systemd/user-environment-generators/90-lucciola-drop-missing-preload"
fail=0
check() { # name, LD_PRELOAD value, expected output
  local out
  out="$(env -i PATH=/usr/bin:/bin LD_PRELOAD="$2" sh "$gen" 2>/dev/null)"
  if [[ "$out" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got [$out], want [$3]"; fail=1; fi
}
real=/bin/sh
check "missing library alone: emptied" "/nope/libwsf_preload.so" "LD_PRELOAD="
check "missing one dropped, real one kept" "$real:/nope/x.so" "LD_PRELOAD=$real"
check "space-separated list" "/nope/x.so $real" "LD_PRELOAD=$real"
check "bare name kept for ld.so to search" "libfoo.so /nope/y.so" "LD_PRELOAD=libfoo.so"
check "all present: prints nothing" "$real" ""
check "unset: prints nothing" "" ""
[[ -x "$gen" ]] || { echo "FAIL generator not executable"; fail=1; }
[[ $fail = 0 ]] && echo "all drop-missing-preload tests passed"
exit $fail
