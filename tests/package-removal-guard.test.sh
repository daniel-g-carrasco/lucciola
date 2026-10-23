#!/usr/bin/env bash
# The package-removal guard (.github/scripts/package-removal-guard.py) on
# package lists: identical lists pass; a package gone from the new image
# fails when enforced and is a warning otherwise; an expected, dated
# removal passes; a line past its window fails; a line whose package is
# still there, or already gone from both images, is a note within the
# window; additions are reported; a malformed or future-dated line is an
# error whatever the mode. Then the wiring in build.yml: the step runs on
# the built image before chunking, skips pull requests, enforces on
# candidate builds, and the expected-removals file is where it says.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/.github/scripts/package-removal-guard.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out"; fails=$((fails+1)); fi
}
lists() {  # lists <new names> <published names>
  tr ' ' '\n' <<<"$1" > "$T/new"; tr ' ' '\n' <<<"$2" > "$T/published"
}
expect() { printf '%s\n' "$@" > "$T/expected"; }
guard() {  # guard <args...> ; sets RC, output in $T/out
  RC=0
  env -i PATH=/usr/bin:/bin python3 -I "$GUARD" --new "$T/new" --published "$T/published" --expected "$T/expected" \
    --today 2026-10-20 --summary "$T/summary.md" "$@" > "$T/out" 2>&1 || RC=$?
}
says() { grep -q -- "$1" "$T/out"; }

lists "a b c" "a b c"; expect "# nothing"
guard --enforce
check "identical lists pass (rc $RC)"                                        [ "$RC" = 0 ]
check "...and say so in the summary"                                          says "0 added, 0 removed"

lists "a b" "a b nautilus"; expect "# nothing"
guard --enforce
check "an unexpected removal fails on a main build (rc $RC)"                 [ "$RC" = 1 ]
check "...naming the package and the line to add"                             says "nautilus 2026-10-20 <why>"
check "...with an ::error::"                                                  says "^::error::nautilus is in the published image"
check "...and the summary lists it as removed"                                grep -qx nautilus "$T/summary.md"
guard
check "the same, not enforced: passes with a warning (rc $RC)"               [ "$RC" = 0 ]
check "...an ::warning:: instead"                                             says "^::warning::nautilus is in the published image"

lists "a b" "a b nautilus"; expect "nautilus 2026-10-18 replaced by Files from Flathub"
guard --enforce
check "an expected, dated removal passes (rc $RC)"                           [ "$RC" = 0 ]
check "...and the summary says why"                                           says "removed as expected"

lists "a b" "a b nautilus"; expect "nautilus 2026-10-01 long ago"
guard --enforce
check "a line past the 14-day window fails (rc $RC)"                         [ "$RC" = 1 ]
check "...asking to delete it"                                                says "delete the line"
guard --enforce --grace-days 30
check "...the window is a parameter (30 days: rc $RC)"                      [ "$RC" = 0 ]

lists "a b nautilus" "a b nautilus"; expect "nautilus 2026-10-18 soon"
guard --enforce
check "a listed package still in both images: a warning, not a failure (rc $RC)" [ "$RC" = 0 ]
check "...saying it is still in the image"                                    says "::warning::.*still in the image"

lists "a b" "a b"; expect "nautilus 2026-10-18 shipped"
guard --enforce
check "a listed package gone from both images: a note (rc $RC)"              [ "$RC" = 0 ]
check "...with the date to delete it by"                                      says "delete the line .* before 2026-11-01"

lists "a b new1 new2" "a b"; expect "# nothing"
guard --enforce
check "added packages are no failure (rc $RC)"                               [ "$RC" = 0 ]
check "...and are listed"                                                     bash -c "grep -qx new1 '$T/summary.md' && grep -qx new2 '$T/summary.md' && grep -q '2 added, 0 removed' '$T/summary.md'"

lists "a a b" "a b b"; expect "# nothing"
guard --enforce
check "duplicate names (multilib) are one package (rc $RC)"                  [ "$RC" = 0 ]
lists "a kmod-v4l2loopback-7.3.0-4.cachyos1.fc45.x86_64" "a kmod-v4l2loopback-7.3.0-cachyos1.fc45.x86_64"; expect "# nothing"
guard --enforce
check "a kernel module rebuilt for a new kernel is the same package (rc $RC)" [ "$RC" = 0 ]
check "...nothing added, nothing removed"                                     says "0 added, 0 removed"
lists "a" "a kmod-v4l2loopback-7.3.0-cachyos1.fc45.x86_64"; expect "# nothing"
guard --enforce
check "a kernel module gone for good still fails (rc $RC)"                   [ "$RC" = 1 ]
check "...by its module name"                                                 says "kmod-v4l2loopback 2026-10-20 <why>"
lists "a" "a kmod-v4l2loopback-7.3.0-cachyos1.fc45.x86_64"; expect "kmod-v4l2loopback 2026-10-18 the loopback camera left"
guard --enforce
check "...and is expected by its module name (rc $RC)"                       [ "$RC" = 0 ]

lists "a" "a"; expect "nautilus"
guard
check "a line without a date is an error, even unenforced (rc $RC)"         [ "$RC" = 2 ]
lists "a" "a"; expect "nautilus 2026-13-40 bad"
guard
check "a line with a bad date is an error (rc $RC)"                          [ "$RC" = 2 ]
lists "a" "a"; expect "nautilus 2026-11-05 tomorrow"
guard
check "a future date is an error (rc $RC)"                                   [ "$RC" = 2 ]
lists "a" "a"; expect "nautilus 2026-10-18 a" "nautilus 2026-10-19 b"
guard
check "a package listed twice is an error (rc $RC)"                          [ "$RC" = 2 ]

# --- the wiring in build.yml ------------------------------------------------
python3 - "$ROOT" > "$T/out" 2>&1 <<'PY' && RC=0 || RC=$?
import os, sys, yaml
root = sys.argv[1]
bad = []
if not os.path.isfile(f"{root}/build_files/expected-removals.txt"):
    bad.append("build_files/expected-removals.txt is missing")
wf = yaml.safe_load(open(f"{root}/.github/workflows/build.yml"))
steps = wf["jobs"]["build_push"]["steps"]
names = [s.get("name", "") for s in steps]
guard = [i for i, s in enumerate(steps) if "package-removal-guard.py" in (s.get("run") or "")]
if len(guard) != 1:
    bad.append("build_push must run package-removal-guard.py in exactly one step")
else:
    i = guard[0]
    s = steps[i]
    run = s["run"]
    build = next(j for j, n in enumerate(names) if n.startswith("Build image"))
    chunk = next(j for j, n in enumerate(names) if n.startswith("Chunk the image"))
    if not (build < i < chunk):
        bad.append("the guard must run after the build and before the chunking (the built image is removed then)")
    env = s.get("env") or {}
    if "pull_request" not in run or env.get("EVENT") != "${{ github.event_name }}":
        bad.append("the guard step must skip pull_request builds through EVENT")
    pub = str(env.get("PUBLISHED", ""))
    if ("CANDIDATE_TAG" not in pub and ":candidate" not in pub) or "${{ env.IMAGE_NAME }}" not in pub:
        bad.append("the guard compares with the published :candidate of this image")
    if "--enforce" not in run or "publish_tag" not in str(env):
        bad.append("the guard enforces on builds that publish :candidate (steps.base.outputs.publish_tag)")
    if "expected-removals.txt" not in run or "GITHUB_STEP_SUMMARY" not in run:
        bad.append("the guard reads build_files/expected-removals.txt and writes the step summary")
    if "podman rmi" not in run:
        bad.append("the pulled published image must be removed again (disk)")
print("\n".join(bad) or "build.yml wiring OK")
sys.exit(1 if bad else 0)
PY
check "build.yml runs the guard where and how it should" [ "$RC" = 0 ]

if (( fails )); then echo "$fails package-removal-guard case(s) failed"; exit 1; fi
echo "all package-removal-guard cases passed"
