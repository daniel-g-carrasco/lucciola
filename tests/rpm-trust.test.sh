#!/usr/bin/env bash
# Tests for rpm-trust, the one place that decides what a third-party RPM
# repository may bring in, through both of its callers: layer-repo (the
# ujust recipes for Docker CE, Tailscale and VS Code) and the build's
# verify_key_fpr / trust_repo_file (00-common.sh). Keys are generated here
# with gpg, files are file:// URLs, directories are temp ones: no root, no
# network. What must hold (review R2, 2026-10-20): only the pinned primary
# key, with its own subkeys, ever reaches rpm; a key file with any other
# primary key is refused; no section of a repository file can turn
# signature checking off or name another key.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRUST="$ROOT/build_files/system_files/usr/libexec/margine/rpm-trust"
LAYER_REPO="$ROOT/build_files/system_files/usr/libexec/margine/layer-repo"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" 2>/dev/null || true; fails=$((fails+1)); fi
}
absent() { local f; for f; do [ ! -e "$f" ] || return 1; done; }

# --- Keys: the pinned one (with a subkey, as Tailscale's has) and another
export GNUPGHOME="$T/gnupg"; mkdir -m 700 "$GNUPGHOME"
gen() { gpg --batch --quiet --passphrase '' --quick-gen-key "$1" ed25519 sign never 2>/dev/null; }
gen 'Pinned <pinned@test>'
gen 'Other <other@test>'
fpr() { gpg --batch --with-colons --list-keys "$1" 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}'; }
PIN="$(fpr pinned@test)"; OTHER="$(fpr other@test)"
gpg --batch --quiet --passphrase '' --quick-add-key "$PIN" cv25519 encr never 2>/dev/null
gpg --batch --armor --export "$PIN" > "$T/pinned.asc"
gpg --batch --armor --export "$OTHER" > "$T/other.asc"
gpg --batch --export "$OTHER" > "$T/other.bin"
cat "$T/pinned.asc" "$T/other.asc" > "$T/two-blocks.asc"           # appended armored block
gpg --batch --armor --export "$PIN" "$OTHER" > "$T/one-block.asc"    # both in one block
cat "$T/other.asc" "$T/pinned.asc" > "$T/other-first.asc"
{ cat "$T/pinned.asc"; echo "trailing text"; } > "$T/trailing.asc"
cat "$T/pinned.asc" "$T/other.bin" > "$T/binary-tail.asc"            # gpg stops at the armor, rpm would not
echo "not a key" > "$T/garbage.asc"
unset GNUPGHOME

# primaries <file>: the primary fingerprints a fresh gpg reads in <file>;
# subkeys <file>: how many subkeys.
colons() { local h; h="$(mktemp -d)"; gpg --batch --homedir "$h" --show-keys --with-colons "$1" 2>/dev/null; rm -rf "$h"; }
primaries() { colons "$1" | awk -F: '$1 == "pub" {p = 1; next} $1 == "fpr" && p {print $10; p = 0}'; }
subkeys() { colons "$1" | awk -F: '$1 == "sub"' | wc -l; }

key_case() {  # key_case <name> <file> <fingerprint> <want rc>
  local rc=0; rm -f "$T/dest.asc"
  python3 "$TRUST" key "$2" "$T/dest.asc" "$3" > "$T/out" 2>&1 || rc=$?
  check "key: $1 (rc $rc, want $4)" [ "$rc" = "$4" ]
  if [ "$4" = 0 ]; then
    check "key: $1, the result holds the pinned primary only" [ "$(primaries "$T/dest.asc")" = "$PIN" ]
    check "key: $1, the result keeps the pinned key's subkey" [ "$(subkeys "$T/dest.asc")" = 1 ]
  else
    check "key: $1, nothing written" [ ! -e "$T/dest.asc" ]
  fi
}
key_case "the pinned key with its subkey"                "$T/pinned.asc"      "$PIN" 0
key_case "fingerprint in lower case with spaces"         "$T/pinned.asc"      "$(sed -E 's/(....)/\1 /g' <<<"${PIN,,}")" 0
key_case "trailing text after the armor"                 "$T/trailing.asc"    "$PIN" 0
key_case "binary key after the armor (rpm reads both)"   "$T/binary-tail.asc" "$PIN" 0
key_case "pinned key plus a second armored block"        "$T/two-blocks.asc"  "$PIN" 1
key_case "pinned key plus another in the same block"     "$T/one-block.asc"   "$PIN" 1
key_case "another key first, the pinned one second"      "$T/other-first.asc" "$PIN" 1
key_case "a different key"                               "$T/other.asc"       "$PIN" 1
key_case "not a key"                                     "$T/garbage.asc"     "$PIN" 1
key_case "a short key id instead of a fingerprint"       "$T/pinned.asc"      "${PIN: -16}" 1
python3 "$TRUST" key "$T/other.asc" "$T/dest.asc" "$PIN" > "$T/out" 2>&1 || true
check "key: a different key is a fingerprint mismatch, refusing" grep -q "fingerprint mismatch.*refusing" "$T/out"
check "fingerprint: the pinned key file prints its one primary" [ "$(python3 "$TRUST" fingerprint "$T/pinned.asc")" = "$PIN" ]
python3 "$TRUST" fingerprint "$T/two-blocks.asc" > "$T/out" 2>&1 && rc=0 || rc=$?
check "fingerprint: a file with two primaries is refused" [ "$rc" = 1 ]

# --- Repository files
K=/etc/pki/rpm-gpg/RPM-GPG-KEY-test
cat > "$T/good.repo" <<'R'
# like Docker's: several sections, gpgkey by URL
[stable]
name=Stable - $basearch
baseurl=https://example.org/$releasever/$basearch/stable
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://example.org/gpg

[test]
name=Test
baseurl=https://example.org/$releasever/$basearch/test
  https://mirror.example.org/test
enabled=0
gpgkey=https://example.org/gpg
  https://elsewhere.example.org/other-key
R
repo_case() {  # repo_case <name> <want rc>  (repo text on stdin)
  local rc=0; cat > "$T/in.repo"; rm -f "$T/dest.repo"
  python3 "$TRUST" repo "$T/in.repo" "$T/dest.repo" "$K" > "$T/out" 2>&1 || rc=$?
  check "repo: $1 (rc $rc, want $2)" [ "$rc" = "$2" ]
  [ "$2" = 0 ] || check "repo: $1, nothing written" [ ! -e "$T/dest.repo" ]
}
repo_case "Docker-like file, two sections" 0 < "$T/good.repo"
# What dnf would read: section by section.
section() { awk -v s="[$1]" '$0 == s {p = 1; next} /^\[/ {p = 0} p' "$T/dest.repo"; }
check "repo: every section gets gpgcheck=1" \
  [ "$(section stable | grep -c '^gpgcheck=1$')$(section test | grep -c '^gpgcheck=1$')" = 11 ]
check "repo: every gpgkey is the local key, and only it" \
  [ "$(grep '^gpgkey' "$T/dest.repo" | sort | tr '\n' ' ')" = "gpgkey=file://$K gpgkey=file://$K " ]
check "repo: no URL of a key survives" bash -c "! grep -q 'example.org/gpg\|other-key' '$T/dest.repo'"
check "repo: repo_gpgcheck=1 is kept" bash -c "awk -v s='[stable]' '\$0==s{p=1;next} /^\[/{p=0} p' '$T/dest.repo' | grep -qx repo_gpgcheck=1"
check "repo: a URL list stays one baseurl line" \
  grep -qx 'baseurl=https://example.org/$releasever/$basearch/test https://mirror.example.org/test' "$T/dest.repo"
check "repo: no indented line dnf could read as a continuation" bash -c "! grep -q '^[[:space:]]' '$T/dest.repo'"

repo_case "gpgcheck=0 in the second section" 1 <<'R'
[a]
baseurl=https://example.org/a
gpgcheck=1
[b]
baseurl=https://example.org/b
gpgcheck=0
R
repo_case "pkg_gpgcheck=false (dnf5's name)" 1 <<'R'
[a]
baseurl=https://example.org/a
pkg_gpgcheck=false
R
repo_case "GPGCHECK=no in capitals" 1 <<'R'
[a]
baseurl=https://example.org/a
GPGCHECK=no
R
repo_case "sslverify=0" 1 <<'R'
[a]
baseurl=https://example.org/a
sslverify=0
R
repo_case "gpgcheck set twice in one section" 1 <<'R'
[a]
baseurl=https://example.org/a
gpgcheck=1
gpgcheck=0
R
repo_case "the same section twice" 1 <<'R'
[a]
baseurl=https://example.org/a
[a]
gpgcheck=0
R
repo_case "gpgcheck=maybe" 1 <<'R'
[a]
baseurl=https://example.org/a
gpgcheck=maybe
R
repo_case "no section at all" 1 <<'R'
gpgcheck=0
R
repo_case "an empty file" 1 < /dev/null
repo_case "gpgcheck=0 hidden as a continuation of baseurl" 0 <<'R'
[a]
baseurl=https://example.org/a
 gpgcheck=0
R
check "repo: ...and it stays inside the baseurl value, gpgcheck=1 rules" \
  [ "$(grep '^gpgcheck=' "$T/dest.repo")" = gpgcheck=1 ]

# --- layer-repo, the ujust recipes' path
mkdir -p "$T/repos" "$T/keys"
lr() {  # lr <name> <repo file> <key file> ; sets RC
  RC=0
  env MARGINE_REPO_DIR="$T/repos" MARGINE_KEY_DIR="$T/keys" \
    bash "$LAYER_REPO" "$1" "file://$2" "file://$3" "$PIN" > "$T/out" 2>&1 || RC=$?
}
lr good "$T/good.repo" "$T/pinned.asc"
check "layer-repo: a good key and repository are added" [ "$RC" = 0 ]
check "layer-repo: the saved key is the pinned one alone" [ "$(primaries "$T/keys/RPM-GPG-KEY-good")" = "$PIN" ]
check "layer-repo: the repository names the saved key in every section" \
  [ "$(grep -c "^gpgkey=file://$T/keys/RPM-GPG-KEY-good$" "$T/repos/good.repo")" = 2 ]
lr bundle "$T/good.repo" "$T/two-blocks.asc"
check "layer-repo: a key file with a second primary is refused" [ "$RC" = 1 ]
check "layer-repo: ...nothing installed" absent "$T/keys/RPM-GPG-KEY-bundle" "$T/repos/bundle.repo"
check "layer-repo: ...and it says refusing (layer-resolve.sh reads it)" grep -q refusing "$T/out"
printf '[a]\nbaseurl=https://example.org/a\ngpgcheck=1\n[b]\nbaseurl=https://example.org/b\ngpgcheck=0\n' > "$T/off.repo"
lr off "$T/off.repo" "$T/pinned.asc"
check "layer-repo: a repository with gpgcheck=0 in a section is refused" [ "$RC" = 1 ]
check "layer-repo: ...nothing installed, not even the key" absent "$T/keys/RPM-GPG-KEY-off" "$T/repos/off.repo"

# --- The build's helpers (00-common.sh), as custom-kernel and 15-devstack call them
build() {  # build <bash code> ; sets RC
  RC=0
  mkdir -p "$T/build-gnupg"; chmod 700 "$T/build-gnupg"
  env SOURCE_DATE_EPOCH=1 FEDORA_VER=45 GNUPGHOME="$T/build-gnupg" bash -c ". '$ROOT/build_files/00-common.sh'; $1" > "$T/out" 2>&1 || RC=$?
}
cp "$T/two-blocks.asc" "$T/build.asc"
build "verify_key_fpr '$T/build.asc' $PIN test"
check "build: verify_key_fpr refuses a second primary" [ "$RC" = 1 ]
cp "$T/binary-tail.asc" "$T/build.asc"
build "verify_key_fpr '$T/build.asc' $PIN test"
check "build: verify_key_fpr accepts the pinned key" [ "$RC" = 0 ]
check "build: ...and rewrites the file to it alone, for rpm --import" \
  [ "$(primaries "$T/build.asc")" = "$PIN" ]
check "build: ...the binary tail rpm would have read is gone" \
  [ "$(wc -c < "$T/build.asc")" -lt "$(wc -c < "$T/binary-tail.asc")" ]
build "trust_repo_file '$T/off.repo' '$T/build.repo' /etc/pki/rpm-gpg/k"
check "build: trust_repo_file refuses gpgcheck=0" [ "$RC" = 1 ]
check "build: ...nothing written" absent "$T/build.repo"

if (( fails )); then echo "$fails rpm-trust case(s) failed"; exit 1; fi
echo "all rpm-trust cases passed"
