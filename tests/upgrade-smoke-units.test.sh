#!/usr/bin/env bash
# The upgrade smoke's failed-unit parser (.github/scripts/upgrade-smoke.py,
# failed_unit_names): the names it hands to journalctl come from the text
# the serial console captured, so only real unit names may pass, never a
# prompt, an echo or a shell fragment; and the smoke dumps each failed
# unit's journal, with bootupctl status for the bootloader update.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE="$ROOT/.github/scripts/upgrade-smoke.py"
out="$(python3 -I - "$SMOKE" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("smoke", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
listing = "\n".join([
    "bootloader-update.service loaded failed failed Update bootloader on boot",
    "getty@tty1.service loaded failed failed Getty on tty1",
    "dev-disk.swap loaded failed failed Swap",
    "; rm -rf / loaded failed failed nasty",
    "$(reboot).service loaded failed failed nasty",
    "MPROMPT> ",
    "",
])
print(" ".join(m.failed_unit_names(listing)))
print(len(m.failed_unit_names("")))
PY
)"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails+1)); fi; }
check "real unit names pass, prompts and shell fragments do not" "$(sed -n 1p <<<"$out")" "bootloader-update.service getty@tty1.service dev-disk.swap"
check "an empty listing names nothing" "$(sed -n 2p <<<"$out")" "0"
if grep -q 'journalctl -b -u {unit} -o cat --no-pager' "$SMOKE" && grep -q 'bootupctl status' "$SMOKE"; then
  echo "ok   the smoke dumps each failed unit's journal, and bootupctl status"
else
  echo "FAIL the smoke no longer dumps the failed units' journal"; fails=$((fails+1))
fi
[ "$fails" = 0 ] && echo "upgrade-smoke units: all checks passed" || exit 1
