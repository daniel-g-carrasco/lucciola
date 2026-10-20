#!/usr/bin/env bash
# Resolve the base image ONCE, for the build and for the labels.
#
#   usage: resolve-base.sh <image-ref>
#   prints (for $GITHUB_OUTPUT):
#     name=<the reference as given, e.g. ghcr.io/ublue-os/silverblue-main:45>
#     digest=sha256:<64 hex>
#     base=<repository>@<digest>   (what the Containerfile's FROM gets)
#   exit:  0 resolved, 1 not resolved (registry unreachable, no such image,
#          no digest): the build must not go on without it.
#
# Until 2026-10-20 (review R9) build.yml looked the digest up best-effort
# for the base.digest label only and built FROM the tag: a tag that moved
# between the lookup and buildah's pull gave an image labelled with a base
# it was not built on, and the kernel reserve (build-fedora-kernel.yml),
# which builds FROM the labelled digest, then used a different base from
# the image it backs up. Now the build uses the digest it records.
# base-watch and the reserve keep reading the same two labels: base.name,
# the human-readable reference, and base.digest.
set -euo pipefail
ref="${1:?usage: resolve-base.sh <image-ref>}"

# The repository: the reference without its digest and without its tag (a
# tag is a ':' in the last path component; an earlier one is a port).
repo="${ref%%@*}"
last="${repo##*/}"
[[ "$last" == *:* ]] && repo="${repo%:*}"

if ! digest="$(skopeo inspect --retry-times 3 --no-tags --format '{{.Digest}}' "docker://${ref}")"; then
  echo "::error::cannot resolve the base image ${ref}: no build without its digest" >&2
  exit 1
fi
# A reference that already names a digest keeps it: that is what was asked.
[[ "$ref" == *@sha256:* ]] && digest="${ref##*@}"
if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "::error::the base image ${ref} resolved to '${digest}', not a sha256 digest" >&2
  exit 1
fi
printf 'name=%s\ndigest=%s\nbase=%s@%s\n' "$ref" "$digest" "$repo" "$digest"
