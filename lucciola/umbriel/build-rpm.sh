#!/usr/bin/env bash
# Build the umbriel and xdg-desktop-portal-umbriel RPMs from their pinned
# commits (the Containerfile's umbriel-rpm stage), into /out. Each archive is
# checked against its sha256 before rpmbuild runs; the specs say the rest.
set -euo pipefail
: "${UMBRIEL_COMMIT:?must be set (the pinned umbriel commit)}"
: "${UMBRIEL_SHA256:?must be set (sha256 of the commit archive)}"
: "${UMBRIEL_PORTAL_COMMIT:?must be set (the pinned xdg-desktop-portal-umbriel commit)}"
: "${UMBRIEL_PORTAL_SHA256:?must be set (sha256 of the commit archive)}"
log() { echo "[umbriel-rpm] $*"; }
TOP=/tmp/rpmbuild
OUT=/out
mkdir -p "$TOP/SOURCES" "$OUT"
dnf5 -y --setopt=install_weak_deps=False install rpm-build

fetch() {  # fetch REPO COMMIT SHA256
  local url="https://github.com/noctalia-dev/$1/archive/$2.tar.gz"
  log "source: $url"
  curl --fail --silent --show-error --location --retry 5 --retry-all-errors --retry-delay 15 \
    -o "$TOP/SOURCES/$2.tar.gz" "$url"
  echo "$3  $TOP/SOURCES/$2.tar.gz" | sha256sum -c -
}

build() {  # build SPEC DEFINES...
  local spec="$1"; shift
  local defines=()
  for d in "$@"; do defines+=(--define "$d"); done
  mapfile -t deps < <(rpmspec -q --buildrequires "${defines[@]}" "$spec")
  dnf5 -y --setopt=install_weak_deps=False install "${deps[@]}"
  rpmbuild -bb --define "_topdir $TOP" "${defines[@]}" \
    --define "_buildhost lucciola-build" \
    --define "source_date_epoch_from_changelog 1" \
    --define "use_source_date_epoch_as_buildtime 1" \
    --define "clamp_mtime_to_source_epoch 1" "$spec"
}

fetch umbriel "$UMBRIEL_COMMIT" "$UMBRIEL_SHA256"
fetch xdg-desktop-portal-umbriel "$UMBRIEL_PORTAL_COMMIT" "$UMBRIEL_PORTAL_SHA256"
cp /src/0001-sdr-transfer-for-staged-sdr-mapping.patch \
   /src/0002-srgb-tagged-like-untagged-under-sdr-mapping.patch "$TOP/SOURCES/"

build /src/umbriel.spec "umbriel_commit $UMBRIEL_COMMIT" "umbriel_short ${UMBRIEL_COMMIT:0:12}"
# the portal requires the umbriel package: install the one just built
dnf5 -y --setopt=install_weak_deps=False install "$TOP"/RPMS/*/umbriel-0.1.0-*.rpm
build /src/xdg-desktop-portal-umbriel.spec "portal_commit $UMBRIEL_PORTAL_COMMIT" \
  "portal_short ${UMBRIEL_PORTAL_COMMIT:0:12}"

shopt -s nullglob
rpms=("$TOP"/RPMS/*/umbriel-0.1.0-*.rpm "$TOP"/RPMS/*/xdg-desktop-portal-umbriel-0.1.0-*.rpm)
rpms=("${rpms[@]/*debug*/}")
mapfile -t rpms < <(printf '%s\n' "${rpms[@]}" | grep -v '^$')
(( ${#rpms[@]} == 2 )) || { echo "ERROR: expected two RPMs, got: ${rpms[*]:-none}" >&2; exit 1; }
cp "${rpms[@]}" "$OUT/"
for r in "${rpms[@]}"; do
  log "built $(basename "$r")"
  rpm -qlp "$r"
done
