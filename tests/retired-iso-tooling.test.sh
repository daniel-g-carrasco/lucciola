#!/usr/bin/env bash
# Margine's ISO tooling is archived, not offered (review R10, 2026-10-20).
# live-env/ (Margine's Titanoboa live image), tools/iso-builder/ and
# tools/bench/ moved to docs/history/margine/: they built and tested
# Margine (ghcr.io/daniel-g-carrasco/margine:stable) and called a workflow
# this repository does not have. What must hold:
#   - nothing that runs (Justfile recipes, workflows, CI scripts, build
#     scripts, the Containerfile) uses the old paths, outside comments;
#   - no just recipe builds or boots an ISO;
#   - the archive is where its README says, and the Flatpak list the image
#     build reads (installer/flatpaks-base) is still in place and used.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out"; fails=$((fails+1)); fi
}

# Every non-comment line of what runs; an old path not under docs/history/
# is an entry point into the archive.
{ git ls-files Justfile Containerfile '.github/workflows/*' '.github/scripts/*' '.github/smoke/*' 'build_files/*' 'lucciola/*'; } \
  | while read -r f; do
      [ -f "$f" ] || continue
      grep -nE '(^|[^/[:alnum:]_.-])(live-env/|tools/iso-builder|tools/bench)' "$f" /dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//|;)' || true
    done > "$T/out"
check "no runnable reference to live-env/, tools/iso-builder or tools/bench" [ ! -s "$T/out" ]

grep -nE '^(build-iso|build-iso-fast|test-install-vm|iso-gui|install-desktop)([[:space:]]|:)' Justfile > "$T/out" || true
check "no just recipe builds or boots an ISO" [ ! -s "$T/out" ]

: > "$T/out"
for d in live-env live-env/src tools/iso-builder tools/bench; do
  [ -e "docs/history/margine/$d" ] || echo "missing docs/history/margine/$d" >> "$T/out"
done
for d in live-env tools/iso-builder tools/bench; do
  [ ! -e "$d" ] || echo "$d is still in the tree" >> "$T/out"
done
grep -q 'live-env' docs/history/margine/tools/README.md || echo "the archive README does not name live-env" >> "$T/out"
check "the archive is in docs/history/margine, with its README" [ ! -s "$T/out" ]

: > "$T/out"
[ -s installer/flatpaks-base ] || echo "installer/flatpaks-base is missing" >> "$T/out"
grep -qE '^COPY installer/flatpaks-base[[:space:]]' Containerfile || echo "the Containerfile no longer copies installer/flatpaks-base" >> "$T/out"
check "installer/flatpaks-base stays, and the Containerfile reads it" [ ! -s "$T/out" ]

if (( fails )); then echo "$fails retired-iso-tooling case(s) failed"; exit 1; fi
echo "all retired-iso-tooling cases passed"
