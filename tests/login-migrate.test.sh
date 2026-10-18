#!/usr/bin/env bash
# Tests for /usr/libexec/lucciola/login-migrate (GDM to greetd, once) on
# throwaway files: LOGIN_MIGRATE_* point it at a temp tree and the autologin
# helper is a stub that records how it was called.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/lucciola/system_files/usr/libexec/lucciola/login-migrate"
TEMPLATE="$ROOT/lucciola/system_files/usr/share/lucciola/greetd/config.toml"
T="$(mktemp -d)"; trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
fails=0

# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$*" >> "%s/autologin.calls"\n' "$T" > "$T/autologin"
chmod +x "$T/autologin"

fresh() {  # fresh <display-manager link target, or "">  <GDM AutomaticLoginEnable> <user>
  rm -rf "${T:?}/etc" "${T:?}/var" "${T:?}/autologin.calls"
  mkdir -p "$T/etc/systemd/system" "$T/etc/gdm" "$T/etc/greetd" "$T/var"
  [ -n "$1" ] && ln -s "$1" "$T/etc/systemd/system/display-manager.service"
  printf '[daemon]\nAutomaticLoginEnable=%s\nAutomaticLogin=%s\n\n[security]\n' "$2" "$3" > "$T/etc/gdm/custom.conf"
  cp "$TEMPLATE" "$T/etc/greetd/config.toml"
}
run() {
  RC=0
  OUT="$(env -i PATH=/usr/bin:/bin LOGIN_MIGRATE_MARKER="$T/var/lib/lucciola/login-migrated" \
    LOGIN_MIGRATE_DM_LINK="$T/etc/systemd/system/display-manager.service" \
    LOGIN_MIGRATE_GDM_CONF="$T/etc/gdm/custom.conf" LOGIN_MIGRATE_GREETD_CONF="$T/etc/greetd/config.toml" \
    LOGIN_MIGRATE_AUTOLOGIN="$T/autologin" bash "$HELPER" 2>&1)" || RC=$?
}
check() {
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; echo "$OUT" | sed 's/^/     /'; fails=$((fails+1)); fi
}
dm_is()      { [ "$(readlink "$T/etc/systemd/system/display-manager.service" 2>/dev/null)" = "$1" ]; }
no_dm()      { [ ! -e "$T/etc/systemd/system/display-manager.service" ] && [ ! -L "$T/etc/systemd/system/display-manager.service" ]; }
marked()     { [ -e "$T/var/lib/lucciola/login-migrated" ]; }
not_marked() { ! marked; }
called()     { [ "$(cat "$T/autologin.calls" 2>/dev/null)" = "$1" ]; }
not_called() { [ ! -e "$T/autologin.calls" ]; }
rc_is()      { [ "$RC" = "$1" ]; }

G=/usr/lib/systemd/system/greetd.service
fresh /usr/lib/systemd/system/gdm.service false ""
run; check "GDM kept by the merge: switched to greetd"            dm_is "$G"
check "GDM kept by the merge: done (marker)"                       marked
check "GDM kept by the merge: says GDM stays for this boot"       grep -q 'GDM for this one' <<<"$OUT"

fresh "$G" false "";                   run; check "greetd already: link untouched"      dm_is "$G"
check "greetd already: done (marker)"                              marked
fresh /usr/lib/systemd/system/sddm.service false ""; run; check "another display manager: left alone" dm_is /usr/lib/systemd/system/sddm.service
fresh "" false "";                     run; check "no display manager: left alone"      no_dm
check "no display manager: done (marker)"                          marked

fresh /usr/lib/systemd/system/gdm.service True alice; run
check "GDM autologin for alice: carried over"                      called "on alice"
check "GDM autologin for alice: greetd is the display manager"     dm_is "$G"
fresh "$G" true bob; run;              check "autologin (lowercase true): carried over" called "on bob"
fresh "$G" False alice; run;           check "GDM autologin off: nothing carried"       not_called
fresh "$G" True ""; run;               check "GDM autologin without a user: nothing"    not_called
fresh "$G" True alice
printf '\n[initial_session]\ncommand = "x"\nuser = "carol"\n' >> "$T/etc/greetd/config.toml"
run;                                   check "greetd has its own autologin: kept"       not_called
fresh /usr/lib/systemd/system/sddm.service True alice; run; check "another display manager: no autologin moved" not_called

fresh /usr/lib/systemd/system/gdm.service false ""
chmod a-w "$T/etc/systemd/system"
run;                                   check "link not writable: exit 1"                rc_is 1
check "link not writable: no marker (retried next boot)"           not_marked
check "link not writable: GDM stays"                               dm_is /usr/lib/systemd/system/gdm.service
chmod u+w "$T/etc/systemd/system"

echo
if (( fails )); then echo "$fails test(s) FAILED"; exit 1; fi
echo "all login-migrate tests passed"
