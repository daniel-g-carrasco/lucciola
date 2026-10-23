#!/usr/bin/env bash
# Builds the xdg-desktop-portal-luminous RPM from its pinned upstream tag.
# Runs in the Containerfile's luminous-rpm stage, on the same base image as
# Lucciola, so the binary links against the libraries the image will carry.
# The RPM lands in /out; lucciola/build.sh installs it with dnf.
#
# Trust: the tarball is GitHub's archive of the tag, checked against the
# sha256 pinned in the Containerfile before anything reads it; the crates
# come from crates.io at the versions and checksums the tag's Cargo.lock
# pins (cargo --locked refuses any other). Compiler and libraries come from
# Fedora's repositories.
set -euo pipefail
: "${LUMINOUS_VERSION:?must be set (the pinned upstream tag, without the v)}"
: "${LUMINOUS_SHA256:?must be set (sha256 of the tag tarball)}"
log() { echo "[luminous-rpm] $*"; }
V="$LUMINOUS_VERSION"
SPEC=/src/xdg-desktop-portal-luminous.spec
TOP=/tmp/rpmbuild
OUT=/out
URL="https://github.com/waycrate/xdg-desktop-portal-luminous/archive/refs/tags/v${V}.tar.gz"
log "build tools and the spec's BuildRequires"
dnf5 -y --setopt=install_weak_deps=False install rpm-build
mapfile -t deps < <(rpmspec -q --buildrequires --define "luminous_version $V" "$SPEC")
dnf5 -y --setopt=install_weak_deps=False install "${deps[@]}"
log "source: $URL"
mkdir -p "$TOP/SOURCES" "$OUT"
curl --fail --silent --show-error --location --retry 5 --retry-all-errors --retry-delay 15 \
  -o "$TOP/SOURCES/v${V}.tar.gz" "$URL"
echo "${LUMINOUS_SHA256}  $TOP/SOURCES/v${V}.tar.gz" | sha256sum -c -
# Build time and file times from the spec's changelog date, a fixed build
# host, paths remapped (the spec): as close to the same RPM from one build
# to the next as a cargo build gets.
rpmbuild -bb --define "_topdir $TOP" --define "luminous_version $V" \
  --define "_buildhost lucciola-build" \
  --define "source_date_epoch_from_changelog 1" \
  --define "use_source_date_epoch_as_buildtime 1" \
  --define "clamp_mtime_to_source_epoch 1" "$SPEC"
shopt -s nullglob
rpms=("$TOP"/RPMS/*/xdg-desktop-portal-luminous-"$V"-*.rpm)
(( ${#rpms[@]} == 1 )) || { echo "ERROR: expected one xdg-desktop-portal-luminous RPM, got: ${rpms[*]:-none}" >&2; exit 1; }
cp "${rpms[0]}" "$OUT/"
log "built $(basename "${rpms[0]}")"
rpm -qlp "${rpms[0]}"
