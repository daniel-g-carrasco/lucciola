#!/usr/bin/env bash
# Builds the Noctalia Greeter RPM from its pinned upstream tag. Runs in the
# Containerfile's greeter-rpm stage, on the same base image as Lucciola, so
# the RPM links against the libraries the image will carry. The RPM lands in
# /out; lucciola/build.sh installs it with dnf.
#
# Trust: the tarball is GitHub's archive of the tag, checked against the
# sha256 pinned in the Containerfile before anything reads it. Everything
# else (compiler, libraries) comes from Fedora's repositories.
set -euo pipefail

: "${NOCTALIA_GREETER_VERSION:?must be set (the pinned upstream tag, without the v)}"
: "${NOCTALIA_GREETER_SHA256:?must be set (sha256 of the tag tarball)}"
log() { echo "[greeter-rpm] $*"; }

V="$NOCTALIA_GREETER_VERSION"
SPEC=/src/noctalia-greeter.spec
TOP=/tmp/rpmbuild
OUT=/out
URL="https://github.com/noctalia-dev/noctalia-greeter/archive/refs/tags/v${V}.tar.gz"

log "build tools and the spec's BuildRequires"
dnf5 -y --setopt=install_weak_deps=False install rpm-build
mapfile -t deps < <(rpmspec -q --buildrequires --define "greeter_version $V" "$SPEC")
dnf5 -y --setopt=install_weak_deps=False install "${deps[@]}"

log "source: $URL"
mkdir -p "$TOP/SOURCES" "$OUT"
curl --fail --silent --show-error --location --retry 5 --retry-all-errors --retry-delay 15 \
  -o "$TOP/SOURCES/v${V}.tar.gz" "$URL"
echo "${NOCTALIA_GREETER_SHA256}  $TOP/SOURCES/v${V}.tar.gz" | sha256sum -c -
# Lucciola's own sources next to the tarball: the patches and the logo the
# spec installs (Source1, Patch0, Patch1).
cp /src/0001-say-pam-results-in-words.patch /src/0002-start-auth-on-select.patch /src/lucciola-mark.svg "$TOP/SOURCES/"

# The same RPM from one build to the next: build time and file times from
# the spec's changelog date, a fixed build host. Otherwise the package, and
# with it the image layer and the rpmdb, would change at every build.
rpmbuild -bb --define "_topdir $TOP" --define "greeter_version $V" \
  --define "_buildhost lucciola-build" \
  --define "source_date_epoch_from_changelog 1" \
  --define "use_source_date_epoch_as_buildtime 1" \
  --define "clamp_mtime_to_source_epoch 1" "$SPEC"

shopt -s nullglob
rpms=("$TOP"/RPMS/*/noctalia-greeter-"$V"-*.rpm)
(( ${#rpms[@]} == 1 )) || { echo "ERROR: expected one noctalia-greeter RPM, got: ${rpms[*]:-none}" >&2; exit 1; }
cp "${rpms[0]}" "$OUT/"
log "built $(basename "${rpms[0]}")"
rpm -qlp "${rpms[0]}"
