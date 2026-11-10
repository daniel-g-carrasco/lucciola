#!/usr/bin/env bash
# .github/smoke/security-probe.sh, the two verdicts that can be tried without
# a booted VM (the probe is sourced with PROBE_FUNCTIONS_ONLY=1, so none of
# its checks run here):
# - the in-image validator is gating (register item E1): exit 0 passes and
#   says how long it took, any other exit is a FAIL named by the validator's
#   first FAIL lines without their colours, a timeout says so, and a
#   validator that is missing or crashed without a FAIL line still fails;
# - a failed unit of ours fails the gate: margine-*, lucciola-*, mok-enroll*
#   and nothing else.
# And that the probe itself calls the function with the validator's real
# exit code, under the timeout the message names.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/.github/smoke/security-probe.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { local n="$1"; shift; if "$@"; then echo "ok   $n"; else echo "FAIL $n"; sed 's/^/     /' "$T/out" 2>/dev/null | tail -n 8; fails=$((fails+1)); fi; }
says() { grep -qE -- "$1" "$T/out"; }
quiet() { ! grep -qE -- "$1" "$T/out"; }

# probe SNIPPET: the snippet runs after the probe's functions are defined;
# the last line printed is the number of FAILs the probe would count.
probe() {
  RC=0
  PROBE_FUNCTIONS_ONLY=1 PROBE_STDOUT=1 LOG="$T/validate.log" bash -c '
    set -u
    . "$1"
    eval "$2"
    echo "FAILS=$FAILS"
  ' _ "$PROBE" "$1" > "$T/out" 2>&1 || RC=$?
}

printf '\033[32m✓\033[0m kernel is ours\n\033[32m✓\033[0m PASSED\n' > "$T/validate.log"
probe 'validator_res 0 "$LOG" 41'
check "sourcing the probe runs none of its checks (rc $RC)" [ "$RC" = 0 ]
check "...not even the first" quiet 'secure-boot|mok-key'
check "validator exit 0: PASS" says '^MARGINE-SEC: validator PASS lucciola-validate-margine-system'
check "...with the time it took and its limit" says 'PASS .*\(41 s of 180\)'
check "...and the gate is not touched" says '^FAILS=0$'

printf '  \033[32m✓\033[0m kernel is ours\n  \033[31m✗\033[0m FAIL: greetd is not the display manager\n  \033[33m!\033[0m WARN: no TPM\n  \033[31m✗\033[0m FAIL: MOK key missing\n' > "$T/validate.log"
probe 'validator_res 1 "$LOG" 12'
check "validator exit 1: FAIL, no longer a WARN" says '^MARGINE-SEC: validator FAIL '
check "...naming the validator's own FAIL lines" says 'FAIL: greetd is not the display manager .*FAIL: MOK key missing'
check "...without the colour codes" quiet $'\033'
check "...and without its WARN lines" quiet 'no TPM'
check "...and the gate counts it" says '^FAILS=1$'

probe 'validator_res 124 "$LOG" 180'
check "a validator that hit its limit: FAIL, saying so" says '^MARGINE-SEC: validator FAIL lucciola-validate-margine-system did not finish in 180 s$'
check "...counted" says '^FAILS=1$'

: > "$T/validate.log"
probe 'validator_res 127 "$LOG" 0'
check "a validator that is not there: FAIL by its exit code" says '^MARGINE-SEC: validator FAIL exit code 127 and no FAIL line in its log$'
check "...counted" says '^FAILS=1$'
probe 'validator_res 2 "$LOG.absent" 0'
check "no log at all: still a FAIL, with the exit code" says '^MARGINE-SEC: validator FAIL exit code 2 and no FAIL line in its log$'

probe 'for u in margine-staleness.service lucciola-remote-login.service mok-enroll.service; do unit_is_ours "$u" && echo "ours $u"; done'
check "margine-* is ours" says '^ours margine-staleness.service$'
check "lucciola-* is ours" says '^ours lucciola-remote-login.service$'
check "mok-enroll is ours" says '^ours mok-enroll.service$'
probe 'for u in cups.service systemd-lucciola.service notlucciola-x.service ""; do unit_is_ours "$u" && echo "ours <$u>"; done; true'
check "anyone else's unit is not" quiet '^ours '

# The probe uses what was tried above, with the real exit code.
check "the probe runs the validator under the limit it names" grep -qE '^MARGINE_VALIDATE_CONTEXT=smoke-boot timeout "\$VALIDATOR_TIMEOUT" /usr/bin/lucciola-validate-margine-system > /tmp/validate.log 2>&1 \|\| vrc=\$\?$' "$PROBE"
check "...and hands its exit code to validator_res" grep -qE '^validator_res "\$vrc" /tmp/validate.log ' "$PROBE"
check "...a failed unit goes through unit_is_ours" grep -qE '^    if unit_is_ours "\$u"; then$' "$PROBE"
check "...and no validator verdict is written outside validator_res" [ "$(grep -c 'res validator ' "$PROBE")" = 3 ]

if (( fails )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
