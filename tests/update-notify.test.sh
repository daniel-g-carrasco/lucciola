#!/usr/bin/env bash
# /usr/libexec/margine/staged-update-notify on fakes: rpm-ostree and
# update-state answer from files, margine-notify records what it is asked
# (and can refuse, as with no notification daemon around). Covered: the
# first sight of a staged update (once), the stamp written only after a
# notification went through, nothing on a locked screen or without a session,
# the stamp cleared once nothing is staged, a failed automatic run (once per
# run, again when the run time changes), nothing when all is well. Needs jq.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SN="$ROOT/build_files/system_files/usr/libexec/margine/staged-update-notify"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { local n="$1"; shift; if "$@"; then echo "ok   $n"; else echo "FAIL $n"; { sed 's/^/     /' "$T/out"; sed 's/^/     notify: /' "$T/notify.log"; } 2>/dev/null | tail -n 12; fails=$((fails+1)); fi; }
mkdir -p "$T/bin" "$T/libexec/margine" "$T/libexec/lucciola" "$T/state"
cat > "$T/bin/rpm-ostree" <<'SH'
#!/bin/sh
cat "$FAKE/status.json"
SH
cat > "$T/bin/loginctl" <<'SH'
#!/bin/sh
case "$1" in
  show-user) cat "$FAKE/display" ;;
  show-session) cat "$FAKE/locked" ;;
esac
SH
cat > "$T/libexec/lucciola/update-state" <<'SH'
#!/bin/sh
cat "$FAKE/state.json"
SH
cat > "$T/libexec/margine/margine-notify" <<'SH'
#!/bin/sh
[ -e "$FAKE/notify-refuses" ] && exit 1
printf '%s\n' "$*" >> "$NOTIFY_LOG"
SH
chmod +x "$T/bin/"* "$T/libexec/margine/"* "$T/libexec/lucciola/"*
# The script names its helpers by absolute path: run a copy with those paths
# pointed at the fakes.
sed -e "s|/usr/libexec/margine/margine-notify|$T/libexec/margine/margine-notify|" \
    -e "s|/usr/libexec/lucciola/update-state|$T/libexec/lucciola/update-state|" \
    -e "s|/var/lib/margine/update-watchdog/blocked|$T/blocked|" "$SN" > "$T/notify.sh"
export FAKE="$T/fake"; mkdir -p "$FAKE"
echo 2 > "$FAKE/display"; echo no > "$FAKE/locked"
run() { : > "$T/notify.log"; RC=0; env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" XDG_STATE_HOME="$T/state" FAKE="$FAKE" NOTIFY_LOG="$T/notify.log" bash "$T/notify.sh" > "$T/out" 2>&1 || RC=$?; }
notices() { wc -l < "$T/notify.log" | tr -d ' '; }
STAMPS="$T/state/margine"

# All well: booted, nothing staged, nothing failed.
cat > "$FAKE/status.json" <<'J'
{"deployments": [{"booted": true, "version": "candidate.20261024", "checksum": "be94", "timestamp": 1793000000}]}
J
echo '{"booted": "candidate.20261024", "staged": null, "transaction": "", "failed": 0, "channels": [{"key":"system","title":"System","outcome":"ok","unit":"uupd.service","last":1793525929,"line":"Last run today"}]}' > "$FAKE/state.json"
run; check "all well: runs, says nothing (rc $RC)" bash -c "[ $RC = 0 ] && [ $(notices) = 0 ]"

# A staged update appears: one notice, then silence; the stamp holds its checksum.
# Built now: an older staged image also gets the "staged for N days" notice.
cat > "$FAKE/status.json" <<J
{"deployments": [
  {"staged": true, "version": "candidate.20261101", "checksum": "80bb", "timestamp": $(date +%s)},
  {"booted": true, "version": "candidate.20261024", "checksum": "be94", "timestamp": 1793000000}]}
J
: > "$FAKE/notify-refuses"
run; check "no notification daemon: no notice, no stamp" bash -c "[ $(notices) = 0 ] && [ ! -e '$STAMPS/staged-seen' ]"
rm "$FAKE/notify-refuses"
echo yes > "$FAKE/locked"
run; check "screen locked: no notice, no stamp, the unlock will say it" bash -c "[ $(notices) = 0 ] && [ ! -e '$STAMPS/staged-seen' ]"
echo no > "$FAKE/locked"; : > "$FAKE/display"
run; check "no graphical session: no notice, no stamp" bash -c "[ $(notices) = 0 ] && [ ! -e '$STAMPS/staged-seen' ]"
echo 2 > "$FAKE/display"
run; check "staged: one 'Update ready' notice" bash -c "[ $(notices) = 1 ] && grep -q 'Update ready' '$T/notify.log' && grep -q 'candidate.20261101' '$T/notify.log'"
check "stamp holds the staged checksum" [ "$(cat "$STAMPS/staged-seen")" = "80bb" ]
run; check "staged again: silence" [ "$(notices)" = 0 ]

# The restart happened: margine-upgrade-notify says it at login, not this script.
cat > "$FAKE/status.json" <<'J'
{"deployments": [
  {"booted": true, "version": "candidate.20261101", "checksum": "80bb", "timestamp": 1793517242},
  {"version": "candidate.20261024", "checksum": "be94"}]}
J
run; check "after the restart: no notice from here" [ "$(notices)" = 0 ]
check "stamp cleared" [ ! -e "$STAMPS/staged-seen" ]

# A failed automatic run: once per run; a later run that fails again is told again.
echo '{"booted": "candidate.20261101", "staged": null, "transaction": "", "failed": 1, "channels": [
  {"key":"system","title":"System","outcome":"failed","unit":"uupd.service","user":false,"last":1793528427,"line":"Failed today at 11:20: Distroboxes for User: daniel: Error: could not start entrypoint. Next try tomorrow at 04:12"},
  {"key":"tools","title":"Command-Line Tools","outcome":"hung","unit":"margine-brew-upgrade.service","user":true,"last":1793531800,"line":"Hung and was stopped today at 12:16"}]}' > "$FAKE/state.json"
run; check "two failed channels: two notices with the reason" bash -c "[ $(notices) = 2 ] && grep -q 'Automatic update failed: System' '$T/notify.log' && grep -q 'could not start entrypoint' '$T/notify.log' && grep -q 'Automatic update failed: Command-Line Tools' '$T/notify.log'"
check "stamps hold the run times" bash -c "[ \"\$(cat '$STAMPS/update-failed-uupd.service')\" = 1793528427 ] && [ \"\$(cat '$STAMPS/update-failed-margine-brew-upgrade.service')\" = 1793531800 ]"
run; check "same runs: silence" [ "$(notices)" = 0 ]
sed -i 's/"last":1793528427/"last":1793614827/' "$FAKE/state.json"
run; check "a newer failed run of uupd: one more notice" bash -c "[ $(notices) = 1 ] && grep -q 'System' '$T/notify.log'"
: > "$FAKE/notify-refuses"; sed -i 's/"last":1793614827/"last":1793701227/' "$FAKE/state.json"
run; check "notice refused: the stamp keeps the old run, it is retried next tick" [ "$(cat "$STAMPS/update-failed-uupd.service")" = 1793614827 ]
rm "$FAKE/notify-refuses"
rm "$T/libexec/lucciola/update-state"
run; check "without update-state: runs, no failure notices (rc $RC)" bash -c "[ $RC = 0 ] && [ $(notices) = 0 ]"

echo; [ "$fails" = 0 ] && echo "update-notify: all checks passed" || { echo "update-notify: $fails failed"; exit 1; }
