#!/usr/bin/env bash
# scrcpy-signed-sha.sh <version>
# Prints the sha256 of scrcpy-linux-x86_64-v<version>.tar.gz as upstream
# published it in the release's SHA256SUMS.txt, after checking that file's
# OpenPGP signature (SHA256SUMS.txt.asc) against the scrcpy maintainer's key
# pinned in this repository (review N2, 2026-10-20).
#
# Until then scrcpy-pin-sha.yml hashed whatever the release URL served and
# committed that as SCRCPY_SHA256, and Renovate automerged it: the pin
# proved only that the bytes did not change after the bot saw them. A
# release made with a stolen GitHub account would have been pinned, built
# (as root, in the image build) and shipped by automation alone. The
# signature is made with a key that does not live on GitHub, so the account
# alone cannot produce it.
#
# The key: Romain Vimont (rom1v, scrcpy's author), primary key
# 456958E85A185DD5C2D1E4E80C822B298461FA03, signing subkey
# E39E2DE6A55F5AA6D8EFB79ACA01F46F18683B3D (the one the v5.0.1 sums are
# signed with). Checked on 2026-10-20 in three places that agree: the key
# on keys.openpgp.org (email-verified), on keyserver.ubuntu.com, and the
# keys of github.com/rom1v. Copy in .github/keys/scrcpy-release-rom1v.asc.
# A new key fails here on purpose: check it by hand the same way, then
# replace the file and the fingerprint together.
#
# SCRCPY_KEY_FILE, SCRCPY_KEY_FPR and SCRCPY_RELEASE_BASE (any URL curl
# reads, file:// included) are for tests.
set -euo pipefail

die() { printf 'scrcpy-signed-sha: %s\n' "$*" >&2; exit 1; }

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || die "usage: scrcpy-signed-sha.sh <version> (got '$VERSION')"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_FILE="${SCRCPY_KEY_FILE:-$HERE/../keys/scrcpy-release-rom1v.asc}"
KEY_FPR="${SCRCPY_KEY_FPR:-456958E85A185DD5C2D1E4E80C822B298461FA03}"
BASE="${SCRCPY_RELEASE_BASE:-https://github.com/Genymobile/scrcpy/releases/download}"
NAME="scrcpy-linux-x86_64-v${VERSION}.tar.gz"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GNUPGHOME="$T/gnupg"
mkdir -m 0700 "$GNUPGHOME"

# The key file holds the pinned primary key and no other.
[[ -f "$KEY_FILE" ]] || die "no key file $KEY_FILE"
primaries="$(gpg --batch --with-colons --show-keys "$KEY_FILE" 2>/dev/null \
             | awk -F: 'prev == "pub" && $1 == "fpr" {print $10} {prev = $1}')"
[[ "$primaries" == "$KEY_FPR" ]] || die "$KEY_FILE must hold exactly the key $KEY_FPR (it holds: ${primaries//$'\n'/ })"
gpg --batch --quiet --import "$KEY_FILE" 2>/dev/null || die "cannot import $KEY_FILE"

for f in SHA256SUMS.txt SHA256SUMS.txt.asc; do
  curl -fsSL --retry 3 --retry-delay 5 -o "$T/$f" "$BASE/v${VERSION}/$f" \
    || die "cannot download $f of v${VERSION} (no signed checksums for this release?)"
done

# GOODSIG: a good signature by a key in the keyring that is neither expired
# nor revoked; VALIDSIG's last field: the primary key it belongs to.
status="$(gpg --batch --status-fd 1 --verify "$T/SHA256SUMS.txt.asc" "$T/SHA256SUMS.txt" 2>/dev/null || true)"
grep -q '^\[GNUPG:\] GOODSIG ' <<<"$status" || die "SHA256SUMS.txt of v${VERSION}: no good signature by $KEY_FPR"
grep -qE "^\[GNUPG:\] VALIDSIG .* ${KEY_FPR}\$" <<<"$status" \
  || die "SHA256SUMS.txt of v${VERSION}: signed, but not by the pinned key $KEY_FPR"

mapfile -t hits < <(awk -v n="$NAME" '$2 == n || $2 == "*" n {print $1}' "$T/SHA256SUMS.txt")
(( ${#hits[@]} == 1 )) || die "SHA256SUMS.txt of v${VERSION} lists $NAME ${#hits[@]} times"
[[ "${hits[0]}" =~ ^[0-9a-f]{64}$ ]] || die "SHA256SUMS.txt of v${VERSION}: '${hits[0]}' is not a sha256"
printf '%s\n' "${hits[0]}"
