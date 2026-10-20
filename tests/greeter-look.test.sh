#!/usr/bin/env bash
# Tests for the login screen's look (Noctalia Greeter 1.6.0): what greeter.toml
# must hold for the greeter to use it, the patches the spec applies, and the
# path that brings the look to systems installed before it changed. The greeter takes colours, font and corners
# from greeter.toml only with a complete palette, and an installed system
# never gets a new sync.toml (copied once), so a mistake here would leave the
# login screen in the old colours without any error. See the header of
# lucciola/system_files/usr/share/lucciola/greeter/greeter.toml.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$ROOT/lucciola/system_files/usr/share/lucciola/greeter"
TMPFILES="$ROOT/lucciola/system_files/usr/lib/tmpfiles.d/lucciola-greeter.conf"
INSTALL="$ROOT/build_files/50-branding/install.sh"
WALL="$ROOT/lucciola/assets/wallpaper"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
OUT=""

check() {
  local name="$1"; shift
  if OUT="$("$@" 2>&1)"; then echo "ok   $name"; else echo "FAIL $name"; echo "$OUT" | sed 's/^/     /'; fails=$((fails+1)); fi
}

toml() {  # toml FILE PYTHON-EXPRESSION-ON-d: exits 0 when it is true
  python3 -I -c '
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
ok = eval(sys.argv[2], {"d": d})
print(ok)
sys.exit(0 if ok is True else 1)' "$1" "$2"
}

ROLES='{"primary","on_primary","secondary","on_secondary","tertiary","on_tertiary","error","on_error","surface","on_surface","surface_variant","on_surface_variant","outline","shadow","hover","on_hover"}'
A='d.get("appearance", {})'

check "greeter.toml: the palette has all 16 roles" \
  toml "$G/greeter.toml" "$ROLES <= set($A.get(\"palette\", {}))"
check "greeter.toml: every palette value is #rrggbb" \
  toml "$G/greeter.toml" "all(len(v) == 7 and v[0] == '#' and int(v[1:], 16) >= 0 for v in $A.get('palette', {}).values())"
check "greeter.toml: font, corners and theme mode next to the palette" \
  toml "$G/greeter.toml" "all(k in $A for k in ('font_family', 'corner_radius_scale', 'theme_mode'))"
check "greeter.toml: JetBrains Mono, the desktop's font" \
  toml "$G/greeter.toml" "$A.get('font_family') == 'JetBrains Mono'"
check "greeter.toml: scheme pinned to Synced (an old pick in sync.toml cannot hide the palette)" \
  toml "$G/greeter.toml" "$A.get('scheme') == 'Synced'"
check "greeter.toml: no palette picker on the login screen" \
  toml "$G/greeter.toml" "$A.get('scheme_selector_position') == 'hidden'"
check "greeter.toml: card, fields, edges and primary in the background's colour (only text shows)" \
  toml "$G/greeter.toml" "all(${A}['palette'][k] == '#121212' for k in ('surface', 'surface_variant', 'outline', 'primary'))"
check "greeter.toml: text in the site's ivory, the login arrow too" \
  toml "$G/greeter.toml" "${A}['palette']['on_surface'] == '#e6d5bf' and ${A}['palette']['on_primary'] == '#e6d5bf'"
check "greeter.toml: a plain #121212 background, no picture" \
  toml "$G/greeter.toml" "${A}['wallpaper'] == {'path': 'color:#121212', 'fill_mode': 'crop', 'fill_color': '#121212'}"
check "greeter.toml: no logo at the bottom (the firefly is the account picture)" \
  toml "$G/greeter.toml" "${A}.get('hide_logo') is True"
check "greeter.toml: the fingerprint still starts on an empty Enter" \
  toml "$G/greeter.toml" "d.get('auth', {}).get('allow_empty_password') is True"
check "greeter.toml: the fingerprint listens without an Enter (start_on_select, patch 0002)" \
  toml "$G/greeter.toml" "d.get('auth', {}).get('start_on_select') is True"
# shellcheck disable=SC2016  # $1..$4 belong to the inner bash
for p in "Patch1 0002-start-auth-on-select" "Patch2 0003-caret-in-palette-colour" \
  "Patch3 0004-quiet-bare-password-prompt" "Patch4 0005-password-follows-the-conversation"; do
  check "the spec applies ${p#* } and build-rpm.sh ships it" \
    bash -c 'grep -Eq "^$4:[[:space:]]+$3.patch$" "$1" && grep -q "$3.patch" "$2" && test -s "${1%/*}/$3.patch"' _ \
    "$ROOT/lucciola/greeter/noctalia-greeter.spec" "$ROOT/lucciola/greeter/build-rpm.sh" "${p#* }" "${p%% *}"
done

check "sync.toml seed: only the session (the look is greeter.toml's)" \
  toml "$G/sync.toml" "d == {'session': {'last': 'Lucciola'}}"

# Installed systems: greeter.toml is a link into the image (so each update
# brings it), sync.toml a copy made once (so it is not where the look goes).
check "tmpfiles: greeter.toml is a link into /usr/share (L)" \
  grep -Eq '^L[[:space:]]+/var/lib/noctalia-greeter/greeter.toml[[:space:]].*[[:space:]]/usr/share/lucciola/greeter/greeter.toml$' "$TMPFILES"
check "tmpfiles: sync.toml is copied once (C)" \
  grep -Eq '^C[[:space:]]+/var/lib/noctalia-greeter/sync.toml[[:space:]]' "$TMPFILES"

# The account picture the login screen shows comes from the image.
# shellcheck disable=SC2016  # the literal line from install.sh
check "install.sh installs the firefly as the default account picture" \
  grep -Fq 'install -Dm0644 "$A/icons/lucciola-mark-256.png" /usr/share/lucciola/avatar/lucciola.png' "$INSTALL"
check "the login wallpaper is gone (nothing names lucciola-login.png)" \
  bash -c '! grep -rqs "lucciola-login\.png" "$@"' _ "$INSTALL" "$G" "$ROOT/lucciola/assets/render.sh"

# The wallpaper SVG is what make-wallpaper.py writes today: a hand edit, or
# a script change without a new render, shows up here.
python3 -I "$WALL/make-wallpaper.py" "$T/lucciola.svg"
check "lucciola.svg matches make-wallpaper.py" cmp "$T/lucciola.svg" "$WALL/lucciola.svg"

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
