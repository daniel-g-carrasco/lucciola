#!/usr/bin/env bash
# Tests for /usr/libexec/margine/devmode (ujust lucciola-devmode) on
# throwaway files. No root, no network, no rpm-ostree: MARGINE_DEVMODE_LIST,
# MARGINE_BREW_ROOT, MARGINE_BREW_INSTALLER and MARGINE_SUDO point the
# helper at temp files and a fake Homebrew installer, and rpm, rpm-ostree
# and brew are stubs. The repository steps need root, so only their refusal
# is tested here; the build's resolve check runs them for real.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/build_files/system_files/usr/libexec/margine/devmode"
LIST_SHIPPED="$ROOT/build_files/60-ujust-services/developer-packages.txt"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0

mkdir -p "$T/bin" "$T/home/.cache"
cat > "$T/list" <<'L'
# a comment
code

gcc
  # indented comment
make
L
# rpm-ostree status --json: deployments[0] from $FAKE_DEPLOY (a JSON file).
cat > "$T/bin/rpm-ostree" <<'STUB'
#!/bin/sh
[ "$1 $2" = "status --json" ] || exit 2
cat "$FAKE_DEPLOY"
STUB
# rpm -q NAME: installed when NAME is in $FAKE_INSTALLED (space separated).
cat > "$T/bin/rpm" <<'STUB'
#!/bin/sh
[ "$1" = "-q" ] || exit 2
shift
[ "$1" = "--qf" ] && { shift 2; v=1.0; } || v=
case " $FAKE_INSTALLED " in *" $1 "*) [ -n "$v" ] && printf '%s' "$v"; exit 0 ;; esac
exit 1
STUB
# A fake Homebrew installer: checks the environment the helper promises,
# counts its runs, and writes a brew stub (or not, or fails, on request).
cat > "$T/fake-install.sh" <<'FAKE'
echo run >> "$FAKE_RUNS"
[ "$NONINTERACTIVE" = 1 ] && [ "$HOMEBREW_NO_SUDO" = 1 ] || { echo "bad env"; exit 9; }
[ -w "$FAKE_PREFIX" ] || { echo "prefix not writable"; exit 8; }
[ "${FAKE_MODE:-ok}" = fail ] && exit 7
[ "${FAKE_MODE:-ok}" = nobrew ] && exit 0
mkdir -p "$FAKE_PREFIX/bin"
cat > "$FAKE_PREFIX/bin/brew" <<'BREW'
#!/bin/sh
case "$1" in
  --version) echo "Homebrew 9.9.9" ;;
  list) [ "$2" = --formula ] && printf 'hello\njq\n'; [ "$2" = --cask ] && printf 'font-x\n'; true ;;
esac
BREW
chmod +x "$FAKE_PREFIX/bin/brew"
FAKE
chmod +x "$T/bin/rpm-ostree" "$T/bin/rpm"

deploy() {  # deploy <booted:true|false> <requested names...>
  local booted="$1"; shift
  python3 -c 'import json,sys; print(json.dumps({"deployments": [{"booted": sys.argv[1] == "true", "requested-packages": sys.argv[2:]}]}))' \
    "$booted" "$@" > "$T/deploy.json"
}
run() {  # run <args...> ; sets RC and OUT
  RC=0
  OUT="$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" \
    FAKE_DEPLOY="$T/deploy.json" FAKE_INSTALLED="${INSTALLED:-}" FAKE_RUNS="$T/runs" \
    FAKE_PREFIX="$T/linuxbrew/.linuxbrew" FAKE_MODE="${MODE:-ok}" \
    MARGINE_DEVMODE_LIST="${LIST:-$T/list}" MARGINE_BREW_ROOT="${BREWROOT:-$T/linuxbrew}" \
    MARGINE_BREW_INSTALLER="${INSTALLER:-file://$T/fake-install.sh}" MARGINE_SUDO="" \
    MARGINE_REPO_DIR="$T/repos" \
    bash "$HELPER" "$@" 2>&1)" || RC=$?
}
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; echo "$OUT" | sed 's/^/     /'; fails=$((fails+1)); fi
}
says()   { case "$OUT" in *"$1"*) return 0;; *) return 1;; esac; }
is()     { [ "$OUT" = "$1" ]; }
rc_is()  { [ "$RC" = "$1" ]; }
runs()   { [ "$(cat "$T/runs" 2>/dev/null | wc -l)" = "$1" ]; }
nl() { printf '%s\n' "$@"; }

# --- package list ----------------------------------------------------------
run packages;                 check "packages: comments, blanks and trailing spaces dropped" is "$(nl code gcc make)"
LIST=$T/nope run packages;    check "packages: a missing list fails"                        rc_is 1
: > "$T/empty"
LIST=$T/empty run packages;   check "packages: an empty list fails"                         rc_is 1
LIST=$LIST_SHIPPED run packages
check "packages: the shipped list has VS Code"                                              says "code"
check "packages: the shipped list parses to plain names"                                    bash -c '! grep -qE "[[:space:]#]" <<<"$1"' _ "$OUT"

# --- what the deployment requests -------------------------------------------
deploy true steam code make
run layered;                  check "layered: only the layer's packages, in request order"  is "$(nl code make)"
deploy true steam
run layered;                  check "layered: none of ours requested, empty and exit 0"     bash -c '[ -z "$1" ] && [ "$2" = 0 ]' _ "$OUT" "$RC"
echo "not json" > "$T/deploy.json"
run layered;                  check "layered: an unreadable status is an error, not 'none'" bash -c '[ "$1" != 0 ]' _ "$RC"
LIST=$T/nope run layered;     check "layered: a missing list is an error"                   bash -c '[ "$1" != 0 ]' _ "$RC"
deploy true
run pending;                  check "pending: newest deployment booted, nothing waits"      rc_is 1
deploy false code
run pending;                  check "pending: a staged deployment waits"                    rc_is 0

# --- root-only steps refuse a user ----------------------------------------
if [[ $EUID -ne 0 ]]; then
  run repo;                   check "repo: refused without root"                            bash -c '[ "$1" = 1 ] && grep -q "run as root" <<<"$2"' _ "$RC" "$OUT"
  run repo-remove;            check "repo-remove: refused without root"                     rc_is 1
fi

# --- Homebrew ----------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  run brew-install
  check "brew-install: exit 0"                                                              rc_is 0
  check "brew-install: the prefix and its parent exist"                                     test -d "$T/linuxbrew/.linuxbrew"
  check "brew-install: brew answers"                                                        says "Homebrew installed: Homebrew 9.9.9"
  check "brew-install: says the shell is set up"                                            says "no need to edit ~/.bashrc"
  check "brew-install: the installer ran once"                                              runs 1
  run brew-install
  check "brew-install again: already installed, exit 0"                                     bash -c '[ "$1" = 0 ] && grep -q "already installed" <<<"$2"' _ "$RC" "$OUT"
  check "brew-install again: the installer did not run"                                     runs 1
  run brew-count;             check "brew-count: formulae and casks"                        is 3

  mkdir -p "$T/home/.cache/Homebrew"
  BREWROOT=$T/brewroot run brew-remove
  check "brew-remove: refuses a directory not named linuxbrew"                              rc_is 1
  BREWROOT=linuxbrew run brew-remove
  check "brew-remove: refuses a relative path"                                              rc_is 1
  check "brew-remove: refusals left Homebrew in place"                                      test -x "$T/linuxbrew/.linuxbrew/bin/brew"
  run brew-remove
  check "brew-remove: exit 0"                                                               rc_is 0
  check "brew-remove: the prefix is gone"                                                   test ! -e "$T/linuxbrew"
  check "brew-remove: brew's cache is gone"                                                 test ! -e "$T/home/.cache/Homebrew"
  run brew-remove;            check "brew-remove again: nothing to remove, exit 0"          bash -c '[ "$1" = 0 ] && grep -q "not installed" <<<"$2"' _ "$RC" "$OUT"
  run brew-count;             check "brew-count without Homebrew: 0"                        is 0

  rm -f "$T/runs"
  MODE=fail run brew-install; check "brew-install: an installer failure is the exit code"   rc_is 7
  rm -rf "$T/linuxbrew"
  MODE=nobrew run brew-install
  check "brew-install: installer done but no brew, a failure"                               bash -c '[ "$1" = 1 ] && grep -q "is missing" <<<"$2"' _ "$RC" "$OUT"
  rm -rf "$T/linuxbrew"
  INSTALLER=file://$T/no-such-installer run brew-install
  check "brew-install: no installer download, a failure that says so"                       bash -c '[ "$1" != 0 ] && grep -q "could not download" <<<"$2"' _ "$RC" "$OUT"
fi

# --- status --------------------------------------------------------------------
rm -rf "$T/linuxbrew"; mkdir -p "$T/repos"; : > "$T/repos/vscode.repo"
deploy false code gcc
INSTALLED="gcc make" run status
check "status: layered and booted"                                                          bash -c 'grep -qE "^  gcc +installed \(1.0\)$" <<<"$1"' _ "$OUT"
check "status: in the image, not requested"                                                 bash -c 'grep -qE "^  make +installed \(1.0\), part of the image$" <<<"$1"' _ "$OUT"
check "status: requested, waiting for a restart"                                            bash -c 'grep -qE "^  code +layered, active after a restart$" <<<"$1"' _ "$OUT"
check "status: the VS Code repository"                                                      says "VS Code repository: configured"
check "status: no Homebrew"                                                                 says "Homebrew: not installed"

run nonsense;                 check "an unknown command: usage, exit 2"                     rc_is 2

echo
if (( fails )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
