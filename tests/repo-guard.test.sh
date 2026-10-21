#!/usr/bin/env bash
# tools/repo-guard.sh without touching GitHub: check against recorded states
# (matching, drifted, unprotected, unreadable), apply refused without a
# typed yes and sent as one PUT with it, through a fake gh; the required
# checks are exactly lint.yml's always-running jobs, by the names GitHub
# gives them; and the pitfall is written where the list is.
# PyYAML is needed for the lint.yml part (lint.yml installs it).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/tools/repo-guard.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out"; fails=$((fails+1)); fi
}
says() { grep -q -- "$1" "$T/out"; }

# A protection as the API returns it, matching the policy.
cat > "$T/good.json" <<'JSON'
{"required_status_checks":{"strict":true,"contexts":["policy","lint","build-inputs-need-vm-test","flatpak-preinstall"],
 "checks":[{"context":"lint","app_id":15368}]},
 "enforce_admins":{"enabled":true},
 "required_pull_request_reviews":{"required_approving_review_count":0,"dismiss_stale_reviews":false},
 "allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false},
 "required_conversation_resolution":{"enabled":true},"required_linear_history":{"enabled":false}}
JSON
jq '.required_status_checks.contexts = ["lint"] | .allow_force_pushes.enabled = true | del(.required_pull_request_reviews)' "$T/good.json" > "$T/drift.json"
echo '{"message":"Branch not protected","documentation_url":"x","status":"404"}' > "$T/unprotected.json"
echo '{"message":"Resource not accessible by integration","status":"403"}' > "$T/forbidden.json"

run() {  # run <state file> <mode> [stdin]
  RC=0
  REPO_GUARD_STATE_FILE="$1" bash "$GUARD" "$2" > "$T/out" 2>&1 <<<"${3:-}" || RC=$?
}
run "$T/good.json" check
check "a matching protection: exit 0 (rc $RC)"                      [ "$RC" = 0 ]
check "...every field reported ok"                                   bash -c "[ \"\$(grep -c '^ok ' '$T/out')\" = 7 ]"
run "$T/drift.json" check
check "a drifted protection: exit 1 (rc $RC)"                       [ "$RC" = 1 ]
check "...names the missing checks"                                  says 'DRIFT  required checks.*got \["lint"\]'
check "...the force-push"                                            says 'DRIFT  no force-push: want false, got true'
check "...the missing pull request requirement"                      says 'DRIFT  a pull request is required.*got null'
check "...and says how to apply"                                     says 'repo-guard.sh apply'
run "$T/unprotected.json" check
check "an unprotected branch: exit 1 (rc $RC)"                      [ "$RC" = 1 ]
check "...said in words"                                             says 'is not protected at all'
run "$T/forbidden.json" check
check "a token that cannot read it: exit 2, not drift (rc $RC)"    [ "$RC" = 2 ]
check "...saying an admin token is needed"                           says 'admin token'
run "$T/good.json" show
check "show prints the policy as JSON (rc $RC)"                     bash -c "jq -e '.required_status_checks.strict == true and .enforce_admins == true and .required_pull_request_reviews.required_approving_review_count == 0 and .allow_force_pushes == false and .allow_deletions == false and .required_conversation_resolution == true and .restrictions == null' '$T/out' >/dev/null"
run "$T/good.json" bogus
check "an unknown mode: exit 2 (rc $RC)"                            [ "$RC" = 2 ]

# apply: through a fake gh that records what it is asked.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
if [[ "$*" == *"-X PUT"* ]]; then cat > "$FAKE_LOG.body"; exit 0; fi
# As the real gh on an HTTP error: the body on stdout, its line on stderr, exit 1.
if [[ -n "${FAKE_HTTP_ERROR:-}" ]]; then cat "$FAKE_STATE"; echo "gh: ${FAKE_HTTP_ERROR} (HTTP 404)" >&2; exit 1; fi
cat "$FAKE_STATE"
STUB
chmod +x "$T/bin/gh"
apply() {  # apply <answer>
  RC=0; : > "$T/log"; rm -f "$T/log.body"
  env PATH="$T/bin:$PATH" FAKE_LOG="$T/log" FAKE_STATE="$T/good.json" bash "$GUARD" apply > "$T/out" 2>&1 <<<"$1" || RC=$?
}
RC=0; : > "$T/log"
env PATH="$T/bin:$PATH" FAKE_LOG="$T/log" FAKE_STATE="$T/unprotected.json" FAKE_HTTP_ERROR="Branch not protected" bash "$GUARD" check > "$T/out" 2>&1 || RC=$?
check "through gh, an unprotected branch (body on stdout, HTTP 404 on stderr): exit 1 (rc $RC)" [ "$RC" = 1 ]
check "...said in words"                                             says 'is not protected at all'
RC=0; : > "$T/log"
env PATH="$T/bin:$PATH" FAKE_LOG="$T/log" FAKE_STATE="$T/good.json" bash "$GUARD" check > "$T/out" 2>&1 || RC=$?
check "through gh, a matching protection: exit 0 (rc $RC)"          [ "$RC" = 0 ]
apply no
check "apply without a typed yes: nothing sent, exit 1 (rc $RC)"   bash -c "[ '$RC' = 1 ] && ! grep -q PUT '$T/log'"
check "...and it says so"                                            says 'Not applied'
apply yes
check "apply with yes: one PUT to the protection endpoint (rc $RC)" bash -c "[ '$RC' = 0 ] && [ \"\$(grep -c -- '-X PUT repos/daniel-g-carrasco/lucciola/branches/main/protection --input -' '$T/log')\" = 1 ]"
check "...with the policy as its body"                               bash -c "jq -e '.required_status_checks.contexts | sort == [\"build-inputs-need-vm-test\",\"flatpak-preinstall\",\"lint\",\"policy\"]' '$T/log.body' >/dev/null"
check "...then reads it back"                                        says 'matches the policy'

# The contexts are lint.yml's always-running jobs, by the names GitHub uses.
python3 - "$ROOT" "$GUARD" > "$T/out" 2>&1 <<'PY' && RC=0 || RC=$?
import re, sys, yaml
root, guard = sys.argv[1:]
text = open(guard).read()
m = re.search(r"^CONTEXTS=\((.*?)\)$", text, re.M)
contexts = sorted(m.group(1).split()) if m else []
lint = yaml.safe_load(open(f"{root}/.github/workflows/lint.yml"))
always = []
for job_id, job in lint["jobs"].items():
    cond = str(job.get("if", "")).strip()
    if cond in ("", "github.event_name == 'pull_request'"):
        always.append(job.get("name") or job_id)
bad = []
if contexts != sorted(always):
    bad.append(f"CONTEXTS {contexts} must equal lint.yml's always-running jobs {sorted(always)}")
on = lint.get("on") or lint.get(True)
if "paths" in (on.get("pull_request") or {}) or "paths-ignore" in (on.get("pull_request") or {}):
    bad.append("lint.yml must have no path filter on pull_request: its jobs are required checks")
if "forever" not in text or "PITFALL" not in text:
    bad.append("the pitfall (a required check that does not run blocks the merge forever) must be in the header")
print("\n".join(bad) or "contexts OK")
sys.exit(1 if bad else 0)
PY
check "CONTEXTS are lint.yml's always-running jobs, and the pitfall is written" [ "$RC" = 0 ]

if (( fails )); then echo "$fails repo-guard case(s) failed"; exit 1; fi
echo "all repo-guard cases passed"
