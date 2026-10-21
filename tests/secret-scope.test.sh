#!/usr/bin/env bash
# The secret-scope checker (.github/scripts/check-secret-scope.py) on
# fixtures: a Containerfile and workflows laid out as the policy wants pass;
# a secret on another stage, on the final stage, without --network=none, a
# policy naming a stage that is not there, a job not on the allowlist, a
# stale allowlist entry, a secret outside env:, an action between staging
# and the build, a wipe that is late or not `if: always()`, and a stray
# reader of the staged directory each fail, naming the place. The real
# tree is judged by lint's policy job (red until the mok-sign stage lands).
# PyYAML is needed (lint.yml installs it).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/.github/scripts/check-secret-scope.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out"; fails=$((fails+1)); fi
}

# --- fixtures --------------------------------------------------------------
good_containerfile() {
  cat <<'CF'
ARG BASE_IMAGE=example.org/base:1
FROM scratch AS ctx
COPY build_files /
FROM ${BASE_IMAGE} AS system
# a comment with --mount=type=secret in it is not an instruction
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/build.sh
FROM ${BASE_IMAGE} AS mok-sign
RUN --network=none \
    --mount=type=bind,from=system,source=/usr/lib/modules,target=/in \
    --mount=type=secret,id=mok-key,target=/run/margine-certs/MOK.key \
    --mount=type=secret,id=mok-cert,target=/run/margine-certs/MOK.pem \
    bash /ctx/mok-sign.sh
FROM system
RUN --mount=type=bind,from=mok-sign,source=/out,target=/signed /ctx/finalize.sh
CF
}
good_build_yml() {
  cat <<'WF'
name: Build
on: { push: { branches: [main] } }
jobs:
  build_push:
    runs-on: ubuntu-26.04
    steps:
      - uses: actions/checkout@abc
      - name: Image metadata
        uses: docker/metadata-action@abc
      - name: Stage MOK secrets for BuildKit
        env:
          MOK_KEY: ${{ secrets.MOK_KEY }}
          MOK_CERT: ${{ secrets.MOK_CERT }}
        run: |
          mkdir -p /tmp/margine-secrets
          printf '%s' "$MOK_KEY" > /tmp/margine-secrets/MOK.key
      - name: Build image
        run: |
          sudo buildah build --secret id=mok-key,src=/tmp/margine-secrets/MOK.key .
      - name: Wipe staged secrets
        if: always()
        run: rm -rf /tmp/margine-secrets
      - name: Push
        run: skopeo copy a b
  sign:
    runs-on: ubuntu-26.04
    steps:
      - name: Sign image by digest
        env:
          COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}
        run: cosign sign --key env://COSIGN_PRIVATE_KEY x
WF
}
fresh() {
  rm -rf "$T/w"; mkdir -p "$T/w/.github/workflows" "$T/w/tests/policy"
  good_containerfile > "$T/w/Containerfile"
  good_build_yml > "$T/w/.github/workflows/build.yml"
  printf 'name: Lint\non: [pull_request]\njobs:\n  lint:\n    runs-on: ubuntu-26.04\n    steps:\n      - run: echo ok\n' > "$T/w/.github/workflows/lint.yml"
  printf '# stages\nmok-sign none\n' > "$T/w/tests/policy/secret-stages.txt"
  printf '# jobs\nbuild.yml build_push MOK_KEY MOK_CERT\nbuild.yml sign COSIGN_PRIVATE_KEY\n' > "$T/w/tests/policy/secret-jobs.txt"
}
run() { RC=0; (cd "$T/w" && env -i PATH=/usr/bin:/bin python3 "$CHECK" --root "$T/w") > "$T/out" 2>&1 || RC=$?; }
says() { grep -q -- "$1" "$T/out"; }
edit() { python3 - "$T/w/$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) == 1, (p, old, s.count(old))
open(p, "w").write(s.replace(old, new))
PY
}

fresh; run
check "the intended layout passes (rc $RC)"                                   [ "$RC" = 0 ]

fresh; edit Containerfile 'RUN --mount=type=bind,from=ctx,source=/,target=/ctx \' 'RUN --mount=type=bind,from=ctx,source=/,target=/ctx --mount=type=secret,id=mok-key,target=/k \'; run
check "a secret on the build stage: fails (rc $RC)"                           [ "$RC" = 1 ]
check "...naming the stage and the policy"                                    says "stage system mounts secret(s) mok-key"

fresh; edit Containerfile 'RUN --mount=type=bind,from=mok-sign,source=/out,target=/signed /ctx/finalize.sh' 'RUN --mount=type=secret,id=mok-key,target=/k /ctx/finalize.sh'; run
check "a secret on the final stage: fails (rc $RC)"                           [ "$RC" = 1 ]
check "...saying the image that ships may never see one"                      says "final stage"

fresh; edit Containerfile 'RUN --network=none \' 'RUN \'; run
check "the signing RUN without --network=none: fails (rc $RC)"                [ "$RC" = 1 ]
check "...naming it"                                                          says "without --network=none"

fresh; edit Containerfile 'FROM ${BASE_IMAGE} AS mok-sign' 'FROM ${BASE_IMAGE} AS signer'; run
check "a policy stage the Containerfile lacks: fails (rc $RC)"                [ "$RC" = 1 ]
check "...and the secret is on an unlisted stage"                             says "stage signer mounts"

fresh; printf 'mok-sign none\nsystem any\n' > "$T/w/tests/policy/secret-stages.txt"
edit Containerfile 'RUN --mount=type=bind,from=ctx,source=/,target=/ctx \' 'RUN --mount=type=bind,from=ctx,source=/,target=/ctx --mount=type=secret,id=mok-key,target=/k \'; run
check "a stage the policy allows with any network passes (rc $RC)"           [ "$RC" = 0 ]
fresh; printf 'mok-sign maybe\n' > "$T/w/tests/policy/secret-stages.txt"; run
check "a malformed stages policy: rc 2 (rc $RC)"                              [ "$RC" = 2 ]

fresh; edit .github/workflows/lint.yml '      - run: echo ok' '      - env: { K: "${{ secrets.COSIGN_PRIVATE_KEY }}" }
        run: echo ok'; run
check "a job off the allowlist naming a secret: fails (rc $RC)"               [ "$RC" = 1 ]
check "...naming workflow and job"                                            says "lint.yml: job lint names secrets.COSIGN_PRIVATE_KEY"

fresh; printf 'build.yml build_push MOK_KEY MOK_CERT\nbuild.yml sign COSIGN_PRIVATE_KEY\nlint.yml lint COSIGN_PRIVATE_KEY\n' > "$T/w/tests/policy/secret-jobs.txt"; run
check "a stale allowlist entry: fails (rc $RC)"                               [ "$RC" = 1 ]
check "...asking to remove it"                                                says "remove the stale entry"

fresh; edit .github/workflows/build.yml 'run: cosign sign --key env://COSIGN_PRIVATE_KEY x' 'run: cosign sign --key "${{ secrets.COSIGN_PRIVATE_KEY }}" x'; run
check "a secret in run: text: fails (rc $RC)"                                 [ "$RC" = 1 ]
check "...env: only"                                                          says "outside env:"

fresh; edit .github/workflows/build.yml $'name: Build\non:' $'name: Build\nenv:\n  MOK_KEY: ${{ secrets.MOK_KEY }}\non:'; run
check "a workflow-level env with a secret: fails (rc $RC)"                    [ "$RC" = 1 ]

fresh; edit .github/workflows/build.yml '      - name: Build image
        run: |' '      - name: Get the date
        uses: some/action@abc
      - name: Build image
        run: |'; run
check "an action between staging and the build: fails (rc $RC)"              [ "$RC" = 1 ]
check "...naming what came next"                                              says "must be the build that reads /tmp/margine-secrets (got 'Get the date')"

fresh; edit .github/workflows/build.yml '      - name: Wipe staged secrets
        if: always()
        run: rm -rf /tmp/margine-secrets
      - name: Push
        run: skopeo copy a b' '      - name: Push
        run: skopeo copy a b
      - name: Wipe staged secrets
        if: always()
        run: rm -rf /tmp/margine-secrets'; run
check "a wipe that is not right after the build: fails (rc $RC)"             [ "$RC" = 1 ]
check "...naming the step found instead"                                      says "got 'Push'"

fresh; edit .github/workflows/build.yml '        if: always()
        run: rm -rf /tmp/margine-secrets' '        run: rm -rf /tmp/margine-secrets'; run
check "a wipe without if: always(): fails (rc $RC)"                           [ "$RC" = 1 ]

fresh; edit .github/workflows/build.yml 'run: skopeo copy a b' 'run: cat /tmp/margine-secrets/MOK.key; skopeo copy a b'; run
check "another step reading the staged directory: fails (rc $RC)"            [ "$RC" = 1 ]
check "...naming it"                                                          says "step 'Push' refers to /tmp/margine-secrets"

fresh; edit .github/workflows/build.yml '          mkdir -p /tmp/margine-secrets
' ''; run
check "a staging step without a mkdir of its directory: fails (rc $RC)"      [ "$RC" = 1 ]

if (( fails )); then echo "$fails secret-scope case(s) failed"; exit 1; fi
echo "all secret-scope cases passed"
