#!/usr/bin/env bash
# Tests for /usr/libexec/margine/flatpak-repo-repair (when
# flatpak-preinstall.service relabels and repairs the system installation)
# on throwaway directories: FLATPAK_REPAIR_DIR, STATE_DIRECTORY and
# FLATPAK_REPAIR_BOOT_MARK point it at a temp tree, and fake restorecon and
# flatpak record what would have run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/build_files/system_files/usr/libexec/margine/flatpak-repo-repair"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0

mkdir -p "$T/bin"
# restorecon -n -v prints a "Would relabel" line per wrong path; the fake
# does so for the paths listed in $T/mislabeled.
cat > "$T/bin/restorecon" <<EOF
#!/bin/bash
echo "restorecon \$*" >> "$T/calls"
if [ "\$1" = "-n" ]; then
  shift 2
  for p in "\$@"; do grep -qxF "\$p" "$T/mislabeled" 2>/dev/null && echo "Would relabel \$p from a to b"; done
fi
exit 0
EOF
printf '#!/bin/bash\necho "flatpak $*" >> "%s/calls"\nexit 0\n' "$T" > "$T/bin/flatpak"
chmod +x "$T/bin/restorecon" "$T/bin/flatpak"

FP="$T/flatpak"; STATE="$T/state"; MARK="$T/run/ran"
healthy() {
  rm -rf "$FP" "$T/mislabeled"
  mkdir -p "$FP/repo/objects" "$FP/repo/refs/heads" "$FP/repo/refs/remotes" "$FP/repo/tmp" "$T/run"
}
new_boot() { rm -f "$MARK"; }
run() {
  RC=0; : > "$T/calls"
  OUT="$(env -i PATH="$T/bin:/usr/bin:/bin" FLATPAK_REPAIR_DIR="$FP" STATE_DIRECTORY="$STATE" \
    FLATPAK_REPAIR_BOOT_MARK="$MARK" bash "$HELPER" "$@" 2>&1)" || RC=$?
}
check() {
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; echo "$OUT" | sed 's/^/     /'; sed 's/^/     call: /' "$T/calls"; fails=$((fails+1)); fi
}
repaired()     { grep -qx "restorecon -RF $FP" "$T/calls" && grep -qx "flatpak repair --system" "$T/calls"; }
not_repaired() { ! grep -q -e "-RF" -e "repair" "$T/calls"; }
passed_mark()  { [ -s "$STATE/passed" ]; }
no_passed()    { [ ! -e "$STATE/passed" ]; }
rc0()          { [ "$RC" = 0 ]; }
says()         { grep -q "$1" <<<"$OUT"; }

# First boot of an install (or the first boot after this change): no mark.
healthy; new_boot; run
check "first run: relabel and repair"                         repaired
check "first run: exits 0"                                    rc0
check "first run: says why"                                   says "did not pass (or this is the first one)"
run --passed
check "--passed writes the mark"                              passed_mark

# A settled boot: the last run passed, the repo looks sound.
new_boot; run
check "settled boot: no relabel, no repair"                   not_repaired
check "settled boot: the mark is consumed until this run passes" no_passed
check "settled boot: the cheap label check still ran"         grep -q "^restorecon -n -v $FP" "$T/calls"
run --passed

# The preinstall fails (Flathub down): the mark is not written back, the
# unit restarts, the retry repairs; the next retries in the same boot do not.
new_boot; run
check "boot with a failing preinstall: first attempt cheap"   not_repaired
run
check "the restart after the failure repairs"                 repaired
run
check "a third attempt in the same boot does not repair again" not_repaired
check "and says so"                                           says "already ran in this boot"
new_boot; run
check "next boot, still not passed: repairs once more"        repaired
run --passed

# Broken repo despite a passed mark: repaired at once.
for d in refs/remotes objects tmp refs/heads; do
  healthy; new_boot; run --passed; rm -rf "${FP:?}/repo/$d"; run
  check "repo/$d missing: repaired although the last run passed" repaired
done

healthy; new_boot; run --passed; echo "$FP/repo/objects" > "$T/mislabeled"; run
check "wrong SELinux type on repo/objects: repaired"          repaired
check "and says why"                                          says "SELinux labels differ"
healthy; new_boot; run --passed; echo "$FP/repo/objects" > "$T/mislabeled"; : > "$MARK"; run
check "broken but already repaired this boot: not again"      not_repaired

# No repo yet (remote-add failed offline on a lost bake): nothing to check,
# no mark, so the repair runs; restorecon and flatpak cope with what exists.
rm -rf "$FP" "$STATE" "$T/mislabeled"; mkdir -p "$FP"; new_boot; run
check "no repo, no mark: repair attempted, exits 0"           bash -c '[ "$1" = 0 ]' _ "$RC"
repaired || { echo "FAIL no repo: repair not attempted"; fails=$((fails+1)); }

# A failing restorecon or repair is reported, never fatal (the '-' in the
# unit would hide it anyway).
healthy; new_boot; printf '#!/bin/bash\necho "flatpak $*" >> "%s/calls"\nexit 3\n' "$T" > "$T/bin/flatpak"; run
check "flatpak repair failing: exit 0, reported"              bash -c '[ "$1" = 0 ] && grep -q "flatpak repair exited 3" <<<"$2"' _ "$RC" "$OUT"

echo
if [ "$fails" -eq 0 ]; then echo "all flatpak-repo-repair tests passed"; else echo "$fails failure(s)"; exit 1; fi
