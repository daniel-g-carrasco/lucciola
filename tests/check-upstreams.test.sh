#!/usr/bin/env bash
# build_files/40-spec-scripts/scripts/check-upstreams.sh on a throwaway
# document and a fake gh and curl: the last review is the newest date in the
# table's last column and nothing else (a later date in a cell or in the
# text does not count: the 2026-11 run counted from the day of the base
# switch), a document without one stops the run, a full page of commits
# reads "100+", an upstream that did not move asks for no review, and the
# base is on the list while the archived rechunk is not.
# Needs jq.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CU="$ROOT/build_files/40-spec-scripts/scripts/check-upstreams.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { local n="$1"; shift; if "$@"; then echo "ok   $n"; else echo "FAIL $n"; sed 's/^/     /' "$T/out" 2>/dev/null | tail -n 8; fails=$((fails+1)); fi; }
says() { grep -qE -- "$1" "$T/out"; }
quiet() { ! grep -qE -- "$1" "$T/out"; }

mkdir -p "$T/bin" "$T/fake"
export FAKE="$T/fake"
cat > "$T/bin/gh" <<'SH'
#!/bin/sh
# gh api -X GET /repos/OWNER/NAME/commits -f since=... -f per_page=100 --jq length
echo "$*" >> "$FAKE/gh-calls"
name=$(printf '%s' "$4" | sed -e 's|^/repos/||' -e 's|/commits$||' -e 's|/|_|g')
cat "$FAKE/$name" 2>/dev/null || echo 0
SH
cat > "$T/bin/curl" <<'SH'
#!/bin/sh
echo "$*" >> "$FAKE/curl-calls"
echo '[]'
SH
chmod +x "$T/bin/gh" "$T/bin/curl"
run() { RC=0; CHECK_UPSTREAMS_DOC="$T/doc.md" PATH="$T/bin:/usr/bin:/bin" bash "$CU" "$@" > "$T/out" 2>&1 || RC=$?; }

cat > "$T/doc.md" <<'MD'
# Upstreams

| Upstream | Role | Last reviewed |
| --- | --- | --- |
| base | ours since 2026-10-11, was something else until 2026-12-31 | 2026-10-03 |
| kernel | signing | 2026-09-01 |

## Review log

### 2026-10-03

Written on 2026-10-20, about a release of 2026-10-28.
MD

run --last-reviewed
check "the date comes from the last column (rc $RC)" [ "$RC" = 0 ]
check "...the newest one there" [ "$(cat "$T/out")" = "2026-10-03" ]
check "...and --last-reviewed asks the network nothing" [ ! -e "$FAKE/gh-calls" ]

sed -i 's/| 2026-09-01 |$/| 2026-11-10 |   /' "$T/doc.md"
run --last-reviewed
check "a row reviewed later moves it, trailing blanks or not" [ "$(cat "$T/out")" = "2026-11-10" ]

echo 100 > "$FAKE/ublue-os_main"
echo 7 > "$FAKE/ublue-os_bazzite"
run
check "a full run ends well (rc $RC)" [ "$RC" = 0 ]
check "...counting from that date" grep -q -- '-f since=2026-11-10T00:00:00Z -f per_page=100' "$FAKE/gh-calls"
check "...a full page reads 100+, and asks for a review" says '^  main +ublue-os/main +100\+ new commit\(s\)'
check "...a smaller count is the count" says '^  bazzite +ublue-os/bazzite +7 new commit\(s\)'
check "...an upstream that did not move asks for nothing" says '^  chunkah +coreos/chunkah +0 commit\(s\) \(no review needed\)'
check "...GitLab is asked too" grep -q 'rakuos%2Fimages%2Frakuos-base' "$FAKE/curl-calls"
check "...the archived rechunk is not asked" quiet 'hhd-dev/rechunk'

rm -f "$FAKE"/ublue-os_*
run
check "nothing moved: nothing to do" says '^No new activity; nothing to do\.$'
check "...and no line the workflow would take for activity" quiet 'new commit\(s\)'

printf '# Upstreams\n\nReviewed on 2026-10-03, in words only.\n' > "$T/doc.md"
run --last-reviewed
check "a document with no date in the column stops the run (rc $RC)" [ "$RC" != 0 ]
check "...and says why" says "no 'Last reviewed' date found"

real=$(CHECK_UPSTREAMS_DOC="$ROOT/docs/upstream-inspirations.md" bash "$CU" --last-reviewed)
check "the real document has a last review ($real)" grep -qE '^202[0-9]-[0-9]{2}-[0-9]{2}$' <<<"$real"
newest_row=$(grep -E '^\| \[' "$ROOT/docs/upstream-inspirations.md" | grep -oE '202[0-9]-[0-9]{2}-[0-9]{2} \|$' | grep -oE '^[0-9-]+' | sort | tail -1)
check "...the newest of its table rows" [ "$real" = "$newest_row" ]

if (( fails )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
