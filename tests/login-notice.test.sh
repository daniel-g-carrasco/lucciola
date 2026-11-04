#!/usr/bin/env bash
# margine-notify and margine-upgrade-notify on a fake gdbus that refuses Notify
# as the bus does while nothing owns the name ("not activatable"). What must
# hold: a notice sent as the session starts waits for the daemon and arrives; a
# notice that cannot be delivered fails, keeps the state and is retried at the
# next login (2026-11-04: it was lost at every login, with the unit succeeding).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MN="$ROOT/build_files/system_files/usr/libexec/margine/margine-notify"
UN="$ROOT/build_files/system_files/usr/libexec/margine-upgrade-notify"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" 2>/dev/null || true; fails=$((fails + 1)); fi
}
export FAKE="$T/fake"; mkdir -p "$T/bin" "$FAKE" "$T/state"
cat > "$T/bin/gdbus" <<'SH'
#!/bin/sh
case "$*" in
  *NameHasOwner*)
    n="$(cat "$FAKE/up-after")"
    if [ "$n" -le 0 ]; then echo '(true,)'; else echo "$((n - 1))" > "$FAKE/up-after"; echo '(false,)'; fi ;;
  *Notify*)
    [ "$(cat "$FAKE/up-after")" -le 0 ] || { echo "Error: GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable" >&2; exit 1; }
    printf '%s\n' "$*" >> "$FAKE/notify.log"; echo '(uint32 1,)' ;;
esac
SH
printf '#!/bin/sh\nexit 1\n' > "$T/bin/bootc"
printf '#!/bin/sh\ncat "$FAKE/status.json"\n' > "$T/bin/rpm-ostree"
chmod +x "$T/bin/"*
notices() { [ -e "$FAKE/notify.log" ] && wc -l < "$FAKE/notify.log" | tr -d ' ' || echo 0; }
clean() { rm -f "$FAKE/notify.log"; echo "$1" > "$FAKE/up-after"; }
envs=(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" XDG_STATE_HOME="$T/state" FAKE="$FAKE")

# --- margine-notify on its own
send() { RC=0; "${envs[@]}" MARGINE_NOTIFY_WAIT="$1" bash "$MN" "Title" "Body" > "$T/out" 2>&1 || RC=$?; }
clean 0; send 10
check "daemon up: rc 0" [ "$RC" = 0 ]
check "daemon up: one notice" [ "$(notices)" = 1 ]
clean 2; send 10
check "daemon up after two seconds: it waits, rc 0" [ "$RC" = 0 ]
check "daemon up after two seconds: delivered" [ "$(notices)" = 1 ]
clean 100; send 1
check "no daemon: non-zero" [ "$RC" != 0 ]
check "no daemon: nothing delivered" [ "$(notices)" = 0 ]
check "no daemon: the bus's own reason is shown" grep -q 'not activatable' "$T/out"

# --- margine-upgrade-notify, with the real margine-notify behind it
sed "s|/usr/libexec/margine/margine-notify|$MN|" "$UN" > "$T/upgrade-notify.py"
STATE="$T/state/margine/last-booted-digest"
status() { printf '{"deployments": [{"staged": true, "version": "lucciola.20261199"}, {"booted": true, "version": "%s", "base-commit-meta": {"ostree.manifest-digest": "%s"}}]}' "$1" "$2" > "$FAKE/status.json"; }
login() { RC=0; "${envs[@]}" MARGINE_NOTIFY_WAIT="$1" python3 "$T/upgrade-notify.py" > "$T/out" 2>&1 || RC=$?; }

clean 0; status lucciola.20261105 sha256:one; login 10
check "first login ever: no notice" [ "$(notices)" = 0 ]
check "first login ever: state written" [ "$(cat "$STATE")" = sha256:one ]
clean 0; login 10
check "same image: no notice" [ "$(notices)" = 0 ]

clean 2; status lucciola.20261106 sha256:two; login 10
check "new image, daemon still starting: rc 0" [ "$RC" = 0 ]
check "new image, daemon still starting: one notice" [ "$(notices)" = 1 ]
check "the notice names the booted version, not the staged one" grep -q 'Update applied lucciola.20261106 is now running' "$FAKE/notify.log"
check "the state moves on" [ "$(cat "$STATE")" = sha256:two ]

clean 100; status lucciola.20261107 sha256:three; login 1
check "no daemon at all: the unit fails" [ "$RC" = 1 ]
check "no daemon at all: it says so" grep -q 'not delivered' "$T/out"
check "no daemon at all: the state stays, to retry" [ "$(cat "$STATE")" = sha256:two ]
clean 0; login 10
check "next login: the notice arrives" [ "$(notices)" = 1 ]
check "next login: the state moves on" [ "$(cat "$STATE")" = sha256:three ]

if (( fails )); then echo "$fails login-notice case(s) failed"; exit 1; fi
echo "all login-notice cases passed"
