# shellcheck shell=bash
# Native gaming alignment, sourced by custom-kernel/install.sh (the why is
# there, above the call) and tested by tests/gaming-align.test.sh with a
# fake dnf. Needs GAMING_LAYER (the layer's packages) and log, err and
# retry from 00-common.sh.

# The transaction dnf would run to layer GAMING_LAYER on the image, printed;
# 1 when the layer does not resolve or dnf gives no verdict.
gaming_plan() {  # gaming_plan [--refresh]
  local out attempt refresh="${1:-}"
  for attempt in 1 2 3 4 5; do
    # shellcheck disable=SC2086  # $refresh is --refresh or nothing
    out="$(dnf install --assumeno $refresh --setopt=install_weak_deps=False --enablerepo=fedora-multimedia "${GAMING_LAYER[@]}" 2>&1 || true)"
    if grep -q '^Transaction Summary' <<<"$out"; then printf '%s\n' "$out"; return 0; fi
    if grep -qE '^Failed to resolve the transaction|^Problem' <<<"$out"; then
      printf '%s\n' "$out" | tail -n 40 >&2
      err "the gaming-native layer does not resolve against the image even with upgrades allowed"
      return 1
    fi
    log "gaming plan attempt $attempt: no verdict from dnf, retrying in ${GAMING_PLAN_PAUSE:-30} s" >&2
    sleep "${GAMING_PLAN_PAUSE:-30}"
  done
  err "dnf gave no gaming plan in five attempts (repositories down?)"
  return 1
}

# The x86_64 and noarch builds of a plan (on stdin) that take the place of
# an installed package. Rows are " <name> <arch> <epoch:version-release>
# <repo> <size>", and a row that replaces an installed package is followed
# by "   replacing <old>" rows. The i686 chain itself is never picked.
gaming_align_list() {
  awk '
    /^ [^ ]/          { cand = ($2 == "i686") ? "" : $1 "-" $3 "." $2; next }
    /^   replacing /  { if (cand != "") print cand; cand = ""; next }
                      { cand = "" }' | sort -u
}

# One view of the repositories: plan on fresh metadata, then install the
# builds the plan picked on that same metadata (no clean, no refresh: the
# three steps of 2026-10-21 must not straddle mirrors). 0 aligned, 1 the
# downloads failed, 2 the layer does not resolve.
gaming_align_round() {
  local plan
  plan="$(gaming_plan --refresh)" || return 2
  mapfile -t GAMING_ALIGN < <(gaming_align_list <<<"$plan")
  if (( ${#GAMING_ALIGN[@]} == 0 )); then
    log "No image package needs upgrading for the gaming-native layer"
    return 0
  fi
  log "Aligning ${#GAMING_ALIGN[@]} image packages with the gaming-native layer: ${GAMING_ALIGN[*]}"
  retry 2 "${GAMING_RETRY_PAUSE:-30}" dnf -y install --setopt=install_weak_deps=False --enablerepo=fedora-multimedia "${GAMING_ALIGN[@]}" && return 0
  return 1
}

# Up to ROUNDS views. A view whose builds cannot be downloaded is thrown
# away whole: while Fedora 45 was a pre-release, metadata could still list
# a build every mirror had already dropped (expat-2.8.5 after 2.9.0, on
# 2026-10-21: "All mirrors were tried", 404 on each), and retrying on that
# view only repeated the 404s. Fresh metadata on the next round names the
# build the mirrors hold.
gaming_align() {  # gaming_align [ROUNDS] [PAUSE]
  local rounds=${1:-4} pause=${2:-60} round rc
  for (( round = 1; round <= rounds; round++ )); do
    rc=0
    gaming_align_round || rc=$?
    case $rc in
      0) return 0 ;;
      2) return 1 ;;
    esac
    if (( round < rounds )); then
      log "the alignment could not download the builds the plan picked: a new view of the repositories in ${pause} s (round $(( round + 1 )) of $rounds)"
      dnf -y clean metadata >/dev/null 2>&1 || true
      sleep "$pause"
    fi
  done
  err "aligning the image packages failed in $rounds views of the repositories; aborting"
  return 1
}
