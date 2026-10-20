#!/usr/bin/env bash
# The MOK private key is mounted in one RUN only, the mok-sign stage's,
# and that RUN can run nothing but the signer (review N1, 2026-10-20).
# Read from the Containerfile and the scripts, no build:
#   - exactly one RUN mounts a secret, and it is the mok-sign stage's;
#   - that stage is FROM the base and holds that RUN and nothing else (no
#     COPY, no other RUN, no package install before the key arrives);
#   - the RUN has --network=none and runs `bash /ctx/mok-sign.sh` alone,
#     from its own context stage;
#   - mok-sign.sh installs, downloads and evaluates nothing;
#   - the steps that run third-party code refuse a mounted key at runtime
#     (refuse_signing_key in build.sh, custom-kernel and finalize.sh);
#   - the mutation of review N1 (a build step reading the key) is caught.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" 2>/dev/null || true; fails=$((fails+1)); fi
}

scope() {  # scope <Containerfile>: prints one verdict per line
  python3 - "$1" <<'PY'
import re, shlex, sys
text = open(sys.argv[1]).read()
# Join continuation lines, drop comments.
lines, buf = [], ""
for raw in text.splitlines():
    if not buf and raw.lstrip().startswith("#"):
        continue
    if raw.rstrip().endswith("\\"):
        buf += raw.rstrip()[:-1] + " "
        continue
    buf += raw
    if buf.strip():
        lines.append(buf.strip())
    buf = ""
stages, cur = [], None
for ins in lines:
    word = ins.split(None, 1)[0].upper()
    if word == "FROM":
        parts = ins.split()
        cur = {"from": parts[1], "name": parts[3] if len(parts) > 3 and parts[2].upper() == "AS" else "", "ins": []}
        stages.append(cur)
    elif cur is not None:
        cur["ins"].append(ins)
secret_runs = []
for st in stages:
    for ins in st["ins"]:
        if ins.upper().startswith("RUN") and "type=secret" in ins:
            secret_runs.append((st, ins))
print(f"secret-runs={len(secret_runs)}")
if len(secret_runs) != 1:
    sys.exit(0)
st, run = secret_runs[0]
print(f"stage={st['name']}")
print(f"from={st['from']}")
others = [i.split(None, 1)[0].upper() for i in st["ins"] if i is not run]
print(f"other-instructions={','.join(o for o in others if o != 'ARG') or 'none'}")
toks = shlex.split(run)[1:]
flags = [t for t in toks if t.startswith("--")]
cmd = [t for t in toks if not t.startswith("--")]
print(f"network-none={'--network=none' in flags}")
ids = sorted(re.search(r"id=([^,]+)", f).group(1) for f in flags if "type=secret" in f)
print(f"secret-ids={','.join(ids)}")
print(f"command={' '.join(cmd)}")
script = [f for f in flags if "target=/ctx/mok-sign.sh" in f]
print(f"script-from={re.search(r'from=([^,]+)', script[0]).group(1) if script else ''}")
ctx = next((s for s in stages if s["name"] == (re.search(r'from=([^,]+)', script[0]).group(1) if script else None)), None)
print(f"script-ctx={'|'.join(ctx['ins']) if ctx else ''}")
PY
}

scope "$ROOT/Containerfile" > "$T/out"
has() { grep -qxF "$1" "$T/out"; }
check "exactly one RUN mounts a secret"            has "secret-runs=1"
check "it is the mok-sign stage's"                 has "stage=mok-sign"
check "that stage is FROM the clean base"          has 'from=${BASE_IMAGE}'
check "nothing else runs in that stage"            has "other-instructions=none"
check "the signing RUN has no network"             has "network-none=True"
check "it mounts the MOK key and cert only"        has "secret-ids=mok-cert,mok-key"
check "it runs the signer and nothing else"        has "command=bash /ctx/mok-sign.sh /in/modules /in/mok-sign.list /out"
check "the signer comes from its own context"      has "script-from=mok-sign-ctx"
check "that context holds the signer alone"        has "script-ctx=COPY build_files/custom-kernel/mok-sign.sh /mok-sign.sh"

# The layout before review N1 (the key on the RUN that runs build.sh) fails.
sed -E '/^RUN --mount=type=bind,from=ctx,source=\/,target=\/ctx/a\    --mount=type=secret,id=mok-key,target=/run/margine-certs/MOK.key \\' \
  "$ROOT/Containerfile" > "$T/Containerfile.n1"
scope "$T/Containerfile.n1" > "$T/out"
check "a secret on the build RUN is caught"        bash -c "! grep -qx 'secret-runs=1' '$T/out'"

# The signer installs, downloads and evaluates nothing.
SIGNER="$ROOT/build_files/custom-kernel/mok-sign.sh"
grep -vE '^\s*#' "$SIGNER" > "$T/signer.code"
cp "$T/signer.code" "$T/out"
check "mok-sign.sh: no package manager, download or eval" \
  bash -c "! grep -qwE 'dnf|rpm|rpm-ostree|curl|wget|pip|eval|source' '$T/signer.code'"

# The steps that run third-party code refuse a mounted key.
for f in build_files/build.sh build_files/custom-kernel/install.sh build_files/custom-kernel/finalize.sh; do
  grep -nE '^\s*refuse_signing_key\s*$' "$ROOT/$f" > "$T/out" || true
  check "$f calls refuse_signing_key" test -s "$T/out"
done
# ... and the guard works: a stand-in for a key at its mount point stops it.
mkdir -p "$T/run"
rc=0
( set +e; . "$ROOT/build_files/00-common.sh" >/dev/null 2>&1
  refuse_signing_key ) > "$T/out" 2>&1 || rc=$?
check "refuse_signing_key passes without a key (rc $rc)" [ "$rc" = 0 ]
sed "s|/run/margine-certs /run/secrets/mok-key /run/secrets/mok-cert|$T/run/margine-certs|" \
  "$ROOT/build_files/00-common.sh" > "$T/common.sh"
mkdir -p "$T/run/margine-certs"
rc=0
( . "$T/common.sh" >/dev/null 2>&1; refuse_signing_key ) > "$T/out" 2>&1 || rc=$?
check "refuse_signing_key stops the build with a key present (rc $rc)" [ "$rc" = 1 ]

# Review N1's mutation: a build step reading the key. With the key mounted
# only in mok-sign, the file does not exist where build steps run; the
# build fails on the guard before such a step is reached. Here: no script
# under build_files (or lucciola/build.sh) names the key path, except the
# signer and the guard.
grep -rlE 'margine-certs|MOK\.key' "$ROOT/build_files" "$ROOT/lucciola/build.sh" \
  | sed "s|^$ROOT/||" | sort > "$T/out" || true
check "only the signer and the guard name the key path" \
  bash -c "diff <(printf '%s\n' build_files/00-common.sh build_files/custom-kernel/mok-sign.sh) '$T/out' >/dev/null"

[ "$fails" = 0 ] && echo "mok-secret-scope: all checks passed" || { echo "mok-secret-scope: $fails failed"; exit 1; }
