#!/usr/bin/env bash
# Tests for the login screen's look (Noctalia Greeter 1.6.0): what greeter.toml
# must hold for the greeter to use it, and the path that brings it to systems
# installed before it changed. The greeter takes colours, font and corners
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
check "greeter.toml: the card and fields in the sky's blues" \
  toml "$G/greeter.toml" "${A}['palette']['surface_variant'] == '#171a2e' and ${A}['palette']['surface'] == '#0e1020'"
check "greeter.toml: the blurred wallpaper, cropped" \
  toml "$G/greeter.toml" "${A}['wallpaper'] == {'path': '/usr/share/backgrounds/lucciola/lucciola-login.png', 'fill_mode': 'crop', 'fill_color': '#121212'}"
check "greeter.toml: the fingerprint still starts on an empty Enter" \
  toml "$G/greeter.toml" "d.get('auth', {}).get('allow_empty_password') is True"

check "sync.toml seed: only the session (the look is greeter.toml's)" \
  toml "$G/sync.toml" "d == {'session': {'last': 'Lucciola'}}"

# Installed systems: greeter.toml is a link into the image (so each update
# brings it), sync.toml a copy made once (so it is not where the look goes).
check "tmpfiles: greeter.toml is a link into /usr/share (L)" \
  grep -Eq '^L[[:space:]]+/var/lib/noctalia-greeter/greeter.toml[[:space:]].*[[:space:]]/usr/share/lucciola/greeter/greeter.toml$' "$TMPFILES"
check "tmpfiles: sync.toml is copied once (C)" \
  grep -Eq '^C[[:space:]]+/var/lib/noctalia-greeter/sync.toml[[:space:]]' "$TMPFILES"

# The wallpaper greeter.toml names is the one the image installs.
# shellcheck disable=SC2016  # the literal line from install.sh
check "install.sh installs lucciola-login.png where greeter.toml looks" \
  grep -Fq 'install -m0644 "$A/wallpaper/lucciola-login.png" /usr/share/backgrounds/lucciola/lucciola-login.png' "$INSTALL"
check "lucciola-login.png is a 1920x1200 PNG" \
  python3 -I -c '
import struct, sys
b = open(sys.argv[1], "rb").read(24)
assert b[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
w, h = struct.unpack(">II", b[16:24])
assert (w, h) == (1920, 1200), (w, h)' "$WALL/lucciola-login.png"
check "lucciola-login.png stays small (under 400 KB, it ships in updates)" \
  test "$(stat -c %s "$WALL/lucciola-login.png")" -lt 409600

# Both SVGs are what make-wallpaper.py writes today: a hand edit, or a script
# change without a new render, shows up here.
python3 -I "$WALL/make-wallpaper.py" "$T/lucciola.svg" "$T/lucciola-login.svg"
check "lucciola.svg matches make-wallpaper.py" cmp "$T/lucciola.svg" "$WALL/lucciola.svg"
check "lucciola-login.svg matches make-wallpaper.py" cmp "$T/lucciola-login.svg" "$WALL/lucciola-login.svg"
check "lucciola-login.svg: blurred and darker" \
  grep -q '<feGaussianBlur stdDeviation="35"/>.*slope="0.85"' "$WALL/lucciola-login.svg"

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
