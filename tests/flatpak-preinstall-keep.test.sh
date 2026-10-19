#!/usr/bin/env bash
# Tests for /usr/libexec/margine/flatpak-preinstall-keep with the real
# `flatpak preinstall` (Flatpak 1.16 or later) against a local repository of
# tiny test apps. Everything happens in a per-user installation under a temp
# directory (FLATPAK_USER_DIR, HOME and XDG dirs point there), so the test
# needs no root and never touches the machine's own Flatpaks. The helper
# reads that installation through FLATPAK_SYSTEM_DIR, the variable it honours
# in place of /var/lib/flatpak.
#
# What it checks is the 2026-10-18 failure: apps that leave the default list
# were uninstalled by the next preinstall. A control run without the helper
# reproduces that first.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/build_files/system_files/usr/libexec/margine/flatpak-preinstall-keep"

if ! command -v flatpak >/dev/null 2>&1 || ! flatpak preinstall --help >/dev/null 2>&1 \
   || ! command -v ostree >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: needs flatpak with 'preinstall' (1.16+), ostree and python3"
  echo "      (CI runs this in a Fedora container, see lint.yml)"
  # CI sets this, so a container without the tools fails instead of passing.
  [ -z "${FLATPAK_TEST_REQUIRED:-}" ] || exit 1
  exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ARCH="$(flatpak --default-arch)"

# Run flatpak and the helper with an environment that has no way back to the
# real installations: no session bus, temp HOME, data and config dirs.
fp() {
  env -i PATH=/usr/bin:/bin HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" \
    XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" \
    FLATPAK_USER_DIR="$INST" FLATPAK_DATA_DIR="$T/data" FLATPAK_CONFIG_DIR="$T/etc" \
    flatpak "$@"
}
keep() {
  env -i PATH=/usr/bin:/bin FLATPAK_SYSTEM_DIR="$INST" FLATPAK_DATA_DIR="$T/data" \
    FLATPAK_CONFIG_DIR="$T/etc" python3 -I "$HELPER" "$@"
}
preinstall() { fp preinstall --user -y --noninteractive >"$T/last.log" 2>&1; }
record()    { ostree config --repo="$INST/repo" --group=core get xa.preinstalled 2>/dev/null || echo "<none>"; }
on_record() { record | tr ';' '\n' | grep -qx "app/org.test.$1/$ARCH/stable"; }
here()      { [ -e "$INST/app/org.test.$1/$ARCH/stable/active" ]; }
gone()      { ! here "$1"; }
off_record() { ! on_record "$1"; }
declare_apps() {
  rm -f "$T/data/preinstall.d/"*
  local a
  for a in "$@"; do printf '[Flatpak Preinstall org.test.%s]\nBranch=stable\nIsRuntime=false\n\n' "$a"; done \
    > "$T/data/preinstall.d/lucciola-defaults.preinstall"
}
check() {
  local name="$1"; shift
  if "$@"; then echo "ok   $name"
  else echo "FAIL $name"; sed 's/^/     /' "$T/last.log"; echo "     record: $(record)"; fails=$((fails+1)); fi
}

# ---- a local repository: one runtime, seven apps --------------------------
mkdir -p "$T/home" "$T/data/preinstall.d" "$T/etc/preinstall.d" "$T/b/rt/files"
printf '[Runtime]\nname=org.test.Platform\nruntime=org.test.Platform/%s/1\nsdk=org.test.Platform/%s/1\n' "$ARCH" "$ARCH" > "$T/b/rt/metadata"
INST="$T/unused"
fp build-export --runtime --files=files "$T/repo" "$T/b/rt" 1 >/dev/null
for a in A B M R S X; do
  d="$T/b/$a"; mkdir -p "$d/files/bin"
  printf '#!/bin/sh\necho %s\n' "$a" > "$d/files/bin/run"; chmod +x "$d/files/bin/run"
  printf '[Application]\nname=org.test.%s\nruntime=org.test.Platform/%s/1\ncommand=run\n' "$a" "$ARCH" > "$d/metadata"
  fp build-finish --command=run "$d" >/dev/null
  fp build-export "$T/repo" "$d" stable >/dev/null
done
fp build-update-repo "$T/repo" >/dev/null

# ---- a machine on the old list ---------------------------------------------
# A and B stay defaults; R and S leave the list; M was installed by hand
# before it became a default (the state of an install that came from
# Margine, whose record started after its apps were there).
setup() {
  INST="$1"
  fp remote-add --user --no-gpg-verify test "file://$T/repo"
  declare_apps A B R S
  preinstall
  fp uninstall --user -y --noninteractive org.test.S >/dev/null   # removed on purpose
  fp uninstall --user -y --noninteractive org.test.B >/dev/null   # removed on purpose
  fp install --user -y --noninteractive test org.test.M >/dev/null
}

setup "$T/control"
check "setup: the first preinstall records the defaults" bash -c '[ "$1" = "app/org.test.A/$2/stable;app/org.test.B/$2/stable;app/org.test.R/$2/stable;app/org.test.S/$2/stable" ]' _ "$(record)" "$ARCH"
setup_state() { here R && gone S && gone B && here M; }
check "setup: R installed, S and B removed by the user, M by hand" setup_state

# ---- control: the image's new list WITHOUT the helper (the bug) ------------
declare_apps A B M
preinstall
check "control: Flatpak uninstalls R once it leaves the list (the 2026-10-18 bug)" gone R
check "control: B, removed by the user, is not installed again"                  gone B
fp uninstall --user -y --noninteractive org.test.M >/dev/null
preinstall
check "control: M, never on the record, comes back after the user removes it"    here M

# ---- the same machine WITH the helper --------------------------------------
setup "$T/fixed"
declare_apps A B M
keep >"$T/last.log" 2>&1 && preinstall
check "R left the list: still installed"                       here R
check "R: off the record, now the user's app"                   off_record R
check "S left the list, removed by the user: stays removed"     gone S
check "S: stays on the record (the removal is remembered)"      on_record S
check "B, a default removed by the user: not installed again"   gone B
check "B: still on the record"                                  on_record B
check "A: still installed"                                      here A
check "A: still on the record"                                  on_record A
check "M, a default installed by hand: adopted on the record"   on_record M

before="$(record)"
keep >"$T/last.log" 2>&1
check "a second run changes nothing"                            bash -c '[ "$1" = "$2" ] && grep -q "record unchanged" "$3"' _ "$before" "$(record)" "$T/last.log"
preinstall
check "the second preinstall has nothing to do"                 grep -q "Nothing to do" "$T/last.log"

fp uninstall --user -y --noninteractive org.test.M >/dev/null
keep >"$T/last.log" 2>&1 && preinstall
check "M removed after adoption: stays removed"                 gone M

# Install=false in /etc takes A off the list: it is released, not removed.
printf '[Flatpak Preinstall org.test.A]\nInstall=false\n' > "$T/etc/preinstall.d/no-a.preinstall"
keep >"$T/last.log" 2>&1 && preinstall
check "Install=false in /etc: A still installed"                here A
check "Install=false in /etc: A released from the record"       off_record A
rm -f "$T/etc/preinstall.d/no-a.preinstall"

# --dry-run prints and writes nothing.
declare_apps A B M X
before="$(record)"
keep --restore --dry-run >"$T/last.log" 2>&1
check "--dry-run writes nothing"                                bash -c '[ "$1" = "$2" ] && grep -q "dry run" "$3"' _ "$before" "$(record)" "$T/last.log"

# --restore (ujust lucciola-slim-restore): the listed apps the user removed
# come back; what is not listed stays as it is.
keep --restore >"$T/last.log" 2>&1 && preinstall
check "--restore: B installed again"                            here B
check "--restore: M installed again"                            here M
check "--restore: X, a new default, installed"                  here X
check "--restore: S, not a default any more, stays removed"     gone S
check "--restore: R untouched"                                  here R
restored_on_record() { on_record B && on_record M && on_record X; }
check "--restore: B, M and X back on the record"                restored_on_record

# An empty list releases everything installed; the record stays (empty, not
# missing), so Flatpak does not start it again from scratch.
declare_apps
keep >"$T/last.log" 2>&1 && preinstall
all_here() { here A && here B && here M && here R && here X; }
check "empty list: nothing uninstalled"                         all_here
check "empty list: only the removed S stays on the record"      bash -c '[ "$1" = "app/org.test.S/$2/stable" ]' _ "$(record)" "$ARCH"

# A repository without a record, or no repository at all: nothing to do.
INST="$T/none"
keep >"$T/last.log" 2>&1
check "no repository: exits 0, says so"                         grep -q "no system repository yet" "$T/last.log"
mkdir -p "$T/fresh"; INST="$T/fresh"; fp remote-add --user --no-gpg-verify test "file://$T/repo"
keep >"$T/last.log" 2>&1
check "no record yet: left to Flatpak"                          grep -q "no preinstall record yet" "$T/last.log"

echo
if [ "$fails" -eq 0 ]; then echo "all flatpak-preinstall-keep tests passed"; else echo "$fails failure(s)"; exit 1; fi
