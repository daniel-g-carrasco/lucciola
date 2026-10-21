#!/usr/bin/env bash
# The strict-mode lint (.github/scripts/check-strict-mode.py) on fixtures:
# which forms count as strict (one line, two lines, long options, the
# `set ${X:+-x} -eou pipefail` form, a source of 00-common.sh), which do not
# (-u alone, nothing, strict mode after the first 30 lines), what is not a
# shell script (python, a symlink), and the allowlist's own rules (a
# reason, an existing file, a script that is still not strict).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/.github/scripts/check-strict-mode.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out"; fails=$((fails+1)); fi
}
W="$T/w"; mkdir -p "$W/build_files/x" "$W/tests" "$W/lucciola"
script() {  # script <path> <lines...>
  { echo '#!/usr/bin/env bash'; printf '%s\n' "${@:2}"; } > "$W/$1"
}
script build_files/x/one.sh 'set -euo pipefail' 'echo one'
script build_files/x/two.sh '# comment' 'set -eu' '' 'set -o pipefail' 'echo two'
script build_files/x/long.sh 'set -o errexit' 'set -o nounset -o pipefail' 'echo long'
script build_files/x/phone.sh 'set ${SET_X:+-x} -eou pipefail' 'echo phone'
script build_files/x/install.sh '. /ctx/00-common.sh' 'echo installs'
script build_files/00-common.sh 'set -euo pipefail' 'log() { echo "$*"; }'
script build_files/x/u-only.sh 'set -u' 'echo u'
script build_files/x/none.sh 'echo nothing'
{ echo '#!/bin/sh'; for i in $(seq 1 31); do echo "echo line $i"; done; echo 'set -eu'; echo 'set -o pipefail'; } > "$W/build_files/x/late.sh"
script build_files/x/sh-dash.sh 'set -eu' 'set -o pipefail' 'echo sh'
sed -i '1s|.*|#!/bin/sh|' "$W/build_files/x/sh-dash.sh"
printf '#!/usr/bin/env python3\nprint("not shell")\n' > "$W/build_files/x/tool.py"
printf 'no shebang\nset -u\n' > "$W/build_files/x/data.txt"
ln -s one.sh "$W/build_files/x/link.sh"
git -C "$W" init -q && git -C "$W" add -A && git -C "$W" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm fixtures
cp "$CHECK" "$W/check.py"
allow() { printf '%s\n' "$@" > "$W/allow.txt"; }
run() {  # run <args...>; sets RC, output in $T/out
  RC=0; (cd "$W" && env -i PATH=/usr/bin:/bin python3 -I check.py --root "$W" --allowlist "$W/allow.txt" "$@") > "$T/out" 2>&1 || RC=$?
}
says() { grep -q -- "$1" "$T/out"; }
flagged() { grep -q "^::error::$1:" "$T/out"; }
not_flagged() { ! flagged "$1"; }

allow "# empty"
run
check "the tree with an empty allowlist: fails (rc $RC)"                 [ "$RC" = 1 ]
for f in one.sh two.sh long.sh phone.sh install.sh sh-dash.sh; do
  check "$f is strict"                                                    not_flagged "build_files/x/$f"
done
check "00-common.sh itself is checked and strict"                          not_flagged "build_files/00-common.sh"
check "-u alone is flagged"                                               flagged "build_files/x/u-only.sh"
check "...naming what is missing"                                          says "u-only.sh: no strict mode.*missing: -e, -o pipefail"
check "no set at all is flagged"                                           flagged "build_files/x/none.sh"
check "strict mode after the first 30 lines is flagged"                   flagged "build_files/x/late.sh"
check "a python file is not a shell script"                                bash -c "! grep -q 'tool.py' '$T/out'"
check "a file without a shebang is not a shell script"                     bash -c "! grep -q 'data.txt' '$T/out'"
check "a symlink is skipped"                                               bash -c "! grep -q 'link.sh' '$T/out'"
check "the count is of real scripts"                                       says "strict mode: 10 shell scripts, 7 strict"

allow "build_files/x/u-only.sh  collects every check and counts the failures" \
      "build_files/x/none.sh    one exec line, nothing to be strict about" \
      "build_files/x/late.sh    the strict mode is there, just late (an old script)"
run
check "every gap excused with a reason: passes (rc $RC)"                 [ "$RC" = 0 ]
check "...and the count says so"                                           says "3 excused with a reason"

allow "build_files/x/u-only.sh" "build_files/x/none.sh  reason here ok" "build_files/x/late.sh  reason here ok"
run
check "an entry without a reason: fails (rc $RC)"                        [ "$RC" = 1 ]
check "...saying so"                                                       says "needs a reason"
allow "build_files/x/u-only.sh  short" "build_files/x/none.sh  reason here ok" "build_files/x/late.sh  reason here ok"
run
check "a one-word reason is not a reason (rc $RC)"                       [ "$RC" = 1 ]

allow "build_files/x/u-only.sh  a reason of some words" "build_files/x/none.sh  a reason of some words" \
      "build_files/x/late.sh  a reason of some words" "build_files/x/one.sh  a reason of some words"
run
check "an entry for a strict script is stale: fails (rc $RC)"            [ "$RC" = 1 ]
check "...asking to remove it"                                             says "one.sh is strict after all: remove its entry"

allow "build_files/x/u-only.sh  a reason of some words" "build_files/x/none.sh  a reason of some words" \
      "build_files/x/late.sh  a reason of some words" "build_files/x/gone.sh  a reason of some words"
run
check "an entry for a file that is not there: fails (rc $RC)"           [ "$RC" = 1 ]
check "...asking to remove it"                                             says "gone.sh is not a tracked shell script in scope"

allow "# empty"
run build_files/x/one.sh build_files/x/two.sh
check "explicit files: only those are judged (rc $RC)"                   [ "$RC" = 0 ]

if (( fails )); then echo "$fails strict-mode case(s) failed"; exit 1; fi
echo "all strict-mode cases passed"
