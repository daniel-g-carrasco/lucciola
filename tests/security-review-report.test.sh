#!/usr/bin/env bash
# .github/scripts/security-review-report.py on a throwaway register: an item
# is done when its Status says so, a decision when its Due does (the
# decisions table has no Status column: two decisions taken in October were
# listed as pending in November), an open item past its date is overdue and
# counted in the exit status, one before it is not.
# Needs python3.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$ROOT/.github/scripts/security-review-report.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { local n="$1"; shift; if "$@"; then echo "ok   $n"; else echo "FAIL $n"; sed 's/^/     /' "$T/out" 2>/dev/null | tail -n 12; fails=$((fails+1)); fi; }
says() { grep -qE -- "$1" "$T/out"; }
quiet() { ! grep -qE -- "$1" "$T/out"; }
run() { RC=0; python3 "$REPORT" --today 2026-11-10 "$T/register.md" > "$T/out" 2>&1 || RC=$?; }

cat > "$T/register.md" <<'MD'
# Register

## Claims

| ID | Promise | Defends against | Proof | Status |
|---|---|---|---|---|
| C1 | The chain is signed | tampering | a gate | verified |
| C2 | The disk is encrypted | theft | none | unverified |

## Decisions pending

| ID | Question | Options | Due |
|---|---|---|---|
| D1 | A taken decision | decided 2026-11-10: the first option | done |
| D2 | A late decision | this or that | 2026-10-31 |
| D3 | A decision with time left | this or that | 2026-11-30 |

## Engineering items

| ID | Item | Due | Status |
|---|---|---|---|
| E1 | A finished item | 2026-10-31 | done |
| E2 | A late item | 2026-11-01 | open |
| E3 | An item with time left | 2026-12-31 | open |
MD
run
check "two items past their date: exit status 2 (rc $RC)" [ "$RC" = 2 ]
check "...named at the top" says '^\*\*2 item\(s\) overdue: D2, E2\.\*\*'
check "a decision whose Due says done is not listed" quiet '\*\*D1\*\*'
check "...and the count leaves it out" says '^## Decisions pending \(2\)$'
check "an item whose Status says done is not listed" quiet '\*\*E1\*\*'
check "...and the count leaves it out" says '^## Engineering items \(2\)$'
check "a late decision is overdue since its date" says '^- \[ \] \*\*D2\*\* A late decision \*\*OVERDUE since 2026-10-31\*\*$'
check "a late item too" says '^- \[ \] \*\*E2\*\* A late item \*\*OVERDUE since 2026-11-01\*\*$'
check "one with time left shows its date" says '^- \[ \] \*\*D3\*\* A decision with time left \(due 2026-11-30\)$'
check "an unverified claim is listed every month" says '^- \[ \] \*\*C2\*\* The disk is encrypted: \*unverified\*$'
check "...a verified one is not" quiet '\*\*C1\*\*'

sed -i -e 's/| 2026-10-31 |$/| done |/' -e 's/| 2026-11-01 | open |/| 2026-11-01 | done |/' "$T/register.md"
run
check "everything late taken or done: exit status 0 (rc $RC)" [ "$RC" = 0 ]
check "...and no overdue line" quiet 'overdue'

if (( fails )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
