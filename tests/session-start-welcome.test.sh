#!/usr/bin/env bash
# Tests for the welcome window hook of /usr/libexec/lucciola/session-start on
# a throwaway home: noctalia (which the script execs at the end) and the
# welcome window (LUCCIOLA_WELCOME) are stubs that record how they ran.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/lucciola/system_files/usr/libexec/lucciola/session-start"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0

mkdir -p "$T/bin"
printf '#!/bin/sh\necho ran >> "%s/noctalia.calls"\n' "$T" > "$T/bin/noctalia"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$*" >> "%s/welcome.calls"\n' "$T" > "$T/welcome"
chmod +x "$T/bin/noctalia" "$T/welcome"

STATE="$T/home/.local/state/lucciola"
fresh() { rm -rf "${T:?}/home" "${T:?}/noctalia.calls" "${T:?}/welcome.calls"; mkdir -p "$T/home"; }
run() {
  RC=0
  rm -f "$T/noctalia.calls" "$T/welcome.calls"
  OUT="$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" LUCCIOLA_WELCOME="${1:-$T/welcome}" \
    sh "$SCRIPT" 2>&1)" || RC=$?
  # The window starts in the background: give it a moment to record.
  for _ in $(seq 1 20); do [ -e "$T/welcome.calls" ] && break; sleep 0.05; done
}
check() {
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; echo "$OUT" | sed 's/^/     /'; fails=$((fails+1)); fi
}
opened()     { [ "$(cat "$T/welcome.calls" 2>/dev/null)" = "--first-login" ]; }
not_opened() { [ ! -e "$T/welcome.calls" ]; }
shell_ran()  { [ "$(cat "$T/noctalia.calls" 2>/dev/null)" = ran ] && [ "$RC" = 0 ]; }
due()        { [ -e "$STATE/welcome-due" ]; }
not_due()    { [ ! -e "$STATE/welcome-due" ]; }

fresh
run
check "first session: the window opens with --first-login" opened
check "first session: marked due" due
check "first session: Noctalia still starts" shell_ran
run
check "next login, window never closed: it opens again" opened
: > "$STATE/welcome-seen"
run
check "closed once (welcome-seen): it stays closed" not_opened
check "closed once: Noctalia still starts" shell_ran

fresh
mkdir -p "$STATE"; : > "$STATE/noctalia-seeded"
run
check "account that had Lucciola sessions before: the window opens once" opened
check "account that had Lucciola sessions before: Noctalia still starts" shell_ran

fresh
mkdir -p "$STATE"; : > "$STATE/noctalia-seeded"; : > "$STATE/welcome-seen"
run
check "account that already closed the window: no window" not_opened
check "account that already closed the window: not marked due again" not_due

fresh
run "$T/missing-welcome"
check "no welcome program in the image: nothing opens" not_opened
check "no welcome program in the image: Noctalia still starts" shell_ran

[ "$fails" -eq 0 ] && echo "all session-start welcome tests passed" || { echo "$fails failed"; exit 1; }
