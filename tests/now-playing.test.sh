#!/usr/bin/env bash
# /usr/libexec/lucciola/now-playing on a fake busctl that answers from files:
# which player status picks (the first playing, else the first paused with a
# title), what it says about it (title, artists joined, a local cover only
# when the file exists, never an http one), nothing playing, players that do
# not answer or answer junk, and the verbs (the right MPRIS method on the
# player named, or on the one status would pick; other names refused).
# Needs python3.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NP="$ROOT/lucciola/system_files/usr/libexec/lucciola/now-playing"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { local n="$1"; shift; if "$@"; then echo "ok   $n"; else echo "FAIL $n"; sed 's/^/     /' "$T/out" 2>/dev/null | tail -n 8; fails=$((fails+1)); fi; }
mkdir -p "$T/bin" "$T/fake"
export FAKE="$T/fake"
cat > "$T/bin/busctl" <<'SH'
#!/bin/sh
# busctl --user list --no-legend | --json=short get-property NAME PATH IFACE PlaybackStatus Metadata | call NAME PATH IFACE METHOD
shift  # --user
case "$1" in
  list) cat "$FAKE/list" 2>/dev/null ;;
  --json=short) [ -f "$FAKE/$3.json" ] && cat "$FAKE/$3.json" || exit 1 ;;
  call) echo "$2 $5" >> "$FAKE/calls"; [ -f "$FAKE/$2.json" ] || exit 1 ;;
esac
SH
chmod +x "$T/bin/busctl"
run() { RC=0; PATH="$T/bin:/usr/bin:/bin" python3 -I "$NP" "$@" > "$T/out" 2>&1 || RC=$?; }
js() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$T/out" "$1"; }
player() {  # player NAME STATUS TITLE ARTISTS_JSON ARTURL
  printf '{"type":"s","data":"%s"}\n{"type":"a{sv}","data":{"xesam:title":{"type":"s","data":"%s"},"xesam:artist":{"type":"as","data":%s},"mpris:artUrl":{"type":"s","data":"%s"}}}\n' "$2" "$3" "$4" "$5" > "$FAKE/org.mpris.MediaPlayer2.$1.json"
}
names() { : > "$FAKE/list"; for n in "$@"; do printf '%s  123 proc user :1.5 user@1000.service - -\n' "$n" >> "$FAKE/list"; done; }

touch "$T/cover one.jpg"
names org.mpris.MediaPlayer2.phone org.mpris.MediaPlayer2.browser org.freedesktop.Notifications
player phone Paused "due porte / due chiavi" '["Giovanni Carnazza"]' "file://$T/cover%20one.jpg"
player browser Playing "Somebody to Love" '["Queen","Friends"]' "https://example.org/cover.jpg"
run status
check "status (rc $RC)" [ "$RC" = 0 ]
check "the playing one wins over an earlier paused one" [ "$(js 'd["player"] + "|" + d["status"]')" = "org.mpris.MediaPlayer2.browser|Playing" ]
check "title, and the artists joined" [ "$(js 'd["title"] + "|" + d["artist"]')" = "Somebody to Love|Queen, Friends" ]
check "an http cover is left out" [ "$(js 'd["art"]')" = "" ]

player browser Paused "Somebody to Love" '["Queen"]' ""
run status
check "nothing playing: the first paused with a title" [ "$(js 'd["player"] + "|" + d["status"]')" = "org.mpris.MediaPlayer2.phone|Paused" ]
check "a local cover that exists is given, its path decoded" [ "$(js 'd["art"]')" = "$T/cover one.jpg" ]
player phone Paused "due porte" '["x"]' "file://$T/missing.jpg"
run status; check "a local cover that is not there is left out" [ "$(js 'd["art"]')" = "" ]

player phone Paused "" '[]' ""
player browser Stopped "Old" '["x"]' ""
run status; check "paused without a title and stopped: nothing" [ "$(js 'd')" = "{'active': False}" ]
names org.freedesktop.Notifications
run status; check "no player: nothing (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '{\"active\": false}' '$T/out'"
names org.mpris.MediaPlayer2.gone org.mpris.MediaPlayer2.junk org.mpris.MediaPlayer2.browser
echo 'not json' > "$FAKE/org.mpris.MediaPlayer2.junk.json"; echo 'still not' >> "$FAKE/org.mpris.MediaPlayer2.junk.json"
player browser Playing "Still Here" '["Queen"]' ""
run status; check "players that do not answer or answer junk are skipped" [ "$(js 'd["title"]')" = "Still Here" ]

: > "$FAKE/calls"
run toggle org.mpris.MediaPlayer2.browser; check "toggle on a named player (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx 'org.mpris.MediaPlayer2.browser PlayPause' '$FAKE/calls'"
run next;     check "next on the player status picks (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx 'org.mpris.MediaPlayer2.browser Next' '$FAKE/calls'"
run previous; check "previous (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx 'org.mpris.MediaPlayer2.browser Previous' '$FAKE/calls'"
: > "$FAKE/calls"
run toggle org.freedesktop.login1; check "a name that is not a player is refused (rc $RC)" bash -c "[ '$RC' != 0 ] && [ ! -s '$FAKE/calls' ]"
run toggle org.mpris.MediaPlayer2.gone; check "a player that is gone: failure, no crash (rc $RC)" [ "$RC" = 1 ]
run stop; check "an unknown verb is refused (rc $RC)" [ "$RC" = 2 ]
run status extra; check "status takes no argument (rc $RC)" [ "$RC" = 2 ]

echo
if [ "$fails" = 0 ]; then echo "now-playing: all checks passed"; else echo "now-playing: $fails failed"; exit 1; fi
