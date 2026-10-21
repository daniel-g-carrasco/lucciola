#!/usr/bin/env bash
# The mutation checker itself (.github/scripts/mutation-check.py), on a
# throwaway repository with a tiny guard and its test: a mutant the test
# catches is killed, one it does not catch survives and fails the run, a
# mutant whose anchor is gone or whose check is red before the mutation is
# broken (never counted as killed), --check applies without running, the
# check runs with the system PATH first, and the copy leaves the real tree
# alone. Also: every mutant in tests/mutants applies to this tree.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/.github/scripts/mutation-check.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out"; fails=$((fails+1)); fi
}

# --- a repository with one guard (refuses "evil") and a test for it --------
R="$T/repo"; mkdir -p "$R/bin" "$R/tests" "$R/mutants"
cat > "$R/bin/guard" <<'SH'
#!/usr/bin/env bash
[ "$1" != evil ] || { echo "refused"; exit 1; }
echo "accepted $1"
SH
cat > "$R/tests/guard.test.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
bash "$here/bin/guard" good >/dev/null
# (not `! cmd`: errexit ignores a negated command, and the test would pass)
if bash "$here/bin/guard" evil >/dev/null; then echo "evil accepted"; exit 1; fi
echo "guard ok"
SH
printf 'exit 1\n' > "$R/tests/always-red.sh"
chmod +x "$R/bin/guard" "$R/tests/"*.sh
git -C "$R" init -q
git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false add -A
git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm init
# The checker finds the tree from its own location: a copy of it in the
# fixture repository's .github/scripts, as in the real tree.
mkdir -p "$R/.github/scripts"; cp "$CHECKER" "$R/.github/scripts/mutation-check.py"
git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false add -A
git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm checker
mut() {  # mut <file> <toml body>
  printf '%s\n' "$2" > "$R/mutants/$1.toml"
}
mut killed      'name = "killed"
file = "bin/guard"
old = '"'"'[ "$1" != evil ]'"'"'
new = '"'"'true'"'"'
must_fail = "bash tests/guard.test.sh"'
mut survived    'name = "survived"
file = "bin/guard"
old = '"'"'echo "accepted $1"'"'"'
new = '"'"'echo "accepted"'"'"'
must_fail = "bash tests/guard.test.sh"'
mut gone        'name = "gone"
file = "bin/guard"
old = '"'"'this text is not in the file'"'"'
new = '"'"'x'"'"'
must_fail = "bash tests/guard.test.sh"'
mut red-before  'name = "red-before"
file = "bin/guard"
old = '"'"'[ "$1" != evil ]'"'"'
new = '"'"'true'"'"'
must_fail = "bash tests/always-red.sh"'
mut untracked   'name = "untracked"
file = "bin/not-tracked"
old = '"'"'a'"'"'
new = '"'"'b'"'"'
must_fail = "bash tests/guard.test.sh"'
mut tagged      'name = "tagged"
file = "bin/guard"
old = '"'"'[ "$1" != evil ]'"'"'
new = '"'"'true'"'"'
must_fail = "bash tests/guard.test.sh"
tags = ["fedora"]'
printf 'name = "bad"\nfile = "bin/guard"\n' > "$R/mutants/incomplete.toml"

run() {  # run <args...> ; sets RC, output in $T/out
  RC=0
  (cd "$R" && env -i PATH=/usr/bin:/bin HOME="$HOME" python3 .github/scripts/mutation-check.py "$@") > "$T/out" 2>&1 || RC=$?
}
verdict() { grep -qE "^$1 +$2 " "$T/out"; }

run "$R/mutants/killed.toml"
check "a caught mutant is killed, exit 0 (rc $RC)"           [ "$RC" = 0 ]
check "...and reported as killed"                             verdict killed killed
run "$R/mutants/survived.toml"
check "an uncaught mutant survives, exit 1 (rc $RC)"         [ "$RC" = 1 ]
check "...and reported as survived"                           verdict survived survived
check "...with an ::error:: naming it"                        grep -q '::error::mutant survived survived' "$T/out"
run "$R/mutants/gone.toml"
check "an anchor not in the file: broken, exit 1 (rc $RC)"   [ "$RC" = 1 ]
check "...reported as broken, not killed"                     verdict gone broken
run "$R/mutants/red-before.toml"
check "a check that is red before the mutation: broken (rc $RC)" [ "$RC" = 1 ]
check "...never counted as killed"                            verdict red-before broken
run "$R/mutants/untracked.toml"
check "a file git does not track: broken (rc $RC)"           [ "$RC" = 1 ]
run "$R/mutants/incomplete.toml"
check "a mutant missing keys: broken (rc $RC)"               [ "$RC" = 1 ]
run --check "$R/mutants/killed.toml" "$R/mutants/survived.toml" "$R/mutants/gone.toml"
check "--check: exit 1 when one does not apply (rc $RC)"     [ "$RC" = 1 ]
check "--check: the others apply without running"            bash -c "grep -qE '^killed +applies' '$T/out' && ! grep -q 'guard ok' '$T/out'"
run --check "$R/mutants/killed.toml" "$R/mutants/survived.toml"
check "--check: exit 0 when all apply (rc $RC)"              [ "$RC" = 0 ]
run --exclude-tag fedora "$R/mutants/killed.toml" "$R/mutants/tagged.toml"
check "--exclude-tag leaves the tagged mutant out"            bash -c "verdict() { grep -qE \"^\$1 +\$2 \" '$T/out'; }; verdict killed killed && ! grep -q '^tagged' '$T/out'"
run --tag fedora "$R/mutants/killed.toml" "$R/mutants/tagged.toml"
check "--tag runs the tagged mutant only"                     bash -c "grep -qE '^tagged +killed' '$T/out' && ! grep -qE '^killed +killed' '$T/out'"
run --only survived "$R/mutants/killed.toml" "$R/mutants/survived.toml"
check "--only selects by name"                                bash -c "grep -qE '^survived +survived' '$T/out' && ! grep -qE '^killed ' '$T/out'"
check "the real tree is untouched by the runs"                bash -c "cd '$R' && git status --porcelain | grep -v '^?? mutants/' | wc -l | grep -qx 0"

# The check runs with /usr/bin:/bin first: a python3 earlier in PATH (a
# virtualenv's) must not be the one the check sees.
mkdir -p "$T/venv"; printf '#!/bin/sh\necho VENV-PYTHON; exit 7\n' > "$T/venv/python3"; chmod +x "$T/venv/python3"
mut path-order 'name = "path-order"
file = "bin/guard"
old = '"'"'[ "$1" != evil ]'"'"'
new = '"'"'true'"'"'
must_fail = "python3 -c \"import sys; sys.exit(0)\" && bash tests/guard.test.sh"'
RC=0
(cd "$R" && env -i PATH="$T/venv:/usr/bin:/bin" HOME="$HOME" /usr/bin/python3 .github/scripts/mutation-check.py "$R/mutants/path-order.toml") > "$T/out" 2>&1 || RC=$?
check "the check sees the system python3, not the one first in PATH (rc $RC)" bash -c "[ '$RC' = 0 ] && ! grep -q VENV-PYTHON '$T/out'"

# --- the real mutants apply to this tree --------------------------------------
RC=0; (cd "$ROOT" && env PATH="/usr/bin:/bin:$PATH" python3 "$CHECKER" --check) > "$T/out" 2>&1 || RC=$?
check "every mutant in tests/mutants applies to the tree (rc $RC)" [ "$RC" = 0 ]

if (( fails )); then echo "$fails mutation-check case(s) failed"; exit 1; fi
echo "all mutation-check cases passed"
