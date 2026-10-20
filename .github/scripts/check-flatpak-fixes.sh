#!/usr/bin/env bash
# Regression guard for the 2026-06 Flatpak fixes (forum 12247) that no boot
# test exercises: a static assertion is the cheap insurance that a future
# edit cannot silently undo them. Run in CI (lint). Exit 1 on any regression.
#
# Until 2026-10-20 this also checked Margine's live ISO (the kickstart that
# baked the Flatpaks at install time and the GRUB entries without
# console=ttyS0). That image moved to docs/history/margine/live-env with the
# rest of the ISO tooling (review R10): Lucciola has no ISO, and a check of
# files nothing builds proves nothing. When the ISO comes back, its checks
# come back with it.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

fail=0
ok()   { printf '  OK   %s\n' "$1"; }
bad()  { printf '::error::%s\n' "$1"; fail=1; }

echo "== Flatpak fix invariants =="

# The preinstall self-heal drop-in must exist with the lockout removed.
DROPIN=build_files/system_files/usr/lib/systemd/system/flatpak-preinstall.service.d/10-margine.conf
if grep -q 'StartLimitIntervalSec=0' "$DROPIN" 2>/dev/null; then
  ok "flatpak-preinstall self-heal drop-in present (no 3-strike lockout)"
else bad "flatpak-preinstall.service.d/10-margine.conf missing or lacks StartLimitIntervalSec=0"; fi

# 4b) The relabel and repair run only when due (2026-10-20), but they must
#     still be reachable: the drop-in calls the gate before the pull and
#     marks a passed run after it, and the gate still relabels and repairs.
REPAIR=build_files/system_files/usr/libexec/margine/flatpak-repo-repair
if grep -qx 'ExecStartPre=-/usr/libexec/margine/flatpak-repo-repair' "$DROPIN" \
   && grep -qx 'ExecStartPost=-/usr/libexec/margine/flatpak-repo-repair --passed' "$DROPIN" \
   && grep -q '^restorecon -RF "\$FP"' "$REPAIR" && grep -q '^flatpak repair --system' "$REPAIR"; then
  ok "preinstall drop-in still relabels and repairs when due (flatpak-repo-repair)"
else bad "flatpak-repo-repair is no longer wired into the preinstall drop-in, or no longer runs restorecon -RF and flatpak repair"; fi

echo
[ "$fail" -eq 0 ] && echo "All Flatpak fix invariants hold." || echo "REGRESSION(S) DETECTED."
exit "$fail"
