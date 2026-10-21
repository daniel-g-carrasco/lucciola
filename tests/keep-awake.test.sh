#!/usr/bin/env bash
# Tests for /usr/libexec/lucciola/keep-awake on fakes: systemd-run and
# systemctl record what they are asked, gdbus plays UPower (the lid) and the
# power profiles daemon, niri answers `msg --json outputs`, and the lock
# helper only notes that it ran. KEEP_AWAKE_TEST=1 keeps notifications and
# the bar out of it. Covered:
#   - what the inhibitor holds in each mode, the two-hour default of
#     --screen, Noctalia's caffeine only with --screen;
#   - "on" again: an earlier end in the same mode changes nothing, a later
#     one restarts the unit, the other mode restarts it with the end asked;
#   - status (text and JSON), off, toggle, tomorrow, schedule, cancel;
#   - the lid watcher (_hold): a closed lid locks the session and holds
#     power-saver, an opened lid gives the profile back; a lid closed at a
#     desk (another monitor on) does nothing; a lid already closed at the
#     start; a lock that fails; no power profiles daemon; no gdbus.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KA="$ROOT/lucciola/system_files/usr/libexec/lucciola/keep-awake"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAKE="$T/fake"; STATE="$T/home/.local/state/lucciola"; ARGS="$FAKE/systemd-run.args"
mkdir -p "$T/bin" "$T/home"
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; { sed 's/^/     /' "$T/out"; sed 's/^     log: /     log: /' "$FAKE/log"; } 2>/dev/null | tail -n 14 || true; fails=$((fails+1)); fi
}

# shellcheck disable=SC2016
cat > "$T/bin/systemd-run" <<'STUB'
#!/bin/bash
# Records the command line; the unit (or its timer) counts as active from now on.
printf '%s\n' "$@" > "$FAKE/systemd-run.args"
name=""; timer=0
for a in "$@"; do case "$a" in --unit=*) name="${a#--unit=}" ;; --on-calendar=*) timer=1 ;; esac; done
if [[ "$timer" = 1 ]]; then name="$name.timer"; fi
touch "$FAKE/active-$name"
for a in "$@"; do case "$a" in --description=*) echo "${a#--description=}" > "$FAKE/desc-$name" ;; esac; done
STUB
# shellcheck disable=SC2016
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/bash
u="${!#}"
case " $* " in
  *" is-active "*) [[ -e "$FAKE/active-$u" ]] ;;
  *" stop "*) echo "stop $u" >> "$FAKE/log"; rm -f "$FAKE/active-$u" ;;
  *" show "*) cat "$FAKE/desc-$u" 2>/dev/null ;;
  *) true ;;
esac
STUB
# shellcheck disable=SC2016
cat > "$T/bin/gdbus" <<'STUB'
#!/bin/bash
# UPower's lid and the power profiles daemon, from files in $FAKE. `monitor`
# plays the lines of $FAKE/lid-events, then stays until timeout ends it.
case " $* " in
  *" monitor "*)
    while IFS= read -r ev; do
      sleep 0.3
      echo "/org/freedesktop/UPower: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.UPower', {'LidIsClosed': <$ev>}, @as [])"
    done < "$FAKE/lid-events"
    exec sleep 30 ;;
  *" LidIsClosed "*) echo "(<$(cat "$FAKE/lid")>,)" ;;
  *"Properties.Get net.hadess.PowerProfiles ActiveProfile"*)
    [[ -e "$FAKE/profile" ]] || exit 1
    echo "(<'$(cat "$FAKE/profile")'>,)" ;;
  *"Properties.Set net.hadess.PowerProfiles ActiveProfile"*)
    v="${!#}"; v="${v#<\'}"; v="${v%\'>}"
    echo "$v" > "$FAKE/profile"; echo "profile=$v" >> "$FAKE/log"; echo "()" ;;
  *) exit 1 ;;
esac
STUB
# shellcheck disable=SC2016
printf '#!/bin/sh\ncat "$FAKE/outputs.json"\n' > "$T/bin/niri"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho lock >> "$FAKE/log"\n' > "$T/bin/lock"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/lock-fail"
chmod +x "$T/bin"/*

reset() {  # lid open, profile balanced, the laptop screen alone, no events
  rm -rf "$FAKE" "$STATE"; mkdir -p "$FAKE"
  echo false > "$FAKE/lid"; echo balanced > "$FAKE/profile"
  echo '{"eDP-1":{"name":"eDP-1","logical":{"x":0,"y":0}}}' > "$FAKE/outputs.json"
  : > "$FAKE/lid-events"; : > "$FAKE/log"
}
run() {  # run <args...>: output in $T/out, RC set; LOCKCMD/GDBUSCMD override the fakes
  RC=0
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" FAKE="$FAKE" KEEP_AWAKE_TEST=1 \
      KEEP_AWAKE_GDBUS="${GDBUSCMD:-$T/bin/gdbus}" KEEP_AWAKE_NIRI="$T/bin/niri" KEEP_AWAKE_LOCK="${LOCKCMD:-$T/bin/lock}" \
      bash "$KA" "$@" > "$T/out" 2>&1 || RC=$?
}
until_file() { cat "$STATE/keep-awake-until-test"; }
mode_file() { cat "$STATE/keep-awake-mode-test" 2>/dev/null || echo none; }
actions() { grep -E '^(lock|profile=|stop )' "$FAKE/log" | tr '\n' ' '; }

reset
run status; check "off at first" grep -qx "off" "$T/out"
run status --json; check "status json: inactive, mode awake" grep -q '"active":false,"until":0,"mode":"awake"' "$T/out"

# The default mode: sleep and the lid only, the idle lock untouched.
run on; check "on (rc $RC)" [ "$RC" = 0 ]
check "awake: the inhibitor holds sleep and the lid switch only" grep -qxF -- "--what=sleep:handle-lid-switch" "$ARGS"
check "awake: Noctalia's caffeine is left alone" bash -c "! grep -q caffeine '$ARGS'"
check "awake: the unit runs the lid watcher" grep -qx "_hold" "$ARGS"
check "awake: the power profile goes back when the unit stops" grep -q "_profile restore" "$ARGS"
check "awake: the unit ends at midnight" [ "$(date -d "@$(until_file)" +%H:%M)" = 00:00 ]
check "mode recorded: awake" [ "$(mode_file)" = awake ]
run status --json; check "status json: active, awake" grep -q '"active":true,"until":[0-9]*,"mode":"awake"' "$T/out"
run status; check "status: on until ..." grep -q "^on until " "$T/out"
check "status: no screen tag in awake mode" bash -c "! grep -q 'screen on' '$T/out'"
cp "$ARGS" "$T/args1"
run on "+10 minutes"; check "on again with an earlier end: nothing changes (rc $RC)" bash -c "[ '$RC' = 0 ] && cmp -s '$ARGS' '$T/args1' && [ -z \"\$(grep '^stop ' '$FAKE/log')\" ]"
run on "tomorrow 23:59"; check "on again with a later end: the unit restarts (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -q '^stop lucciola-keep-awake-test.service' '$FAKE/log'"

# --screen: idle too, caffeine, two hours by default; a mode switch takes the end asked for.
: > "$FAKE/log"
now=$(date +%s)
run on --screen; check "on --screen (rc $RC)" [ "$RC" = 0 ]
check "screen: the inhibitor holds idle too" grep -qxF -- "--what=sleep:idle:handle-lid-switch" "$ARGS"
check "screen: caffeine on while it holds, off afterwards" bash -c "grep -q caffeine-enable '$ARGS' && grep -q caffeine-disable '$ARGS'"
check "screen: two hours by default, not the later end of the awake run" bash -c "d=\$(( $(until_file) - $now )); [ \$d -ge 7190 ] && [ \$d -le 7210 ]"
check "screen: the awake unit was stopped first" grep -q "^stop lucciola-keep-awake-test.service" "$FAKE/log"
check "mode recorded: screen" [ "$(mode_file)" = screen ]
check "screen: the description says so" grep -q "^Keep Awake (screen on) until" "$FAKE/desc-lucciola-keep-awake-test.service"
run status; check "status names the mode" grep -q "^on until .* (screen on)$" "$T/out"
run status --json; check "status json: mode screen" grep -q '"mode":"screen"' "$T/out"
run on; check "on without the flag: back to awake, until midnight (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qxF -- '--what=sleep:handle-lid-switch' '$ARGS' && [ \"\$(cat '$STATE/keep-awake-mode-test')\" = awake ] && [ \"\$(date -d @\$(cat '$STATE/keep-awake-until-test') +%H:%M)\" = 00:00 ]"
now=$(date +%s)
run on "+1 hour" --screen; check "--screen after the time works too (rc $RC)" bash -c "[ '$RC' = 0 ] && [ \"\$(cat '$STATE/keep-awake-mode-test')\" = screen ] && d=\$(( \$(cat '$STATE/keep-awake-until-test') - $now )) && [ \$d -ge 3590 ] && [ \$d -le 3610 ]"
run off; check "off (rc $RC)" bash -c "[ '$RC' = 0 ] && [ ! -e '$FAKE/active-lucciola-keep-awake-test.service' ] && [ ! -e '$STATE/keep-awake-until-test' ] && [ ! -e '$STATE/keep-awake-mode-test' ]"
run status; check "off again" grep -qx "off" "$T/out"

run tomorrow --screen; check "tomorrow --screen: screen mode until tomorrow night (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && grep -qxF -- '--what=sleep:idle:handle-lid-switch' '$ARGS' && [ \"\$(date -d @\$(cat '$STATE/keep-awake-until-test') +%F)\" = \"\$(date -d tomorrow +%F)\" ]"
run off
run toggle; check "toggle: on (rc $RC)" bash -c "[ '$RC' = 0 ] && [ -e '$FAKE/active-lucciola-keep-awake-test.service' ]"
run toggle; check "toggle: off (rc $RC)" bash -c "[ '$RC' = 0 ] && [ ! -e '$FAKE/active-lucciola-keep-awake-test.service' ]"

# Scheduled starts keep their mode.
run schedule "tomorrow 08:00" --screen; check "schedule --screen (rc $RC)" [ "$RC" = 0 ]
check "the timer starts keep-awake on --screen" bash -c "grep -q -- '^--on-calendar=' '$ARGS' && grep -qx -- '--screen' '$ARGS' && grep -qx on '$ARGS'"
check "the scheduled start is recorded with its mode" [ "$(cut -d' ' -f3 "$STATE/keep-awake-scheduled-test")" = screen ]
run status --json; check "status json: scheduled mode" grep -q '"scheduled_mode":"screen"' "$T/out"
run status; check "status: the scheduled line" grep -q "^scheduled: " "$T/out"
run cancel; check "cancel (rc $RC)" bash -c "[ '$RC' = 0 ] && [ ! -e '$STATE/keep-awake-scheduled-test' ]"
run status --json; check "nothing scheduled afterwards" grep -q '"scheduled_start":0' "$T/out"

# The lid watcher.
reset; printf 'true\nfalse\n' > "$FAKE/lid-events"
t0=$(date +%s%N); run _hold 2; t1=$(date +%s%N)
check "_hold: ends on time (rc $RC)" bash -c "[ '$RC' = 0 ] && [ $(( (t1 - t0) / 1000000 )) -ge 1900 ] && [ $(( (t1 - t0) / 1000000 )) -le 4000 ]"
check "lid closed: the session is locked, then power-saver; opened: the profile back" [ "$(actions)" = "lock profile=power-saver profile=balanced " ]
check "nothing left to restore" [ ! -e "$STATE/keep-awake-profile-test" ]

reset; echo '{"eDP-1":{"logical":null},"DP-1":{"logical":{"x":0,"y":0}}}' > "$FAKE/outputs.json"; printf 'true\n' > "$FAKE/lid-events"
run _hold 1; check "lid closed at a desk (another monitor on): no lock, no profile change (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && [ -z \"$(actions)\" ] && grep -q 'another monitor' '$T/out'"

reset; echo true > "$FAKE/lid"
run _hold 1; check "lid already closed at the start: locked at once, power-saver held (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && [ \"$(actions)\" = 'lock profile=power-saver ' ] && [ \"\$(cat '$STATE/keep-awake-profile-test')\" = balanced ]"
run _profile restore; check "the unit's stop gives the profile back (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && [ \"\$(cat '$FAKE/profile')\" = balanced ] && [ ! -e '$STATE/keep-awake-profile-test' ]"

reset; echo power-saver > "$FAKE/profile"; printf 'true\nfalse\n' > "$FAKE/lid-events"
run _hold 2; check "power-saver already chosen: left alone (rc $RC)" bash -c "[ '$RC' = 0 ] && [ \"$(actions)\" = 'lock ' ] && [ ! -e '$STATE/keep-awake-profile-test' ]"

reset; mkdir -p "$STATE"; echo balanced > "$STATE/keep-awake-profile-test"; echo performance > "$FAKE/profile"
run _profile restore; check "a profile changed by hand in between stays (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && [ \"\$(cat '$FAKE/profile')\" = performance ] && [ ! -e '$STATE/keep-awake-profile-test' ]"

reset; rm -f "$FAKE/profile"; echo true > "$FAKE/lid"
run _hold 1; check "no power profiles daemon: the lock still happens (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && [ \"$(actions)\" = 'lock ' ] && [ ! -e '$STATE/keep-awake-profile-test' ]"

reset; echo true > "$FAKE/lid"
LOCKCMD="$T/bin/lock-fail" run _hold 1; check "a lock that fails is reported and the watcher goes on (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && grep -q 'could not be locked' '$T/out'"

reset; printf 'true\n' > "$FAKE/lid-events"
t0=$(date +%s%N); GDBUSCMD=/nonexistent/gdbus run _hold 1; t1=$(date +%s%N)
check "no gdbus: the hold lasts anyway, the lid is not watched (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && [ $(( (t1 - t0) / 1000000 )) -ge 900 ] && grep -q 'not watched' '$T/out' && [ -z \"$(actions)\" ]"

[ "$fails" = 0 ] && echo "keep-awake: all checks passed" || { echo "keep-awake: $fails failed"; exit 1; }
