#!/usr/bin/env bash
# The weekly upgrade matrix (.github/scripts/upgrade-matrix.py and its wiring
# in upgrade-smoke.yml): a dispatch is one cell made of its inputs, an empty
# layer stays empty; the weekly run has the four starting points, five once
# :stable is promoted (steam layered on margine:lucciola only then), every
# weekly cell targets :candidate over the unverified transport, with unique
# names and slugs; and the workflow runs them one at a time, never cancels
# the rest on a failed cell, keeps each cell's logs apart, keeps the dispatch
# inputs, and notifies ntfy with the cell's name when one fails.
# PyYAML is needed for the workflow part (lint.yml installs it).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/.github/scripts/upgrade-matrix.py"
WF="$ROOT/.github/workflows/upgrade-smoke.yml"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out"; fails=$((fails+1)); fi
}
plan() {  # the JSON on stdout is what the workflow reads; the words go to stderr
  RC=0; env -i PATH=/usr/bin:/bin python3 -I "$SCRIPT" "$@" > "$T/out" 2> "$T/err" || RC=$?
}
q() { python3 -c 'import json,sys; cells=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$T/out" "$1"; }

plan --event workflow_dispatch --from ghcr.io/x/old:1 --to ghcr.io/x/new:2 --transport ostree-image-signed --layer htop --expect-id-like fedora
check "dispatch: one cell (rc $RC)"                              [ "$(q 'len(cells)')" = 1 ]
check "dispatch: the inputs as given"                            [ "$(q 'cells[0]["from_ref"], cells[0]["to_ref"], cells[0]["transport"], cells[0]["layer"], cells[0]["expect_id_like"]')" = "('ghcr.io/x/old:1', 'ghcr.io/x/new:2', 'ostree-image-signed', 'htop', 'fedora')" ]
check "dispatch: a name that says what moves"                    [ "$(q 'cells[0]["name"]')" = "from old:1 to new:2, htop layered" ]
plan --event workflow_dispatch --from ghcr.io/x/old:1 --to ghcr.io/x/new:2 --layer ""
check "dispatch: an empty layer stays empty"                     [ "$(q 'cells[0]["layer"]')" = "" ]
check "dispatch: transport and ID_LIKE default when empty"       [ "$(q 'cells[0]["transport"], cells[0]["expect_id_like"]')" = "('ostree-unverified-registry', 'fedora')" ]
plan --event workflow_dispatch --from "" --to ""
check "dispatch without refs: refused (rc $RC)"                  [ "$RC" != 0 ]

plan --event schedule --promote-stable false
check "weekly, :stable held: four cells (rc $RC)"                [ "$(q 'len(cells)')" = 4 ]
check "weekly: no steam cell while :stable is held"              [ "$(q 'any("steam" in c["layer"] for c in cells)')" = False ]
check "weekly: margine:lucciola with cowsay comes first"         [ "$(q 'cells[0]["from_ref"], cells[0]["layer"]')" = "('ghcr.io/daniel-g-carrasco/margine:lucciola', 'cowsay')" ]
check "weekly: silverblue, kinoite and bluefin starts"           [ "$(q 'sorted(c["from_ref"] for c in cells[1:])')" = "['ghcr.io/ublue-os/bluefin:stable', 'quay.io/fedora/fedora-kinoite:45', 'quay.io/fedora/fedora-silverblue:45']" ]
check "weekly: every cell targets :candidate, unverified"        [ "$(q 'set((c["to_ref"], c["transport"]) for c in cells)')" = "{('ghcr.io/daniel-g-carrasco/lucciola:candidate', 'ostree-unverified-registry')}" ]
check "weekly: names and slugs are unique"                       [ "$(q 'len({c["name"] for c in cells}) == len(cells) == len({c["slug"] for c in cells})')" = True ]
check "weekly: the same cells in words, for the log"             bash -c "[ \"\$(grep -c '^- from ' '$T/err')\" = 4 ]"
plan --event schedule --promote-stable true
check "weekly, :stable promoted: five cells (rc $RC)"            [ "$(q 'len(cells)')" = 5 ]
check "weekly: steam layered on margine:lucciola, then"          [ "$(q '[(c["from_ref"].rsplit("/",1)[1], c["layer"]) for c in cells if c["layer"] == "steam"]')" = "[('margine:lucciola', 'steam')]" ]
plan --event schedule --promote-stable TRUE
check "weekly: the variable's case does not matter"              [ "$(q 'len(cells)')" = 5 ]

# --- the workflow -----------------------------------------------------------
python3 - "$WF" > "$T/out" 2>&1 <<'PY' && RC=0 || RC=$?
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
on = wf.get("on") or wf.get(True)
bad = []
crons = [s.get("cron") for s in on.get("schedule") or []]
if crons != ["0 8 * * 0"]:
    bad.append(f"schedule must be Sunday 08:00 UTC ('0 8 * * 0'), got {crons}")
inputs = (on.get("workflow_dispatch") or {}).get("inputs") or {}
for name in ("from_ref", "to_ref", "transport", "layer", "expect_id_like"):
    if name not in inputs:
        bad.append(f"workflow_dispatch input {name} is gone")
jobs = wf["jobs"]
plan = jobs.get("plan")
smoke = jobs.get("upgrade_smoke")
if not plan or not smoke:
    bad.append("jobs plan and upgrade_smoke are both needed")
else:
    plan_text = yaml.dump(plan)
    if "upgrade-matrix.py" not in plan_text or "vars.LUCCIOLA_PROMOTE_STABLE" not in plan_text:
        bad.append("the plan job must run upgrade-matrix.py with vars.LUCCIOLA_PROMOTE_STABLE")
    if "if" in plan:
        bad.append("the plan job must have no if: (upgrade_smoke needs it; check-job-conditions)")
    if smoke.get("needs") not in ("plan", ["plan"]):
        bad.append("upgrade_smoke must need plan")
    st = smoke.get("strategy") or {}
    if st.get("max-parallel") != 1:
        bad.append("strategy.max-parallel must be 1 (one VM, one concurrency group)")
    if st.get("fail-fast") is not False:
        bad.append("strategy.fail-fast must be false (a failed cell must not cancel the rest)")
    inc = str((st.get("matrix") or {}).get("include", ""))
    if "fromJSON(needs.plan.outputs.matrix)" not in inc:
        bad.append("matrix.include must come from the plan job's output")
    if smoke.get("name") != "${{ matrix.name }}":
        bad.append("the cell's job name must be the cell's name")
    steps = smoke["steps"]
    smoke_text = yaml.dump(steps)
    if "inputs." in smoke_text:
        bad.append("steps must read matrix.*, not inputs.* (the schedule has no inputs)")
    for key in ("matrix.from_ref", "matrix.to_ref", "matrix.transport", "matrix.layer", "matrix.expect_id_like"):
        if key not in smoke_text:
            bad.append(f"no step reads {key}")
    uploads = [s for s in steps if str(s.get("uses", "")).startswith("actions/upload-artifact")]
    if not uploads or any("matrix.slug" not in str(s.get("with", {}).get("name", "")) for s in uploads):
        bad.append("the logs artifact must carry matrix.slug in its name (one per cell)")
    ntfy = [s for s in steps if "NTFY_TOPIC_URL" in yaml.dump(s)]
    if len(ntfy) != 1:
        bad.append("exactly one ntfy step")
    else:
        n = ntfy[0]
        if str(n.get("if", "")).strip() != "failure()":
            bad.append("the ntfy step runs on failure() only")
        if "matrix.name" not in yaml.dump(n):
            bad.append("the ntfy message must carry the cell's name")
        if "skipping notification" not in n.get("run", ""):
            bad.append("the ntfy step must skip quietly when the secret is unset")
conc = wf.get("concurrency") or {}
if conc.get("group") != "upgrade-smoke" or conc.get("cancel-in-progress") is not False:
    bad.append("concurrency must stay group upgrade-smoke, cancel-in-progress false")
print("\n".join(bad) or "workflow OK")
sys.exit(1 if bad else 0)
PY
check "upgrade-smoke.yml: schedule, plan, matrix, logs, ntfy" [ "$RC" = 0 ]
RC=0; python3 "$ROOT/.github/scripts/check-job-conditions.py" "$WF" > "$T/out" 2>&1 || RC=$?
check "upgrade-smoke.yml: no job can be skipped by accident" [ "$RC" = 0 ]

if (( fails )); then echo "$fails upgrade-matrix case(s) failed"; exit 1; fi
echo "all upgrade-matrix cases passed"
