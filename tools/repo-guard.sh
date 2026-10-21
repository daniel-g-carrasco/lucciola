#!/usr/bin/env bash
# Branch protection for main, as code: compare (check) or set (apply).
#
#   tools/repo-guard.sh [check|apply|show]       (just repo-guard [mode])
#
#   check   read repos/<owner>/<repo>/branches/main/protection through gh and
#           print each field against the policy below: exit 0 when they
#           match, 1 on any drift (an unprotected branch is all drift), 2 when
#           the protection cannot be read with this token (admin needed).
#   apply   show the policy as JSON, ask for a typed `yes`, PUT it, then check.
#   show    print the policy as JSON.
#
# The policy (2026-10-20): a pull request is required but one person can
# merge it (0 approvals), its branch must be up to date with main (strict),
# the conversations resolved, admins included, no force-push, no deletion,
# and the status checks below must pass.
#
# PITFALL, read before touching CONTEXTS: a required status check that does
# not run on a pull request blocks its merge forever (GitHub waits for a
# verdict that never comes). Only jobs that run on EVERY pull request may be
# required: lint.yml's, which has no path filter and listens to label
# events; never build.yml's jobs (vm-test pull requests only), never a job
# behind a `paths:` filter or an `if:` other than "this is a pull request".
# GitHub names an Actions check by the job's `name:` or, without one, its
# id; the names below are what the check-runs API reports on pull request
# heads (lint, flatpak-preinstall) and the two jobs added with them.
# tests/repo-guard.test.sh keeps CONTEXTS equal to lint.yml's always-running
# jobs; repo-guard.yml reads the public `protected` field weekly and runs
# this check (which, with the workflow token, can only say it cannot read).
set -euo pipefail

REPO="${REPO_GUARD_REPO:-daniel-g-carrasco/lucciola}"
BRANCH="${REPO_GUARD_BRANCH:-main}"
CONTEXTS=(lint flatpak-preinstall build-inputs-need-vm-test policy)
# Tests point this at a JSON file instead of calling gh (tests/repo-guard.test.sh).
STATE_FILE="${REPO_GUARD_STATE_FILE:-}"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

policy_json() {
  jq -n --argjson contexts "$(printf '%s\n' "${CONTEXTS[@]}" | jq -R . | jq -s .)" '{
    required_status_checks: {strict: true, contexts: $contexts},
    enforce_admins: true,
    required_pull_request_reviews: {
      required_approving_review_count: 0,
      dismiss_stale_reviews: false,
      require_code_owner_reviews: false
    },
    restrictions: null,
    required_linear_history: false,
    allow_force_pushes: false,
    allow_deletions: false,
    block_creations: false,
    required_conversation_resolution: true,
    lock_branch: false,
    allow_fork_syncing: false
  }'
}

read_state() {  # prints the protection JSON, or a {"message": ...} error body
  if [[ -n "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
    return 0
  fi
  # On an HTTP error gh prints the API's JSON body ({"message": ...}) on
  # stdout and its own line on stderr; keep the body, or make one from stderr.
  local out err
  err="$(mktemp)"
  if out="$(gh api "repos/${REPO}/branches/${BRANCH}/protection" 2>"$err")" \
     || { [[ -n "$out" ]] && jq -e . <<<"$out" >/dev/null 2>&1; }; then
    printf '%s\n' "$out"
  else
    jq -n --arg m "$(tr '\n' ' ' <"$err")" '{message: $m}'
  fi
  rm -f "$err"
}

check() {
  local state message drift=0
  state="$(read_state)"
  if ! jq -e . <<<"$state" >/dev/null 2>&1; then
    echo "repo-guard: the protection of ${REPO} ${BRANCH} came back as something other than JSON:"
    printf '%s\n' "$state" | head -n 5
    return 2
  fi
  message="$(jq -r '.message // empty' <<<"$state")"
  if [[ "$message" == "Branch not protected" ]]; then
    echo "DRIFT: ${REPO} ${BRANCH} is not protected at all (no required checks, no pull request, force-push allowed)"
    echo "repo-guard: drift. Apply the policy with: tools/repo-guard.sh apply"
    return 1
  fi
  if [[ -n "$message" ]]; then
    echo "repo-guard: cannot read the protection of ${REPO} ${BRANCH}: ${message}"
    echo "            (reading it needs an admin token: run this where gh is logged in as the owner)"
    return 2
  fi
  want() {  # want <label> <jq expression> <expected>
    local got
    got="$(jq -c "$2" <<<"$state")"
    if [[ "$got" == "$3" ]]; then
      echo "ok     $1: $got"
    else
      echo "DRIFT  $1: want $3, got $got"
      drift=1
    fi
  }
  local contexts
  contexts="$(printf '%s\n' "${CONTEXTS[@]}" | sort | jq -R . | jq -sc .)"
  want "required checks are exactly lint's always-running jobs" '.required_status_checks.contexts | sort' "$contexts"
  want "branch must be up to date before merging (strict)" '.required_status_checks.strict' true
  want "a pull request is required, 0 approvals" '.required_pull_request_reviews.required_approving_review_count' 0
  want "admins included" '.enforce_admins.enabled' true
  want "no force-push" '.allow_force_pushes.enabled' false
  want "no deletion" '.allow_deletions.enabled' false
  want "conversations resolved before merging" '.required_conversation_resolution.enabled' true
  if (( drift )); then
    echo "repo-guard: drift. Apply the policy with: tools/repo-guard.sh apply"
    return 1
  fi
  echo "repo-guard: ${REPO} ${BRANCH} matches the policy"
}

apply() {
  echo "This will set the protection of ${REPO} ${BRANCH} to:"
  policy_json
  echo
  echo "Required checks: ${CONTEXTS[*]} (every one runs on every pull request; see the pitfall in $0)."
  local answer
  read -r -p "Type yes to apply: " answer
  if [[ "$answer" != yes ]]; then
    echo "Not applied."
    return 1
  fi
  policy_json | gh api -X PUT "repos/${REPO}/branches/${BRANCH}/protection" --input - > /dev/null
  echo "Applied. Reading it back:"
  check
}

case "${1:-check}" in
  check) check ;;
  apply) apply ;;
  show) policy_json ;;
  -h|--help|help) usage ;;
  *) echo "unknown mode '$1'" >&2; usage >&2; exit 2 ;;
esac
