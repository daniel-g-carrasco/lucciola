#!/usr/bin/env bash
# The gaming alignment (build_files/custom-kernel/gaming-align.sh) on a fake
# dnf: a view of the repositories that names a build no mirror holds is
# thrown away and the next round plans on fresh metadata (expat-2.8.5 after
# 2.9.0, 2026-10-21); a layer that does not resolve stops at once; four
# views of 404s give up; a plan with nothing to replace installs nothing;
# only x86_64 and noarch replacements are aligned, never the i686 chain.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# shellcheck source=build_files/00-common.sh
. "$ROOT/build_files/00-common.sh"
# shellcheck source=build_files/custom-kernel/gaming-align.sh
. "$ROOT/build_files/custom-kernel/gaming-align.sh"
export GAMING_LAYER=(steam lutris)
export GAMING_PLAN_PAUSE=0 GAMING_RETRY_PAUSE=0
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/calls" 2>/dev/null; fails=$((fails+1)); fi
}

plan() {  # plan <expat version>: what dnf prints for the layer on one view
  cat <<PLAN
Package                Arch    Version              Repository         Size
Upgrading:
 expat                 x86_64  0:$1-1.fc45          updates-testing    350.2 KiB
   replacing expat     x86_64  0:2.8.3-1.fc45       <unknown>          338.4 KiB
 tzdata                noarch  0:2026c-1.fc45       updates-testing      1.0 MiB
   replacing tzdata    noarch  0:2026b-1.fc45       <unknown>            1.0 MiB
Installing:
 openh264              x86_64  1:2.6.0-1.fc45       fedora-multimedia    1.0 MiB
   replacing noopenh264 x86_64 0:2.6.0-1.fc45       <unknown>           10.0 KiB
 steam                 i686    0:1.0.0.87-3.fc45    fedora-multimedia    4.0 MiB
 expat                 i686    0:$1-1.fc45          updates-testing    300.0 KiB
Installing dependencies:
 glibc                 i686    0:2.42-1.fc45        fedora               2.0 MiB

Transaction Summary:
 Installing:         4 packages
 Upgrading:          2 packages
PLAN
}

# The fake dnf: the view number and the scenario live in files; each call
# is logged. --assumeno prints the plan and exits 1, as dnf does.
dnf() {
  local view; view=$(cat "$T/view")
  echo "dnf $*" >> "$T/calls"
  case "$*" in
    "-y clean metadata") echo $(( view + 1 )) > "$T/view"; return 0 ;;
  esac
  if [[ " $* " == *" --assumeno "* ]]; then
    case "$(cat "$T/scenario")" in
      stale)     if (( view == 1 )); then plan 2.8.5; else plan 2.9.0; fi ;;
      always404) plan 2.8.5 ;;
      noresolve) printf 'Failed to resolve the transaction:\nProblem: nothing provides libSDL3.so.0 needed by steam\n' ;;
      nothing)   printf 'Installing:\n steam i686 0:1.0.0.87-3.fc45 fedora-multimedia 4.0 MiB\n\nTransaction Summary:\n Installing: 1 package\n' ;;
    esac
    return 1
  fi
  if [[ " $* " == *" install "* ]]; then
    if [[ " $* " == *expat-0:2.8.5* ]]; then
      echo "Librepo error: Cannot download Packages/e/expat-2.8.5-1.fc45.x86_64.rpm: All mirrors were tried"
      return 1
    fi
    echo "${*: -3}" > "$T/installed"
    return 0
  fi
}

run() {  # run <scenario>: gaming_align with no pauses, return code in $T/rc
  echo 1 > "$T/view"; echo "$1" > "$T/scenario"; : > "$T/calls"; rm -f "$T/installed"
  local rc=0
  gaming_align 4 0 > "$T/out" 2>&1 || rc=$?
  echo "$rc" > "$T/rc"
}
count() { grep -c -- "$1" "$T/calls" || true; }

expected_list="$(printf '%s\n' expat-0:2.8.5-1.fc45.x86_64 openh264-1:2.6.0-1.fc45.x86_64 tzdata-0:2026c-1.fc45.noarch)"
check "the list: x86_64 and noarch replacements, obsoletes included, never the i686 chain" \
  test "$(plan 2.8.5 | gaming_align_list)" = "$expected_list"

run stale
check "a view whose build no mirror holds is thrown away: aligned on the next view" test "$(cat "$T/rc")" = 0
check "  one metadata clean between the two views" test "$(count 'clean metadata')" = 1
check "  the stale build tried twice on its view, the fresh one once" \
  test "$(count 'install --setopt=install_weak_deps=False --enablerepo=fedora-multimedia expat-0:2.8.5')" = 2
check "  what got installed is the fresh view's builds" \
  test "$(cat "$T/installed")" = "expat-0:2.9.0-1.fc45.x86_64 openh264-1:2.6.0-1.fc45.x86_64 tzdata-0:2026c-1.fc45.noarch"
check "  never an i686 package in an install" bash -c "! grep -E ' install .*\\.i686' '$T/calls'"

run noresolve
check "a layer that does not resolve stops at once" test "$(cat "$T/rc")" = 1
check "  no install, no new view" test "$(count ' install --setopt')$(count 'clean metadata')" = 00

run always404
check "four views of 404s give up" test "$(cat "$T/rc")" = 1
check "  three new views after the first" test "$(count 'clean metadata')" = 3
check "  and it says so" grep -q "failed in 4 views of the repositories" "$T/out"

run nothing
check "a plan with nothing to replace installs nothing" test "$(cat "$T/rc")$(count ' install --setopt')" = 00

[ "$fails" = 0 ] && echo "gaming-align: all checks passed" || { echo "gaming-align: $fails check(s) failed"; exit 1; }
