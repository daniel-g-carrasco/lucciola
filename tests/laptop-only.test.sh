#!/usr/bin/env bash
# /usr/libexec/lucciola/laptop-only on a fake niri and fake systemd: which outputs it
# turns off, that it gives back only those, and that a failing niri stops nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LO="$ROOT/lucciola/system_files/usr/libexec/lucciola/laptop-only"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" 2>/dev/null || true; fails=$((fails + 1)); fi
}
export FAKE="$T/fake"; mkdir -p "$T/bin" "$FAKE"
cat > "$T/bin/niri" <<'SH'
#!/bin/sh
case "$*" in
  "msg --json outputs") cat "$FAKE/outputs.json" ;;
  "msg output "*) echo "$3 $4" >> "$FAKE/calls"; [ ! -e "$FAKE/refuse" ] ;;
esac
SH
cat > "$T/bin/systemctl" <<'SH'
#!/bin/sh
case "$*" in
  *is-active*) [ -e "$FAKE/active" ] ;;
  *" stop "*) rm -f "$FAKE/active"; echo stop >> "$FAKE/log" ;;
esac
SH
cat > "$T/bin/systemd-run" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE/run-args"; : > "$FAKE/active"
SH
chmod +x "$T/bin/"*
STATE="$T/state/lucciola"
run() {
  RC=0
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" XDG_STATE_HOME="$T/state" FAKE="$FAKE" \
    LAPTOP_ONLY_TEST=1 LAPTOP_ONLY_NIRI="$T/bin/niri" bash "$LO" "$@" > "$T/out" 2>&1 || RC=$?
}
calls() { cat "$FAKE/calls" 2>/dev/null | tr '\n' ';'; }
reset() { rm -rf "$T/state"; rm -f "$FAKE/calls" "$FAKE/refuse" "$FAKE/active" "$FAKE/run-args"; }

reset; echo '{"eDP-1":{"logical":{"x":0}},"DP-9":{"logical":{"x":1}},"HDMI-A-1":{"logical":{"x":2}},"DP-3":{"logical":null}}' > "$FAKE/outputs.json"
run _sweep
check "only external outputs that are on go off" [ "$(calls)" = "DP-9 off;HDMI-A-1 off;" ]
check "they are remembered" bash -c "[ \"\$(tr '\n' ' ' < '$STATE/laptop-only-off-test')\" = 'DP-9 HDMI-A-1 ' ]"
run _sweep
check "remembered once, even if seen again" [ "$(/usr/bin/grep -c 'DP-9' "$STATE/laptop-only-off-test")" = 1 ]
rm -f "$FAKE/calls"; run _restore
check "the restore turns on just those" [ "$(calls)" = "DP-9 on;HDMI-A-1 on;" ]
check "and forgets them" [ ! -e "$STATE/laptop-only-off-test" ]

reset; echo '{"eDP-1":{"logical":{"x":0}}}' > "$FAKE/outputs.json"; run _sweep
check "the laptop alone: nothing to do" [ -z "$(calls)" ]
for internal in LVDS-1 DSI-1; do
  reset; echo "{\"$internal\":{\"logical\":{\"x\":0}}}" > "$FAKE/outputs.json"; run _sweep
  check "$internal counts as the laptop's own" [ -z "$(calls)" ]
done

reset; echo '{"DP-9":{"logical":{"x":1}}}' > "$FAKE/outputs.json"; : > "$FAKE/refuse"; run _sweep
check "niri refuses: said, no failure, not remembered (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -q 'could not be turned off' '$T/out' && [ ! -e '$STATE/laptop-only-off-test' ]"
rm -f "$FAKE/refuse"; echo 'not json' > "$FAKE/outputs.json"; run _sweep
check "niri not answering: no failure (rc $RC)" [ "$RC" = 0 ]

reset; run on "+1 hour"
check "on starts the watcher with the restore on stop (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -q '_watch' '$FAKE/run-args' && grep -q 'ExecStopPost=.*_restore' '$FAKE/run-args'"
run status; check "status: on until" grep -q '^on until' "$T/out"
run status --json; check "status json" grep -q '"active":true' "$T/out"
run off; check "off stops the unit" bash -c "[ ! -e '$FAKE/active' ] && grep -q stop '$FAKE/log'"
run status; check "status: off" grep -qx off "$T/out"
run on "2001-01-01 00:00"; check "an end in the past is refused" [ "$RC" = 2 ]
reset; run toggle; check "toggle: on" [ -e "$FAKE/active" ]
run toggle; check "toggle: off" [ ! -e "$FAKE/active" ]
run nonsense; check "a wrong command: usage, rc 2" [ "$RC" = 2 ]

if (( fails )); then echo "$fails laptop-only case(s) failed"; exit 1; fi
echo "all laptop-only cases passed"
