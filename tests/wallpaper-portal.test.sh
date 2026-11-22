#!/usr/bin/env bash
# /usr/libexec/lucciola/wallpaper-portal, the backend behind "Set as
# Background", through its `set URI` form and a fake noctalia that records
# what it is asked: a picture is copied into the user's store under a name
# made from its content and that copy is what Noctalia gets; the same
# picture twice is one file; the previous copy goes once the new one is
# set, and a wallpaper that is not ours is never removed; what is not a
# local picture is refused with nothing copied; if Noctalia refuses,
# nothing is left behind. And the image's files send the Wallpaper
# interface, and only that, to this backend in the Lucciola (Umbriel) session.
# Needs python3.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SF="$ROOT/lucciola/system_files"
WP="$SF/usr/libexec/lucciola/wallpaper-portal"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { local n="$1"; shift; if "$@"; then echo "ok   $n"; else echo "FAIL $n"; sed 's/^/     /' "$T/out" 2>/dev/null | tail -n 8; fails=$((fails+1)); fi; }
says() { grep -qE -- "$1" "$T/out"; }

mkdir -p "$T/bin" "$T/data" "$T/pics"
STORE="$T/data/lucciola/wallpapers"
cat > "$T/bin/noctalia" <<'SH'
#!/bin/sh
# noctalia msg wallpaper-get | wallpaper-set PATH
case "$2" in
  wallpaper-get) cat "$FAKE/current" 2>/dev/null ;;
  wallpaper-set) echo "$3" >> "$FAKE/calls"; [ -n "${FAKE_REFUSE:-}" ] && { echo "error: nope"; exit 1; }; printf '%s' "$3" > "$FAKE/current"; echo ok ;;
esac
SH
chmod +x "$T/bin/noctalia"
export FAKE="$T/fake"; mkdir -p "$FAKE"
run() { RC=0; env -i PATH=/usr/bin:/bin HOME="$T/home" XDG_DATA_HOME="$T/data" FAKE="$FAKE" ${REFUSE:+FAKE_REFUSE=1} \
  WALLPAPER_PORTAL_NOCTALIA="$T/bin/noctalia" python3 -I "$WP" "$@" > "$T/out" 2>&1 || RC=$?; }
stored() { find "$STORE" -type f 2>/dev/null | wc -l; }

printf 'first picture' > "$T/pics/a night.png"
printf 'second picture' > "$T/pics/b.WEBP"
run set "file://$T/pics/a%20night.png"
check "a picture given as a file:// URI is set (rc $RC)" [ "$RC" = 0 ]
first="$(cat "$FAKE/current")"
check "...Noctalia gets a copy in the user's store, not the path it was handed" bash -c "[ \"\$(dirname '$first')\" = '$STORE' ] && cmp -s '$first' '$T/pics/a night.png'"
check "...named after its content, with its extension" grep -qE '/[0-9a-f]{16}\.png$' <<<"$first"
run set "$T/pics/a night.png"
check "the same picture again, as a plain path: still one file (rc $RC)" bash -c "[ '$RC' = 0 ] && [ \"$(stored)\" = 1 ]"
run set "file://$T/pics/b.WEBP"
second="$(cat "$FAKE/current")"
check "another picture: set, extension in lower case (rc $RC)" bash -c "[ '$RC' = 0 ] && [[ '$second' == *.webp ]]"
check "...and the copy that was the wallpaper before is gone" bash -c "[ ! -e '$first' ] && [ \"$(stored)\" = 1 ]"

printf 'mine' > "$T/pics/own.jpg"; printf '%s' "$T/pics/own.jpg" > "$FAKE/current"
run set "file://$T/pics/a%20night.png"
check "a wallpaper that is not one of our copies is never removed" [ -e "$T/pics/own.jpg" ]

before="$(stored)"; : > "$FAKE/calls"
for bad in "https://example.org/x.png" "file://$T/pics/missing.png" "file://$T/pics" "file://$T/pics/notes.txt" "relative.png"; do
  printf 'x' > "$T/pics/notes.txt"
  run set "$bad"
  check "refused: $bad (rc $RC)" [ "$RC" = 1 ]
done
check "...none of them reached Noctalia or the store" bash -c "[ ! -s '$FAKE/calls' ] && [ \"$(stored)\" = '$before' ]"
: > "$T/pics/empty.png"; run set "file://$T/pics/empty.png"
check "an empty file is refused (rc $RC)" [ "$RC" = 1 ]

printf 'third picture' > "$T/pics/c.png"; kept="$(cat "$FAKE/current")"
REFUSE=1 run set "file://$T/pics/c.png"
check "Noctalia refusing: reported as a failure (rc $RC)" bash -c "[ '$RC' = 1 ] && grep -q 'did not take the wallpaper' '$T/out'"
check "...the copy just made is removed, the current wallpaper stays" bash -c "[ \"$(stored)\" = '$before' ] && [ -e '$kept' ]"
unset REFUSE

run bogus
check "anything else on the command line is refused (rc $RC)" [ "$RC" = 2 ]

# The image's wiring.
check "the Umbriel session sends Wallpaper to this backend" grep -qx 'org.freedesktop.impl.portal.Wallpaper=lucciola;' "$SF/etc/xdg-desktop-portal/umbriel-portals.conf"
check "the portal file offers Wallpaper and nothing else, under Umbriel" \
  bash -c "grep -qx 'Interfaces=org.freedesktop.impl.portal.Wallpaper' '$SF/usr/share/xdg-desktop-portal/portals/lucciola.portal' && grep -qx 'UseIn=umbriel' '$SF/usr/share/xdg-desktop-portal/portals/lucciola.portal'"
check "the bus name is the same in the portal file, the service file and the program" \
  bash -c "grep -qx 'DBusName=org.freedesktop.impl.portal.desktop.lucciola' '$SF/usr/share/xdg-desktop-portal/portals/lucciola.portal' && grep -qx 'Name=org.freedesktop.impl.portal.desktop.lucciola' '$SF/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.lucciola.service' && grep -q '^NAME = \"org.freedesktop.impl.portal.desktop.lucciola\"' '$WP'"
check "the service file starts the program the image ships, executable" \
  bash -c "grep -qx 'Exec=/usr/libexec/lucciola/wallpaper-portal' '$SF/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.lucciola.service' && [ -x '$WP' ]"

echo; [ "$fails" = 0 ] && echo "wallpaper-portal: all checks passed" || { echo "wallpaper-portal: $fails failed"; exit 1; }
