#!/usr/bin/env bash
# scrcpy's pin comes from upstream's signed checksums, not from the bytes
# the release URL serves (review N2, 2026-10-20). Offline, with throwaway
# OpenPGP keys and a fake release directory read through file://:
#   - .github/scripts/scrcpy-signed-sha.sh prints the tarball's sha256 from
#     a SHA256SUMS.txt signed by the pinned key, and refuses: a signature
#     by another key, a changed SHA256SUMS.txt, a missing signature, a key
#     file with a second key in it, a tarball listed twice or not at all;
#   - the pinned key file in the repository is the one key the script pins;
#   - scrcpy-pin-sha.yml takes the hash from the script (main's copy), never
#     from hashing the download; build.yml's pins job checks every Renovate
#     scrcpy bump against it, and a failed check holds the image build back.
# PyYAML is needed for the last part (lint.yml installs it).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/.github/scripts/scrcpy-signed-sha.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" 2>/dev/null | tail -n 20 || true; fails=$((fails+1)); fi
}

# Two throwaway signers.
export GNUPGHOME="$T/keys"; mkdir -m 0700 "$GNUPGHOME"
for who in upstream mallory; do
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
      --quick-gen-key "$who <$who@example.invalid>" rsa2048 sign 1d 2>/dev/null
done
fpr() { gpg --batch --with-colons --list-keys "$1" | awk -F: '$1 == "fpr" {print $10; exit}'; }
UP="$(fpr upstream)"; MAL="$(fpr mallory)"
gpg --batch --armor --export "$UP" > "$T/upstream.asc"
gpg --batch --armor --export "$UP" "$MAL" > "$T/two-keys.asc"

V=9.8.7
release() {  # release <signer|none> [sums-line...]: writes $T/rel/v$V
  local signer="$1"; shift
  rm -rf "$T/rel"; mkdir -p "$T/rel/v$V"
  if (( $# )); then printf '%s\n' "$@" > "$T/rel/v$V/SHA256SUMS.txt"
  else
    printf '%s  %s\n' "$(printf 'a%.0s' {1..64})" "scrcpy-server-v$V" \
                      "$(printf 'b%.0s' {1..64})" "scrcpy-linux-x86_64-v$V.tar.gz" \
                      "$(printf 'c%.0s' {1..64})" "scrcpy-win64-v$V.zip" > "$T/rel/v$V/SHA256SUMS.txt"
  fi
  [[ "$signer" == none ]] || gpg --batch --quiet --armor --local-user "$signer" \
      --detach-sign -o "$T/rel/v$V/SHA256SUMS.txt.asc" "$T/rel/v$V/SHA256SUMS.txt" 2>/dev/null
}
run() {  # run [key-file] ; sets RC, output in $T/out
  RC=0
  env -u GNUPGHOME SCRCPY_KEY_FILE="${1:-$T/upstream.asc}" SCRCPY_KEY_FPR="$UP" \
      SCRCPY_RELEASE_BASE="file://$T/rel" bash "$SCRIPT" "$V" > "$T/out" 2>&1 || RC=$?
}

release "$UP"; run
check "signed by the pinned key: prints the tarball's hash (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && [ \"\$(cat '$T/out')\" = '$(printf 'b%.0s' {1..64})' ]"
release "$MAL"; run
check "signed by another key: refused (rc $RC)" [ "$RC" = 1 ]
release "$UP"
sed -i "s/^b\{64\}/$(printf 'd%.0s' {1..64})/" "$T/rel/v$V/SHA256SUMS.txt"; run
check "checksums changed after signing: refused (rc $RC)" [ "$RC" = 1 ]
release none; run
check "no signature published: refused (rc $RC)" [ "$RC" = 1 ]
release "$UP"; run "$T/two-keys.asc"
check "key file with a second key: refused (rc $RC)" [ "$RC" = 1 ]
release "$UP" "$(printf 'a%.0s' {1..64})  scrcpy-server-v$V"; run
check "tarball not listed: refused (rc $RC)" [ "$RC" = 1 ]
release "$UP" "$(printf 'b%.0s' {1..64})  scrcpy-linux-x86_64-v$V.tar.gz" "$(printf 'e%.0s' {1..64})  scrcpy-linux-x86_64-v$V.tar.gz"; run
check "tarball listed twice: refused (rc $RC)" [ "$RC" = 1 ]
RC=0; bash "$SCRIPT" "1.2;rm" > "$T/out" 2>&1 || RC=$?
check "a version that is not one: refused (rc $RC)" [ "$RC" = 1 ]

# The repository's key file holds exactly the pinned key.
pinned="$(sed -n 's/^KEY_FPR="\${SCRCPY_KEY_FPR:-\([0-9A-F]\{40\}\)}"$/\1/p' "$SCRIPT")"
gpg --batch --with-colons --show-keys "$ROOT/.github/keys/scrcpy-release-rom1v.asc" 2>/dev/null \
  | awk -F: 'prev == "pub" && $1 == "fpr" {print $10} {prev = $1}' > "$T/out"
check "repository key file = the pinned fingerprint ($pinned)" \
  bash -c "[ -n '$pinned' ] && [ \"\$(cat '$T/out')\" = '$pinned' ]"

# The workflows use it.
python3 - "$ROOT/.github/workflows/scrcpy-pin-sha.yml" "$ROOT/.github/workflows/build.yml" > "$T/out" 2>&1 <<'PY' && RC=0 || RC=$?
import re, sys, yaml
pin, build = (yaml.safe_load(open(p)) for p in sys.argv[1:])
bad = []
run = "\n".join(s.get("run", "") for s in pin["jobs"]["fix-sha"]["steps"])
if "scrcpy-signed-sha.sh" not in run:
    bad.append("scrcpy-pin-sha.yml does not take the hash from scrcpy-signed-sha.sh")
if not re.search(r"git show [^\n]*origin/main:\.github/scripts/scrcpy-signed-sha\.sh", run):
    bad.append("scrcpy-pin-sha.yml does not run main's copy of the script")
if re.search(r"curl[^\n]*\|\s*sha256sum", run):
    bad.append("scrcpy-pin-sha.yml still hashes the download to make the pin")
pins = "\n".join(s.get("run", "") for s in build["jobs"]["pins"]["steps"])
if "scrcpy-signed-sha.sh" not in pins or '"$BASE:.github/scripts/scrcpy-signed-sha.sh"' not in pins:
    bad.append("build.yml's pins job does not check the pin with the base's scrcpy-signed-sha.sh")
cond = str(build["jobs"]["build_push"]["if"])
if "needs.pins.result != 'failure'" not in cond:
    bad.append("build_push still runs when the pin check failed")
print("\n".join(bad) or "workflows OK")
sys.exit(1 if bad else 0)
PY
check "workflows: pin from the signed checksums, checked on every Renovate bump" [ "$RC" = 0 ]

[ "$fails" = 0 ] && echo "scrcpy-signed-sha: all checks passed" || { echo "scrcpy-signed-sha: $fails failed"; exit 1; }
