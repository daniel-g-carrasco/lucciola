#!/usr/bin/env bash
# Image build: make devices verify the image signature on every update
# (2026-10-06).
#
# CI signs every image with cosign (secrets/cosign.pub), but until then no
# installed system checked it: /etc/containers/policy.json had no scope for
# the image's repository, so pulls fell through to the docker catch-all
# `insecureAcceptAnything`. A system on the "signed" transport
# (ostree-image-signed:) therefore verified nothing, and ISO installs sat on
# ostree-unverified-registry: anyway.
#
# This adds the missing scopes next to Universal Blue's ublue-os one. It
# does not replace the file: policy.json has no drop-in directory, and
# replacing it would freeze every other scope the base ships.
#
# Two repositories, one key. ghcr.io/daniel-g-carrasco/lucciola is what this
# image updates from. ghcr.io/daniel-g-carrasco/margine is the repository
# Lucciola was published in until it got its own (as :lucciola), signed by
# the same key: keeping its scope means a device that rebases between the
# two is verified both ways.
#
# Prerequisites shipped from system_files:
#   /usr/lib/pki/containers/margine.pub              copy of secrets/cosign.pub
#   /etc/containers/registries.d/lucciola.yaml       use-sigstore-attachments
#   /etc/containers/registries.d/margine.yaml        use-sigstore-attachments
# The key only verifies the CLASSIC cosign signature (sha256-<digest>.sig);
# build.yml writes one since #448 and smoke-boot refuses images without it.
set -euo pipefail
. /ctx/00-common.sh

POLICY=/etc/containers/policy.json
KEY=/usr/lib/pki/containers/margine.pub
SCOPES=(ghcr.io/daniel-g-carrasco/lucciola ghcr.io/daniel-g-carrasco/margine)

[[ -s "$KEY" ]] || { err "missing $KEY (system_files)"; exit 1; }
[[ -s "$POLICY" ]] || { err "missing $POLICY in the base image"; exit 1; }
for scope in "${SCOPES[@]}"; do
  f="/etc/containers/registries.d/${scope##*/}.yaml"
  grep -qs "^  ${scope}:" "$f" || { err "missing $f for $scope (system_files)"; exit 1; }
done

python3 - "$POLICY" "$KEY" "${SCOPES[@]}" <<'PY'
import json, sys
path, key, scopes = sys.argv[1], sys.argv[2], sys.argv[3:]
policy = json.load(open(path))
docker = policy.setdefault("transports", {}).setdefault("docker", {})
for scope in scopes:
    docker[scope] = [{
        "type": "sigstoreSigned",
        "keyPath": key,
        "signedIdentity": {"type": "matchRepository"},
    }]
with open(path, "w") as f:
    json.dump(policy, f, indent=2)
    f.write("\n")
PY

for scope in "${SCOPES[@]}"; do
  python3 -c "import json, sys; p=json.load(open(sys.argv[1])); r=p['transports']['docker'][sys.argv[2]][0]; assert r['type']=='sigstoreSigned' and r['keyPath']==sys.argv[3]" \
    "$POLICY" "$scope" "$KEY" \
    || { err "policy scope for $scope did not stick"; exit 1; }
  log "image trust: $scope must be signed by $KEY"
done
