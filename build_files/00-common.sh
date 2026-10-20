#!/usr/bin/env bash
# Margine image build — common helpers and environment.
# Sourced by every NN-<area>/install.sh script.
#
# Split out of the monolithic build.sh on 2026-06-06 (audit §8 rec #22).
# The orchestrator at build.sh just dispatches to /ctx/[1-9][0-9]-*/
# install.sh in lexicographic order; each script sources this file.

set -euo pipefail

log() { printf '[margine-build] %s\n' "$*"; }
err() { printf '[margine-build] ERROR: %s\n' "$*" >&2; }

# retry_curl <url> <output_path> — fetch with the same brownout-tolerance
# the kernel-cachyos COPR install uses. Branding asset pulls from
# raw.githubusercontent.com can fail transiently (5xx, DNS blip,
# GitHub Pages cold-start); without retry a single hiccup costs us a
# 25-min rebuild near the end. 5 attempts, 30-150s exponential backoff.
retry_curl() {
  local url="$1" out="$2"
  local attempt=1 max=5
  while :; do
    if curl --fail --silent --show-error -L "$url" -o "$out"; then
      return 0
    fi
    if (( attempt >= max )); then
      log "retry_curl FAILED after $max attempts: $url"
      return 1
    fi
    local backoff=$(( attempt * 30 ))
    log "retry_curl attempt $attempt failed for $url; sleeping ${backoff}s"
    sleep $backoff
    attempt=$(( attempt + 1 ))
  done
}

# retry_curl_strict <url> <output_path> — same retry behaviour as
# retry_curl, but ABORTS the build if the asset is missing or empty
# after all attempts. Use only for assets without which the image is
# broken at first boot (welcome screen logo, About-panel logo). Silent
# failure of these has shipped to user-visible regressions twice
# (2026-06-04 welcome page dinosaur, 2026-06-06 logo absent), so
# fail-loud is the right default here even if it means a build retry.
retry_curl_strict() {
  local url="$1" out="$2"
  if ! retry_curl "$url" "$out"; then
    log "FATAL: required asset fetch failed: $url"
    return 1
  fi
  if [[ ! -s "$out" ]]; then
    log "FATAL: required asset is empty after fetch: $out (url=$url)"
    return 1
  fi
  return 0
}

# retry <max-attempts> <base-backoff-seconds> <cmd...> — generic outer
# retry with linear backoff (30, 60, 90... for base=30). Deduplicates
# the three hand-copied dnf retry loops custom-kernel carried (review
# P3). For dnf installs that should clean metadata between attempts,
# wrap the command in `bash -c`.
retry() {
  local max=$1 base=$2 n=1
  shift 2
  while ! "$@"; do
    if (( n >= max )); then
      log "retry FAILED after ${max} attempts: $*"
      return 1
    fi
    log "retry: attempt ${n} failed; sleeping $(( n * base ))s: $*"
    sleep $(( n * base ))
    n=$(( n + 1 ))
  done
  return 0
}

# NOTE on trap-based cleanup in build scripts: deliberately ABSENT.
# A failed RUN discards the whole container layer, so half-restored
# state (moved kernel hooks, remounted /proc/sys, tmpdirs) can never
# ship. Documented once here so it stops being re-litigated at every
# review.

# Cached, exported globals used across sections. Defined here once so
# every sub-script gets the same value without recomputing.
export FEDORA_VER="${FEDORA_VER:-$(rpm -E %fedora 2>/dev/null || echo 44)}"
export BUILD_DATE="${BUILD_DATE:-$(date -u +%Y%m%d)}"

# SOURCE_DATE_EPOCH for every build step (2026-10-03). rpm >= 4.18 writes
# it, instead of the wall clock, as the install time of each package it
# installs, so the rpmdb stops differing between two builds of the same
# content (it was a layer of its own, 40 MiB, on every update). The value
# is the newest install time already in the rpmdb: on the first step
# that is the base image's, and every later step finds the same number
# (our own installs carry it), so it moves only when the base does.
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH="$(rpm -qa --qf '%{INSTALLTIME}\n' 2>/dev/null | sort -n | tail -n1)"
  [[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] && export SOURCE_DATE_EPOCH || unset SOURCE_DATE_EPOCH
fi

# --- Third-party signing keys: verify fingerprints before trusting a repo --
# Moved here from custom-kernel/install.sh (2026-08-25) so 15-devstack can
# pin the Docker and Microsoft repo keys the same way. The RPMFusion and
# NVIDIA constants stay in custom-kernel, the Docker/VS Code ones in
# 15-devstack: each script owns the fingerprints it consumes.
# gpg and python3 come from the base image; nothing to install at build time.
#
# The rules live in one place, rpm-trust (system_files, shipped as
# /usr/libexec/margine/rpm-trust for layer-repo; here read from /ctx before
# system_files is copied, like margine-seed-etc-passwd). Until 2026-10-20
# this file compared only the FIRST fingerprint gpg printed and then let rpm
# import the whole file, and rpm imports every key in it: a key file with
# the pinned key first and another one after it passed (review R2).
RPM_TRUST="${RPM_TRUST:-$(dirname "${BASH_SOURCE[0]}")/system_files/usr/libexec/margine/rpm-trust}"

# verify_key_fpr <file> <fingerprint> <label>
# Refuses unless <file> holds exactly one primary key, <fingerprint>, and
# rewrites <file> in place with that certificate alone (its own subkeys
# included), so the `rpm --import` and gpgkey=file:// that follow can only
# ever see the pinned key.
verify_key_fpr() {
  local file="$1" expected="$2" label="$3"
  if [[ ! -f "$file" ]]; then
    err "$label: expected key file $file, not found"
    return 1
  fi
  if ! python3 "$RPM_TRUST" key "$file" "$file" "$expected"; then
    err "$label: GPG key refused, refusing to build"
    return 1
  fi
  log "$label: key fingerprint verified, pinned key only ($expected)"
  return 0
}

# trust_repo_file <src> <dest> <keyfile>
# For a repository file the build did not write itself (downloaded, or
# dropped by a *-release RPM): refuses one that turns signature checking off
# in any section, and writes <dest> with gpgcheck=1 and gpgkey=file://<keyfile>
# in every section, so dnf can import no key but the verified one.
trust_repo_file() {
  local src="$1" dest="$2" keyfile="$3"
  if ! python3 "$RPM_TRUST" repo "$src" "$dest" "$keyfile"; then
    err "repository file $src refused, refusing to build"
    return 1
  fi
  log "repository file $dest: signature checking on, key $keyfile"
}

# Verifies the key files a rpmfusion-<flavor>-release RPM just dropped in
# /etc/pki/rpm-gpg, and the repository files it dropped next to them.
# Called BEFORE any package is pulled from those repos, which is the only
# moment the check is worth anything.
verify_rpmfusion_keys() {
  local ver flavor fprvar key repo rc=0
  ver="$(rpm -E %fedora)"
  for flavor in "$@"; do
    fprvar="RPMFUSION_${flavor^^}_FPR"
    key="/etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion-${flavor}-fedora-${ver}"
    verify_key_fpr "$key" "${!fprvar}" "rpmfusion-${flavor}" || { rc=1; continue; }
    for repo in /etc/yum.repos.d/rpmfusion-"${flavor}"*.repo; do
      [[ -f "$repo" ]] || { err "rpmfusion-${flavor}: no repository file"; rc=1; break; }
      trust_repo_file "$repo" "$repo" "$key" || rc=1
    done
  done
  return $rc
}

# --- A Fedora build pinned by version: the repositories, then Koji --------
# A build pinned to its version-release (kernel-devel of the base's kernel
# for the kernel reserve, Lucciola's Noctalia) does not stay in the
# repositories: a branched release keeps no superseded build, updates keeps
# only the newest, and the updates-testing a pre-release enables is gone the
# day the release is out (noctalia 5.3.0-1 sat only there in Fedora 45 on
# 2026-10-17). Koji keeps every build, and for one that went through Bodhi
# a copy signed with the release key, at
#   packages/<build>/<version>/<release>/data/signed/<keyid>/<arch>/<nvra>.rpm
# where <keyid> is the fingerprint's last 8 digits, in lower case. dnf does
# not check the signature of a local file, so these helpers check it with
# rpmkeys before dnf sees the file, and insist on Fedora's release key: the
# rpmdb also holds COPR and third-party keys, which rpmkeys would accept
# just the same. Shared by custom-kernel (install_fedora_kernel_devel) and
# lucciola/build.sh since 2026-10-20.

# fedora_release_key
# Prints the path of Fedora's release key for FEDORA_VER. fedora-gpg-keys
# puts it in /usr/share/pki/rpm-gpg (Silverblue and fedora:45 alike); older
# layouts had it in /etc/pki/rpm-gpg. MARGINE_RPM_GPG_DIRS (tests) overrides
# the places looked at.
fedora_release_key() {
  local dirs d
  read -ra dirs <<<"${MARGINE_RPM_GPG_DIRS:-/usr/share/pki/rpm-gpg /etc/pki/rpm-gpg}"
  for d in "${dirs[@]}"; do
    if [[ -s "$d/RPM-GPG-KEY-fedora-${FEDORA_VER}-primary" ]]; then
      printf '%s\n' "$d/RPM-GPG-KEY-fedora-${FEDORA_VER}-primary"
      return 0
    fi
  done
  err "no Fedora ${FEDORA_VER} release key in the image (looked in: ${dirs[*]})"
  return 1
}

# fedora_release_keyid
# The key id Koji files the signed copies under, and rpmkeys -v names: the
# release key's fingerprint, last 8 digits, lower case.
fedora_release_keyid() {
  local keyfile fpr
  keyfile="$(fedora_release_key)" || return 1
  fpr="$(python3 "$RPM_TRUST" fingerprint "$keyfile")" || { err "rpm-trust could not read $keyfile"; return 1; }
  [[ "$fpr" =~ ^[0-9A-F]{40}$ ]] || { err "unreadable fingerprint for $keyfile"; return 1; }
  fpr="${fpr,,}"
  printf '%s\n' "${fpr: -8}"
}

# verify_fedora_signature <file.rpm>...
# rpmkeys --checksig every file, and refuse it unless digests and signature
# are OK and the signer is the release key: the verbose report names the
# key, "key fingerprint: <40 hex>: OK" (rpm 6) or "key ID <8 hex>: OK"
# (rpm 4), both ending in the key id. The first file that fails stops it.
verify_fedora_signature() {
  local keyfile keyid f out report
  keyfile="$(fedora_release_key)" || return 1
  keyid="$(fedora_release_keyid)" || return 1
  rpmkeys --import "$keyfile" || true   # already in the rpmdb on a Fedora base
  for f in "$@"; do
    out="$(rpmkeys --checksig "$f" 2>&1)" || true
    [[ "$out" == *"signatures OK"* ]] \
      || { err "$(basename "$f") does not carry a valid Fedora ${FEDORA_VER} signature: $out"; return 1; }
    report="$(rpmkeys --checksig -v "$f" 2>&1)" || true
    if ! grep -Eq "ignature, key (fingerprint|ID):? ?[0-9a-f]*${keyid}: OK" <<<"$report"; then
      err "$(basename "$f") is signed, but not by Fedora ${FEDORA_VER}'s release key (${keyid}):"
      printf '%s\n' "$report" | sed 's/^/    /' >&2
      return 1
    fi
    log "  $out (Fedora ${FEDORA_VER} release key ${keyid})"
  done
}

# fetch_signed_rpm <name> <version-release> <arch> <destdir> [<build>]
# Downloads Koji's copy of <name>-<version-release>.<arch>.rpm signed with
# Fedora's release key into <destdir> and verifies it (above). <build> is
# the source package when it is not <name>: kernel-devel comes from kernel.
# The epoch is never part of a Koji path or a file name. A 404 is an answer,
# not a hiccup (no such build, or no signed copy: only builds that went
# through Bodhi have one), so it fails at once, naming the URL, instead of
# retrying for minutes; any other trouble gets retry_curl's five attempts.
fetch_signed_rpm() {
  local name="$1" vr="$2" arch="$3" dir="$4" build="${5:-$1}" keyid url out code
  [[ "$vr" =~ ^[^-]+-[^-]+$ ]] || { err "fetch_signed_rpm: '$vr' is not <version>-<release>"; return 1; }
  keyid="$(fedora_release_keyid)" || return 1
  url="https://kojipkgs.fedoraproject.org/packages/${build}/${vr%-*}/${vr#*-}/data/signed/${keyid}/${arch}/${name}-${vr}.${arch}.rpm"
  out="${dir}/${name}-${vr}.${arch}.rpm"
  mkdir -p "$dir"
  code="$(curl --silent --show-error -L --head -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" || code=""
  if [[ "$code" == 404 ]]; then
    err "Koji has no signed ${name}-${vr}.${arch} (HTTP 404): ${url}"
    err "  either the build ${build}-${vr} does not exist, or it never went through Bodhi and has no copy signed with Fedora ${FEDORA_VER}'s key ${keyid}"
    return 1
  fi
  log "fetching ${name}-${vr}.${arch} from Koji: ${url}"
  retry_curl_strict "$url" "$out" || return 1
  verify_fedora_signature "$out"
}

# dnf_install_pinned <name> <version-release> <arch> [<dnf5 install argument>...]
# One dnf5 transaction that installs exactly <name>-<version-release>
# together with whatever else is given (other packages, --setopt=...
# options): from the repositories when they still have that build,
# otherwise Koji's signed copy, verified, as a local file in the same
# transaction. Says which. The question is asked on fresh metadata
# (--refresh): a stale yes would send dnf after a file the mirrors no
# longer have, and the install fails where Koji would have done.
dnf_install_pinned() {
  local name="$1" vr="$2" arch="$3" have dir rc=0
  shift 3
  if ! have="$(dnf5 -q --refresh repoquery --qf '%{version}-%{release}.%{arch}\n' "$name")"; then
    err "dnf5 repoquery ${name} failed: cannot tell whether the repositories have ${name}-${vr}"
    return 1
  fi
  if grep -qxF -- "${vr}.${arch}" <<<"$have"; then
    log "${name}-${vr}.${arch}: the repositories have it, installing from there"
    dnf5 -y install "$@" "${name}-${vr}" || { err "dnf5 install of ${name}-${vr} from the repositories failed"; return 1; }
    return 0
  fi
  log "${name}-${vr}.${arch} is not in the repositories (they have: $(tr '\n' ' ' <<<"${have:-nothing}" | sed 's/ $//')): fetching Fedora's signed build from Koji"
  dir="$(mktemp -d)"
  if ! fetch_signed_rpm "$name" "$vr" "$arch" "$dir"; then
    rm -rf "$dir"
    err "${name}-${vr}.${arch} is in neither the repositories nor Koji's signed copies: nothing to install"
    return 1
  fi
  dnf5 -y install "$@" "${dir}/${name}-${vr}.${arch}.rpm" || rc=$?
  rm -rf "$dir"
  (( rc == 0 )) || err "dnf5 install of Koji's ${name}-${vr}.${arch} failed (rc ${rc})"
  return "$rc"
}

# regenerate_initramfs <kver>
# Write /usr/lib/modules/<kver>/initramfs.img so that the same packages give
# the same bytes whatever the build date (2026-10-16). Every daily update used
# to re-download the whole 297 MB initramfs layer although its files were
# identical day to day: only timestamps differed (the kernel modules are
# re-signed on every build, so they carry the build time) and the build date
# in initrd-release, which dracut copies from os-release's PRETTY_NAME.
#   - --reproducible with SOURCE_DATE_EPOCH = the kernel package's build time
#     clamps every timestamp dracut would take from the build
#   - os-release is handed to dracut without the "(YYYYMMDD)" in PRETTY_NAME
#     and restored right after; the installed system keeps the dated name
regenerate_initramfs() {
  local kver="$1" dir="/usr/lib/modules/$1" osr=/usr/lib/os-release epoch saved rc=0
  command -v zstd >/dev/null || { err "zstd missing: dracut would silently gzip the initramfs"; return 1; }
  epoch=$(rpm -qf --qf '%{BUILDTIME}\n' "$dir/vmlinuz" | head -n1)
  [[ "$epoch" =~ ^[0-9]+$ ]] || { err "no build time for the package owning $dir/vmlinuz"; return 1; }
  saved=$(mktemp)
  cp -p "$osr" "$saved"
  sed -i -E 's/^(PRETTY_NAME=".*) \([0-9]{8}\)"$/\1"/' "$osr"
  DRACUT_NO_XATTR=1 SOURCE_DATE_EPOCH="$epoch" dracut --force --zstd --reproducible \
      --no-hostonly --no-hostonly-cmdline --add ostree --kver "$kver" \
      "$dir/initramfs.img" || rc=$?
  cp -p "$saved" "$osr"
  rm -f "$saved"
  return "$rc"
}
