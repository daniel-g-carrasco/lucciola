#!/usr/bin/env bash
# Tests for /usr/bin/margine-autologin on throwaway files. No root, no greetd:
# MARGINE_AUTOLOGIN_* point the helper at temp files, `id` and `getent` are
# stubbed over a fake passwd (and `id -u` with no user says 0, so the helper
# takes itself for root and never calls sudo).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/build_files/system_files/usr/bin/margine-autologin"
TEMPLATE="$ROOT/lucciola/system_files/usr/share/lucciola/greetd/config.toml"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0

mkdir -p "$T/bin"
cat > "$T/passwd" <<'PW'
root:x:0:0:root:/root:/bin/bash
greetd:x:973:973:greetd daemon:/var/lib/greetd:/usr/sbin/nologin
alice:x:1000:1000:Alice:/var/home/alice:/bin/bash
bob:x:1001:1001:Bob:/var/home/bob:/usr/sbin/nologin
carol:x:1002:1002:Carol:/var/home/carol:/usr/bin/zsh
PW
# shellcheck disable=SC2016
cat > "$T/bin/id" <<'STUB'
#!/bin/sh
# id -u -> 0 (the helper runs "as root"); id -u NAME -> NAME's uid or failure.
[ "$1" = "-u" ] || exit 1
[ -z "$2" ] && { echo 0; exit 0; }
awk -F: -v u="$2" '$1 == u { print $3; found = 1 } END { exit !found }' "$FAKE_PASSWD"
STUB
# shellcheck disable=SC2016
cat > "$T/bin/getent" <<'STUB'
#!/bin/sh
[ "$1" = passwd ] || exit 2
if [ -n "$2" ]; then awk -F: -v u="$2" '$1 == u { print; found = 1 } END { exit !found }' "$FAKE_PASSWD"
else cat "$FAKE_PASSWD"; fi
STUB
chmod +x "$T/bin/id" "$T/bin/getent"

fresh() {  # a greetd config as the image ships it, and GDM's stock custom.conf
  cp "$TEMPLATE" "$T/config.toml"
  printf '# GDM configuration storage\n\n[daemon]\n\n[security]\n\n[debug]\n#Enable=true\n' > "$T/custom.conf"
  rm -f "$T"/*.margine.bak.*
}
run() {  # run <args...> ; sets RC and OUT. DM (default greetd.service), SUDO_USER from the caller.
  RC=0
  OUT="$(env -i PATH="$T/bin:/usr/bin:/bin" FAKE_PASSWD="$T/passwd" \
    MARGINE_AUTOLOGIN_GREETD_CONF="$T/config.toml" MARGINE_AUTOLOGIN_GDM_CONF="$T/custom.conf" \
    MARGINE_AUTOLOGIN_DM="${DM:-greetd.service}" ${SUDO_USER:+SUDO_USER="$SUDO_USER"} \
    bash "$HELPER" "$@" 2>&1)" || RC=$?
}
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; echo "$OUT" | sed 's/^/     /'; fails=$((fails+1)); fi
}
toml() {  # toml <python expression over d, the parsed greetd config>
  python3 -c 'import sys, tomllib; d = tomllib.load(open(sys.argv[1], "rb")); sys.exit(0 if eval(sys.argv[2]) else 1)' "$T/config.toml" "$1"
}
says()       { case "$OUT" in *"$1"*) return 0;; *) return 1;; esac; }
rc_is()      { [ "$RC" = "$1" ]; }
gdm_has()    { grep -qx "$1" "$T/custom.conf"; }
unchanged()  { cmp -s "$TEMPLATE" "$T/config.toml"; }
has_backup() { compgen -G "$T/config.toml.margine.bak.*" >/dev/null; }
one_section() { [ "$(grep -c '^\[initial_session\]' "$T/config.toml")" = 1 ]; }
comments_kept() { grep -q '^# Lucciola.s login screen' "$T/config.toml" && grep -q 'WLR_RENDERER_ALLOW_SOFTWARE' "$T/config.toml"; }

fresh
run status;            check "status on the shipped config: disabled"          says "autologin: disabled"
run on alice;          check "on alice: exit 0"                                  rc_is 0
check "on alice: [initial_session] user alice"                                   toml 'd["initial_session"]["user"] == "alice"'
check "on alice: the autologin launcher"                                         toml 'd["initial_session"]["command"] == "/usr/libexec/lucciola/autologin-session"'
check "on alice: the greeter stays the default session"                          toml 'd["default_session"]["user"] == "greetd" and "noctalia-greeter-session" in d["default_session"]["command"]'
check "on alice: comments kept"                                                  comments_kept
check "on alice: mirrored into GDM's custom.conf (enable)"                        gdm_has 'AutomaticLoginEnable=True'
check "on alice: mirrored into GDM's custom.conf (user)"                          gdm_has 'AutomaticLogin=alice'
check "on alice: a backup of the greetd config"                                  has_backup
check "on alice: the keyring hint"                                               says "ujust margine-keyring tpm"
run status;            check "status after on: ENABLED for alice"               says 'autologin: ENABLED for user "alice"'
run on alice;          check "on again: still one [initial_session]"            one_section
run on carol;          check "on carol: replaces alice"                          toml 'd["initial_session"]["user"] == "carol"'
check "on carol: still one [initial_session]"                                    one_section
run off;               check "off: exit 0"                                       rc_is 0
check "off: no [initial_session]"                                                toml '"initial_session" not in d'
check "off: the default session untouched"                                       toml 'd["default_session"]["user"] == "greetd"'
check "off: GDM's autologin off too"                                             gdm_has 'AutomaticLoginEnable=False'
run status;            check "status after off: disabled"                       says "autologin: disabled"
run off;               check "off again: exit 0"                                 rc_is 0

fresh
run on bob;            check "on bob (nologin shell): refused"                   rc_is 1
check "on bob: config untouched"                                                 unchanged
run on greetd;         check "on greetd (system account): refused"               says "not a normal user account"
run on root;           check "on root: refused"                                  rc_is 1
run on nosuch;         check "on a missing user: refused"                        says "does not exist"
check "refusals: config untouched"                                               unchanged
SUDO_USER=alice run on; check "on with no user: the sudo caller"                 toml 'd["initial_session"]["user"] == "alice"'

fresh
printf '[terminal]\nvt = 1\n' > "$T/config.toml"
run on alice;          check "a config without [default_session]: refused"       rc_is 1
check "a config without [default_session]: left as it was"                       grep -qx 'vt = 1' "$T/config.toml"

fresh
DM=gdm.service run on alice; check "GDM as the login screen: on edits custom.conf" gdm_has 'AutomaticLogin=alice'
check "GDM as the login screen: greetd's config untouched"                       unchanged
DM=gdm.service run status; check "GDM as the login screen: status reads GDM"      says 'ENABLED for user "alice" (login screen: GDM)'
DM=gdm.service run off; check "GDM as the login screen: off"                      gdm_has 'AutomaticLoginEnable=False'

echo
if (( fails )); then echo "$fails test(s) FAILED"; exit 1; fi
echo "all margine-autologin tests passed"
