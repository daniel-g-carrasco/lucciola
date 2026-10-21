#!/usr/bin/env bash
# The claims-register lint (.github/scripts/check-claims.py) on a throwaway
# tree: a verified or partial claim must name a proof that exists (a path
# in backticks, a workflow step or job in quotes), a named path must exist,
# other statuses are left to the monthly review, image references and
# ellipses are not paths, a workflow by its file name resolves; and every
# test under tests/ must be run by lint.yml or mutation.yml, directly or
# through a test they run. PyYAML is needed (lint.yml installs it).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/.github/scripts/check-claims.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out"; fails=$((fails+1)); fi
}
fresh() {  # fresh <table rows...>
  rm -rf "$T/w"; mkdir -p "$T/w/docs" "$T/w/.github/workflows" "$T/w/tests" "$T/w/.github/scripts"
  printf '#!/usr/bin/env bash\necho ok\n' > "$T/w/tests/a.test.sh"
  printf '#!/usr/bin/env bash\nexec python3 tests/a-cases.test.py\n' > "$T/w/tests/wrapper.test.sh"
  printf 'print("ok")\n' > "$T/w/tests/a-cases.test.py"
  : > "$T/w/.github/scripts/scan.py"
  cat > "$T/w/.github/workflows/lint.yml" <<'WF'
name: Lint
on: [pull_request]
jobs:
  lint:
    runs-on: ubuntu-26.04
    steps:
      - name: Image security scanner
        run: bash tests/a.test.sh
      - name: Wrapper
        run: bash tests/wrapper.test.sh
WF
  cat > "$T/w/.github/workflows/build.yml" <<'WF'
name: Build
on: [push]
jobs:
  sign:
    name: Cosign sign (by digest)
    runs-on: ubuntu-26.04
    steps:
      - name: Sign image by digest
        run: cosign sign x
WF
  {
    echo "# Register"
    echo
    echo "## Claims"
    echo
    echo "| ID | Promise | Defends against | Proof | Status |"
    echo "|---|---|---|---|---|"
    printf '%s\n' "$@"
    echo
    echo "## Decisions pending"
    echo
    echo "| ID | Question | Options | Due |"
    echo "|---|---|---|---|"
    echo "| D1 | x | y | 2026-12-31 |"
  } > "$T/w/docs/SECURITY-CLAIMS.md"
}
run() { RC=0; env -i PATH=/usr/bin:/bin python3 "$CHECK" --root "$T/w" > "$T/out" 2>&1 || RC=$?; }
says() { grep -q -- "$1" "$T/out"; }

fresh '| C1 | a | b | scan (`tests/a.test.sh`) | verified |'; run
check "a verified claim naming a test in the tree passes (rc $RC)"          [ "$RC" = 0 ]
fresh '| C1 | a | b | the image scan, smoke `mok-key` | verified |'; run
check "a verified claim naming only words: fails (rc $RC)"                   [ "$RC" = 1 ]
check "...and says what to name"                                             says "C1 (Claims) is verified but its proof names no path"
fresh '| C1 | a | b | `tests/gone.test.sh` | verified |'; run
check "a verified claim naming a missing path: fails (rc $RC)"              [ "$RC" = 1 ]
check "...naming the path"                                                   says 'names `tests/gone.test.sh`, which is not in the tree'
fresh '| C1 | a | b | `tests/a.test.sh`, `tests/gone.test.sh` | verified |'; run
check "one good path does not excuse a dangling one (rc $RC)"               [ "$RC" = 1 ]
fresh '| C2 | a | b | measured once by hand | partial |'; run
check "a partial claim with no proof path: fails (rc $RC)"                   [ "$RC" = 1 ]
fresh '| C3 | a | b | none | unverified |' '| C4 | a | b | none yet | limitation, decision D1 |' '| C5 | a | b | `tests/coming.test.sh` | pending merge (#30) |'; run
check "unverified, limitation and pending rows are not judged (rc $RC)"     [ "$RC" = 0 ]
fresh '| C1 | a | b | build.yml step "Sign image by digest" | verified |'; run
check "a workflow step named in quotes counts (rc $RC)"                      [ "$RC" = 0 ]
fresh '| C1 | a | b | the job "Cosign sign (by digest)" | verified |'; run
check "a job named in quotes counts (rc $RC)"                                [ "$RC" = 0 ]
fresh '| C1 | a | b | step "Sign the image" | verified |'; run
check "a step name no workflow has: fails (rc $RC)"                          [ "$RC" = 1 ]
check "...naming it"                                                         says 'names the step or job "Sign the image", which no workflow has'
fresh '| C1 | a | b | `.github/scripts/scan.py`, scopes for `ghcr.io/daniel-g-carrasco/lucciola` and `.../margine` | verified |'; run
check "image references and ellipses are not paths (rc $RC)"                [ "$RC" = 0 ]
fresh '| C1 | a | b | `build.yml` | verified |'; run
check "a workflow by its file name resolves (rc $RC)"                        [ "$RC" = 0 ]
fresh '| C1 | a | b | `.github/scripts/` | verified |'; run
check "a directory in the tree counts (rc $RC)"                              [ "$RC" = 0 ]

fresh '| C1 | a | b | `tests/a.test.sh` | verified |'
printf '#!/usr/bin/env bash\necho lonely\n' > "$T/w/tests/orphan.test.sh"; run
check "a test nobody runs: fails (rc $RC)"                                   [ "$RC" = 1 ]
check "...naming it"                                                         says "tests/orphan.test.sh is run by neither lint.yml nor mutation.yml"
fresh '| C1 | a | b | `tests/a.test.sh` | verified |'
printf 'name: M\non: [push]\njobs:\n  m:\n    runs-on: x\n    steps:\n      - run: bash tests/orphan.test.sh\n' > "$T/w/.github/workflows/mutation.yml"
printf '#!/usr/bin/env bash\necho lonely\n' > "$T/w/tests/orphan.test.sh"; run
check "a test mutation.yml runs is not an orphan (rc $RC)"                   [ "$RC" = 0 ]
fresh '| C1 | a | b | `tests/a.test.sh` | verified |'; run
check "a .py run by a wired .sh wrapper is not an orphan (rc $RC)"           [ "$RC" = 0 ]

if (( fails )); then echo "$fails check-claims case(s) failed"; exit 1; fi
echo "all check-claims cases passed"
