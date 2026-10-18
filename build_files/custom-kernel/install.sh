#!/bin/bash
#
# Install the CachyOS kernel from COPR (bieszczaders/kernel-cachyos),
# sign the vmlinuz and modules with the Margine MOK, build v4l2loopback
# against it, and create a one-shot systemd unit that imports the MOK
# certificate on first boot.
#
# Inspired by Origami Linux's modules/custom-kernel/custom-kernel.sh
# (https://gitlab.com/origami-linux/images), simplified for Margine:
#   - only the kernel-cachyos (mainline) variant — no LTS/RT/LTO choice
#     (Margine's :lts flavour, issue #382, and its :nvidia variant, ADR
#     0009, were not carried over to Lucciola)
#   - signing is mandatory: this image is meant to boot under Secure Boot
#
# Inputs (BuildKit secrets):
#   /run/margine-certs/MOK.key        — RSA private key (PEM)
#   /run/margine-certs/MOK.pem        — X509 certificate (PEM)
# (The mokutil enrollment passphrase is public by design and lives as
#  a constant below — see the MOK_PASSWORD comment.)
#
set -euo pipefail

# Shared helpers (retry, retry_curl, FEDORA_VER, ...). log/err are
# re-defined right after to keep this script's [custom-kernel] prefix.
. /ctx/00-common.sh

log() { printf '[custom-kernel] %s\n' "$*"; }
err() { printf '[custom-kernel] ERROR: %s\n' "$*" >&2; }

# NOT under /tmp: the same RUN mounts a tmpfs on /tmp, and with
# --layers=false buildah orders that mount after the secrets, so a
# secret at /tmp/certs is masked by the empty tmpfs and the build dies
# with "Missing secret" (2026-08-18).
SIGNING_KEY="/run/margine-certs/MOK.key"
SIGNING_CERT="/run/margine-certs/MOK.pem"

for f in "$SIGNING_KEY" "$SIGNING_CERT"; do
  [[ -f "$f" ]] || { err "Missing secret: $f"; exit 1; }
done

# --- Third-party signing keys: pin the fingerprints ----------------------
# This build bootstraps third-party repos from a URL, RPMFusion for one (a
# release RPM installed straight from download1.rpmfusion.org). The thing
# we fetch carries the very key that will then judge everything that repo
# serves, which makes the signature check circular: whoever can swap the
# package or the repo file can swap the key along with it, and dnf -y
# imports it without a word. HTTPS proves we reached the host we asked
# for; it proves nothing about what that host is currently serving.
#
# So pin the fingerprints and refuse to build when what lands on disk is
# not what we expect. Borrowed from OpenGamingCollective, who hardened the
# same shape of trust in their kernel build (upstream review 2026-08,
# issue #333): fetch the key from the authoritative place, then confirm
# the fingerprint instead of assuming it.
#
# Verified 2026-08-21 against rpmfusion-free-release-44 and the
# fingerprints published on https://rpmfusion.org/keys. These rotate
# rarely; when they do, this fails loudly and the new fingerprint must be
# checked by hand before it is written here. That is the intended
# behaviour: a silent key change is exactly what this exists to catch.
# Only RPMFusion free is used now (v4l2loopback's akmod); the nonfree
# fingerprint left with the gaming closure on 2026-10-18.
# shellcheck disable=SC2034  # read indirectly as ${!fprvar} in verify_rpmfusion_keys
RPMFUSION_FREE_FPR="E9A491A3DE247814E7E067EAE06F8ECDD651FF2E"

# negativo17 "fedora-multimedia": where gstreamer1-plugins-bad and -ugly come
# from. Verified 2026-08-25 against https://negativo17.org/repos/RPM-GPG-KEY-slaanesh
# (first key in the file; the second is its companion).
# shellcheck disable=SC2034
NEGATIVO17_FPR="0C5D0F470484AE2FC40A9B6597F3008993E8909B"

# key_fingerprint / verify_key_fpr / verify_rpmfusion_keys now live in
# 00-common.sh, shared with 15-devstack (2026-08-25).

# The MOK *enrollment passphrase* is PUBLIC BY DESIGN: every installer
# must type it into MokManager, the live-ISO Secure Boot dialog prints
# it, and the install docs spell it out. Only the signing KEY above is
# secret. Until 2026-06-12 this value was plumbed through GHA secrets +
# a BuildKit secret mount — implying a confidentiality that never
# existed (the unit below ships world-readable in the image anyway) and
# inviting a pointless "rotation" that would only break the docs.
# Keep it a simple constant; if it ever changes, update the live-ISO
# dialog (live-env/src/build.sh) and the install docs together.
# LETTERS ONLY, no hyphen, no symbols (2026-08-20, issue #353).
# MokManager runs in the firmware, before any keyboard layout exists, so
# it assumes US. On an Italian keyboard the key printed "-" sends "/";
# German and French shift other symbols around too. The user types this
# blind, at a blue screen that already unnerves people, and gets a
# rejection they cannot explain. It buys no security either — the value
# is public by design (see below) — so there is nothing to weigh
# against typability. ublue-os reached the same conclusion:
# "universalblue", letters only.
MOK_PASSWORD="margine"

# Validate that key and cert match.
openssl pkey -in "$SIGNING_KEY"  -noout >/dev/null \
  || { err "MOK.key is not a valid private key"; exit 1; }
openssl x509 -in "$SIGNING_CERT" -noout >/dev/null \
  || { err "MOK.pem is not a valid X509 cert"; exit 1; }
_tmp1=$(mktemp); _tmp2=$(mktemp)
openssl pkey -in "$SIGNING_KEY"  -pubout        >"$_tmp1"
openssl x509 -in "$SIGNING_CERT" -pubkey -noout >"$_tmp2"
cmp -s "$_tmp1" "$_tmp2" \
  || { rm -f "$_tmp1" "$_tmp2"; err "MOK.key and MOK.pem don't match"; exit 1; }
rm -f "$_tmp1" "$_tmp2"

COPR_REPO="bieszczaders/kernel-cachyos"
# COPR signing keys, pinned by fingerprint like RPMFusion and negativo17. Read
# from https://download.copr.fedorainfracloud.org/results/<owner>/<project>/pubkey.gpg
# on 2026-08-30.
COPR_CACHYOS_FPR="537DEED33436B0367F5B26D5B3E3132CF10859CF"
COPR_ADDONS_FPR="A98571785D3845AEF14B16B1CDD249F6F4033A98"

# copr_enable_direct <owner/project> <fingerprint>
# Writes the repo file `dnf copr enable` would write, without talking to
# the COPR API. The API (copr.fedorainfracloud.org/api_3/rpmrepo/...) is
# the fragile half of COPR: on 2026-08-30 it timed out for hours (curl 28,
# five attempts each) and killed three builds in a row, while the download
# backend answered in under a second. Packages, metadata and the signing
# key all live on the backend, so the API is not needed at all. Same repo
# id as dnf's, so --enablerepo/--disablerepo and the scrub globs still work.
copr_enable_direct() {
  local project="$1" fpr="$2"
  local owner="${project%%/*}" name="${project##*/}"
  local base="https://download.copr.fedorainfracloud.org/results/${owner}/${name}"
  local key="/run/copr-${name}.gpg"
  local repo="/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:${owner}:${name}.repo"
  retry_curl_strict "${base}/pubkey.gpg" "$key" || return 1
  verify_key_fpr "$key" "$fpr" "copr ${project}" || return 1
  rpm --import "$key"
  cat > "$repo" <<REPOEOF
[copr:copr.fedorainfracloud.org:${owner}:${name}]
name=Copr repo for ${name} owned by ${owner}
baseurl=${base}/fedora-\$releasever-\$basearch/
type=rpm-md
skip_if_unavailable=False
gpgcheck=1
gpgkey=file://${key}
repo_gpgcheck=0
enabled=1
enabled_metadata=1
REPOEOF
  log "COPR ${project}: repo written against the download backend (no API), key pinned"
}
# kernel-cachyos is built for x86-64-v3 (CONFIG_X86_64_VERSION=3, read from
# the package) and hangs at decompression on an x86-64-v2 CPU, before it can
# print anything; the image has no fallback kernel (issue #382).
KERNEL_PKG="kernel-cachyos"
KERNEL_DEVEL_PKG="kernel-cachyos-devel-matched"
KERNEL_PACKAGES=(kernel-cachyos kernel-cachyos-core kernel-cachyos-modules "$KERNEL_DEVEL_PKG")
# TRANSIENT packages are installed for build time only and removed at the end.
# sbsigntools provides sbsign/sbverify; akmods is needed for v4l2loopback (best-effort).
TRANSIENT=(akmods sbsigntools "$KERNEL_DEVEL_PKG")

# Install the signing tools up-front so they're available when we sign vmlinuz.
log "Installing sbsigntools (build-time only)"
dnf -y install sbsigntools

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

disable_kernel_install_hooks() {
  for _f in \
      /usr/lib/kernel/install.d/05-rpmostree.install \
      /usr/lib/kernel/install.d/50-dracut.install
  do
    [[ -f "$_f" ]] || continue
    mv "$_f" "$_f.bak"
    printf '#!/bin/sh\nexit 0\n' >"$_f"
    chmod +x "$_f"
  done
}
restore_kernel_install_hooks() {
  for _f in \
      /usr/lib/kernel/install.d/05-rpmostree.install \
      /usr/lib/kernel/install.d/50-dracut.install
  do
    [[ -f "$_f.bak" ]] && mv -f "$_f.bak" "$_f"
  done
}

# akmodsbuild on bootc images skips signing if /var isn't writable; patch
# it out so akmods proceeds inside the container build.
disable_akmodsbuild() {
  _ak="/usr/sbin/akmodsbuild"
  [[ -f "$_ak" ]] || return 1
  cp -p "$_ak" "$_ak.backup"
  sed '/if \[\[ -w \/var \]\] ; then/,/fi/d' "$_ak" > "$_ak.tmp"
  # Fixed build directory instead of mktemp's random one (2026-10-03).
  # The module's debug info records the directory it was compiled in, the
  # GNU build-id is a hash over it, and the build-id lands in the shipped
  # .ko: two builds of the same source differed ONLY in .note.gnu.build-id
  # (text, data and modinfo identical), and that one note moved a 50 MiB
  # layer on every update. Best-effort like the module itself: if the
  # line ever changes upstream, the build goes on with a random dir.
  sed -i 's|mktemp -d -p /tmp "${myprog}.XXXXXXXX"|mkdir -m 0700 /tmp/"${myprog}".margine \&\& echo /tmp/"${myprog}".margine|' "$_ak.tmp"
  grep -q '/tmp/"${myprog}".margine' "$_ak.tmp" \
    || log "akmodsbuild: tmpdir line not found, v4l2loopback builds in a random dir (not reproducible)"
  mv "$_ak.tmp" "$_ak"
  chmod +x "$_ak"
}
restore_akmodsbuild() {
  [[ -f /usr/sbin/akmodsbuild.backup ]] \
    && mv -f /usr/sbin/akmodsbuild.backup /usr/sbin/akmodsbuild
}

sign_kernel() {
  _vmlinuz="/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"
  [[ -f "$_vmlinuz" ]] || { err "vmlinuz not found at $_vmlinuz"; return 1; }
  _tmp=$(mktemp)
  # systemd-sbsign, not sbsign (2026-10-03). sbsign stamps the signature
  # with the wall clock (PKCS#7 signingTime) and has no way to fix it, so
  # vmlinuz changed on every build and every update re-downloaded the
  # whole kernel layer (219 MiB, with kernel-devel) for one attribute:
  # measured on candidate.20261003 vs pr-439, the only differing file in
  # that layer, with all 34665 others identical. systemd-sbsign (shipped
  # in the base's systemd) takes SOURCE_DATE_EPOCH for that attribute;
  # pinned to the kernel package's build time, the same kernel and key
  # give the same bytes. Checked against sbsign on this vmlinuz: same
  # signed attributes, same Authenticode digest, identical image bytes
  # outside the certificate table, and sbverify accepts both.
  _sign_epoch=$(rpm -qf --qf '%{BUILDTIME}\n' "$_vmlinuz" | head -n1)
  [[ "$_sign_epoch" =~ ^[0-9]+$ ]] || { err "no build time for the package owning $_vmlinuz"; return 1; }
  SOURCE_DATE_EPOCH="$_sign_epoch" /usr/lib/systemd/systemd-sbsign sign \
    --private-key "$SIGNING_KEY" --certificate "$SIGNING_CERT" \
    --output "$_tmp" "$_vmlinuz"
  sbverify --cert "$SIGNING_CERT" "$_tmp" \
    || { rm -f "$_tmp"; err "sbverify failed on signed kernel"; return 1; }
  cp "$_tmp" "$_vmlinuz"
  chmod 0644 "$_vmlinuz"
  rm -f "$_tmp"
  # Stamp for the end-of-script integrity check (back-ported from the
  # Origami reference script): if any later step — akmods, dracut,
  # cleanup — rewrites vmlinuz after signing, the build must fail
  # rather than ship an unsigned kernel that Secure Boot rejects.
  sha256sum "$_vmlinuz" > /tmp/vmlinuz.sha
}

sign_kernel_modules() {
  _module_root="/usr/lib/modules/${KERNEL_VERSION}"
  _sign_file="${_module_root}/build/scripts/sign-file"
  [[ -x "$_sign_file" ]] || { err "sign-file missing: $_sign_file"; return 1; }
  find "$_module_root" -type f \( \
      -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.zst" -o -name "*.ko.gz" \
    \) | while IFS= read -r _mod; do
    case "$_mod" in
      *.ko)
        "$_sign_file" sha256 "$SIGNING_KEY" "$SIGNING_CERT" "$_mod" ;;
      *.ko.xz)
        _raw="${_mod%.xz}"
        xz -d -q "$_mod"
        "$_sign_file" sha256 "$SIGNING_KEY" "$SIGNING_CERT" "$_raw"
        xz -z -q "$_raw" ;;
      *.ko.zst)
        _raw="${_mod%.zst}"
        zstd -d -q --rm "$_mod"
        "$_sign_file" sha256 "$SIGNING_KEY" "$SIGNING_CERT" "$_raw"
        zstd -q "$_raw" ;;
      *.ko.gz)
        _raw="${_mod%.gz}"
        gunzip -q "$_mod"
        "$_sign_file" sha256 "$SIGNING_KEY" "$SIGNING_CERT" "$_raw"
        gzip -q "$_raw" ;;
    esac
  done
}

create_mok_enroll_unit() {
  _mok_cert="/usr/share/cert/MOK.der"
  _unit_file="/usr/lib/systemd/system/mok-enroll.service"
  mkdir -p "$(dirname "$_mok_cert")"
  openssl x509 -in "$SIGNING_CERT" -outform DER -out "$_mok_cert"
  chmod 0644 "$_mok_cert"
  mkdir -p "$(dirname "$_unit_file")"
  # The logic lives in /usr/libexec/margine/mok-enroll (system_files,
  # copied into the rootfs later by 10-os-identity, so read here from
  # /ctx), with the password as a constant there too: fail the build if
  # the two ever disagree, or users would be told a password MokManager
  # rejects.
  _helper=/usr/libexec/margine/mok-enroll
  _helper_src="/ctx/system_files${_helper}"
  [[ -x "$_helper_src" ]] || { err "missing $_helper_src"; return 1; }
  grep -qx "PASSWORD=\"${MOK_PASSWORD}\"" "$_helper_src" \
    || { err "MOK_PASSWORD and the password in $_helper_src differ"; return 1; }
  cat > "$_unit_file" <<EOF
[Unit]
Description=Make sure the Margine MOK is enrolled (Secure Boot needs it)
ConditionPathExists=${_mok_cert}
ConditionPathExists=/sys/firmware/efi
# Every boot, with Secure Boot on or off: the key must already be in shim
# BEFORE Secure Boot is turned on, or the Margine kernel stops booting.
# The old one-shot marker (/var/.mok-enrolled) is deliberately ignored:
# it was stamped even when nothing had been enrolled (2026-10-04).
# Before the display manager, so the login-time notice sees the request.
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=${_helper}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$_unit_file"
  systemctl -f enable mok-enroll.service
  log "MOK enroll unit installed and enabled"
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

log "Disabling kernel install hooks for the duration of the swap"
disable_kernel_install_hooks

log "Removing the stock kernel packages"
dnf -y remove \
    kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra \
    kernel-devel kernel-devel-matched || true
rm -rf /usr/lib/modules/* || true

log "Enabling COPR: $COPR_REPO"
copr_enable_direct "$COPR_REPO" "$COPR_CACHYOS_FPR" || exit 1

# On self-hosted runners, /var/cache is a persistent BuildKit cache
# mount. A previous failed download (e.g. a partial RPM with bad
# SHA256) gets stored there and dnf will keep re-using it, failing
# every subsequent build with "Payload SHA256 ALT digest: BAD".
# Clean packages + metadata before install so each kernel pull is fresh.
log "Cleaning dnf packages + metadata to avoid cache poisoning on persistent runners"
dnf -y clean packages metadata

log "Installing CachyOS kernel: ${KERNEL_PACKAGES[*]}"
# COPR (copr.fedorainfracloud.org) is occasionally slow or returns 5xx
# / curl timeouts for several minutes — observed 2026-06-02 with run
# #26838562527 dying at "Curl error (28): Timeout was reached" after
# 5 internal librepo retries. Outer retry (shared helper) with backoff
# so transient COPR brownouts don't sink the whole 28-min image build.
# Each attempt cleans metadata first to dodge the bad-metadata-cached
# failure mode (see comment above).
retry 5 30 bash -c 'dnf -y clean metadata >/dev/null 2>&1 || true; exec dnf -y install --refresh "$@"' _ "${KERNEL_PACKAGES[@]}" akmods \
  || { err "CachyOS kernel install FAILED after 5 attempts (COPR likely down)"; exit 1; }

KERNEL_VERSION="$(rpm -q "$KERNEL_PKG" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
log "Installed kernel: $KERNEL_VERSION"

log "Restoring kernel install hooks"
restore_kernel_install_hooks

log "Removing COPR repo file (kept only at build time)"
rm -f /etc/yum.repos.d/*copr*

# Refresh GPU firmware + microcode to match the (newer) CachyOS kernel.
# The CachyOS kernel can be newer than the base image's linux-firmware
# snapshot (the CachyOS spec only Recommends: it), so a kernel that
# references amdgpu blobs absent from the base would fail the GPU probe /
# black-screen before GDM on bare metal — invisible to the virtio-gpu CI
# gate. Upgrade ONLY the firmware packages actually installed (so an
# unknown-package name can't abort the transaction), from the always-on
# Fedora repos; never block the build on it.
FW_PKGS="$(rpm -qa --qf '%{NAME}\n' 'linux-firmware*' 'amd-gpu-firmware*' 'amd-ucode*' 2>/dev/null | sort -u | tr '\n' ' ')"
if [[ -n "${FW_PKGS// /}" ]]; then
  log "Refreshing firmware/microcode for $KERNEL_VERSION: $FW_PKGS"
  # shellcheck disable=SC2086 # intentional word-split of the package list
  dnf -y upgrade --refresh $FW_PKGS \
    || log "WARN: firmware/microcode refresh non-fatal failure (continuing)"
fi

# ---------------------------------------------------------------------------
# v4l2loopback against the CachyOS kernel (OPTIONAL — skip on build error)
# ---------------------------------------------------------------------------
# Building akmod-v4l2loopback in BuildKit currently fails with "ERROR:
# Could create tempdir" because akmodsbuild expects writable /var
# state that isn't available in a build cache mount. Origami works
# around it with their own build environment. For Margine v1 we mark
# v4l2loopback as best-effort: if the build fails, we log and continue
# without it. Users who need virtual camera support can install
# v4l2loopback later as a one-off layer or via Flatpak (OBS has its
# own GStreamer pipeline that doesn't need this module).
log "Building v4l2loopback against $KERNEL_VERSION (best-effort)"
# akmods builds as its own unprivileged user and rpmbuild writes its temp
# files under /var/tmp. The plain Bluefin image ships no /var/tmp at all
# (an empty /var; bootc creates it at boot via tmpfiles), so whatever rpm
# transaction created it first left it 0755 root and the build died with
# 'error creating temporary file /var/tmp/rpm-tmp.*: Permission denied'
# (trial 7, 2026-08-25). Same fix as the /tmp tmpfs mode in the
# Containerfile: world-writable with the sticky bit, before akmods runs.
install -d -m 1777 /var/tmp
chmod 1777 /tmp /var/tmp
V4L2_OK=0
if disable_akmodsbuild; then
  if dnf -y install \
        "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
     && verify_rpmfusion_keys free \
     && dnf install -y --setopt=install_weak_deps=False --setopt=tsflags=noscripts \
        akmod-v4l2loopback; then
    # The kmod RPM akmods builds is installed, so its header lands in the
    # rpmdb: build host and build time must not depend on when and where
    # the image was built, or the rpmdb layer changes on every rebuild.
    # Build-time only, removed right after akmods.
    cat > /etc/rpm/macros.zz-margine-reproducible <<'MACROS'
%_buildhost margine-build
%source_date_epoch_from_changelog 1
%use_source_date_epoch_as_buildtime 1
%clamp_mtime_to_source_date_epoch 1
MACROS
    if akmods --force --verbose --kernels "$KERNEL_VERSION" --kmod v4l2loopback; then
      # akmods always returns 0; check for *.failed.log explicitly
      V4L2_FAILED=0
      for _f in /var/cache/akmods/v4l2loopback/*-for-"$KERNEL_VERSION".failed.log; do
        if [[ -f "$_f" ]]; then
          V4L2_FAILED=1
          # Show the cause in the build log: a bare "[FAILED]" from akmods
          # hid why the module did not build on the plain Bluefin base
          # (trial build of 2026-08-25).
          log "v4l2loopback build FAILED, tail of $_f:"
          tail -n 40 "$_f" | sed 's/^/[v4l2loopback] /' || true
          break
        fi
      done
      if (( V4L2_FAILED == 0 )); then
        V4L2_OK=1
      fi
    fi
    rm -f /etc/rpm/macros.zz-margine-reproducible
    dnf -y remove rpmfusion-free-release
    rm -f /etc/yum.repos.d/rpmfusion-free*.repo
  fi
  restore_akmodsbuild
fi

if (( V4L2_OK )); then
  log "v4l2loopback built OK"
  TRANSIENT+=(akmod-v4l2loopback)
  _kmod_rpm="$(find /var/cache/akmods/v4l2loopback/ -name "kmod-v4l2loopback-*$KERNEL_VERSION*.rpm" -print -quit 2>/dev/null || true)"
  if [[ -n "${_kmod_rpm:-}" && -f "$_kmod_rpm" ]]; then
    dnf -y install "$_kmod_rpm"
    TRANSIENT+=(kmod-v4l2loopback)
  fi
else
  log "v4l2loopback build skipped/failed — not blocking; image continues without virtual camera kmod"
fi

# ---------------------------------------------------------------------------
# scx-scheds — sched_ext BPF schedulers managed by scx_loader/scxctl
# (current shipped names come from `scxctl list`). Ships in the same
# CachyOS addons COPR as the kernel itself, lives in the base image so the
# `ujust margine-scheduler` recipe is available on every Margine
# install — gaming variant inherits it without re-adding. Enable the
# COPR just for the install, then disable + scrub the repo file so user
# systems don't pull random updates from it outside our pipeline.
log "Enabling kernel-cachyos-addons COPR for scx-scheds"
copr_enable_direct bieszczaders/kernel-cachyos-addons "$COPR_ADDONS_FPR" || exit 1
# Same COPR host as the kernel (copr.fedorainfracloud.org), same 5xx /
# Curl-timeout brownouts — same shared retry helper.
retry 5 30 bash -c 'dnf -y clean metadata >/dev/null 2>&1 || true; exec dnf -y install --refresh scx-scheds' \
  || { err "scx-scheds install FAILED after 5 attempts (kernel-cachyos-addons COPR likely down)"; exit 1; }
rm -f /etc/yum.repos.d/_copr*kernel-cachyos-addons*.repo
log "scx-scheds installed:"
ls /usr/bin/scx_* 2>/dev/null | sed 's|^/usr/bin/||' | sort

# scx_loader is opt-in (Bazzite pattern + audit §6.7). Disabling it
# here is idempotent — if the package preset is already 'disabled' the
# call is a no-op. Users opt in via `ujust margine-scheduler` or the
# margine-scheduler.desktop GUI. (The tuned profiles {balanced,powersave,
# throughput-performance}-margine that flipped the scx mode left on
# 2026-10-18: no profile selection ever picked them.) Default-on burned
# battery without an obvious win on a creator workstation.
log "Disabling scx_loader.service by default (opt-in via margine-scheduler)"
systemctl disable scx_loader.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# Codecs and controller rules
# ---------------------------------------------------------------------------
# gstreamer1-plugins-bad / -ugly resolve from negativo17's fedora-multimedia.
# On Bluefin DX that repo file shipped in the base (enabled=0) and the
# packages were already installed, so the install below was silently a
# no-op and nobody noticed the repo was never enabled. On a base without
# negativo17 (projectbluefin/bluefin, 2026-08-25 trial) the same line dies
# with "No match for argument: gstreamer1-plugins-bad". So: make sure the
# repo exists, with its key verified first, enable it for this one
# transaction only, and leave it disabled like every other third-party repo
# in the image.
if [[ ! -f /etc/yum.repos.d/negativo17-fedora-multimedia.repo ]]; then
  log "negativo17 fedora-multimedia repo absent from the base, adding it (key pinned)"
  retry_curl_strict https://negativo17.org/repos/RPM-GPG-KEY-slaanesh /run/negativo17.asc
  verify_key_fpr /run/negativo17.asc "$NEGATIVO17_FPR" "negativo17" || exit 1
  rpm --import /run/negativo17.asc
  retry_curl_strict https://negativo17.org/repos/fedora-multimedia.repo /etc/yum.repos.d/negativo17-fedora-multimedia.repo
  sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/negativo17-fedora-multimedia.repo
  rm -f /run/negativo17.asc
fi

# gstreamer1-plugins-{bad,ugly} complete the codec swap the declarations
# YAML specifies (host_packages.baseline.codec_replacement.install);
# ffmpeg full already comes from the base. BOTH resolve from negativo17
# (the base's own multimedia family), NOT from RPMFusion: RPMFusion's
# bad-freeworld links libx265.so.215 while negativo17 ships x265 4.2 (.216);
# since 2026-07-04 the two can no longer coexist. negativo17's
# gstreamer1-plugins-bad (epoch 1) is a superset of the freeworld build
# (verified: bundles libgstx265.so, libgstva.so, nvcodec/msdk/qsv,
# fdkaac), so the handbook's codec promises hold.
# steam-devices: udev rules for USB game controllers (Steam, Xbox, PS,
# generic gamepads), a few kilobytes; the Flatpak Steam of
# `ujust margine-gaming` needs them on the host. From Fedora.
#
# What left this step on 2026-10-18 (Lucciola):
#   - mangohud and goverlay (vkBasalt came with them): `ujust margine-gaming`
#     and `ujust margine-gaming-native` layer them when someone asks for
#     the gaming layer.
#   - RPMFusion: it was enabled here only for mangohud, goverlay,
#     steam-devices and the gaming closure below; Fedora has the first
#     three and steam comes from negativo17.
retry 5 30 bash -c 'dnf -y clean metadata >/dev/null 2>&1 || true; exec dnf -y install --refresh --enablerepo=fedora-multimedia steam-devices gstreamer1-plugins-bad gstreamer1-plugins-ugly' \
  || { err "codec and controller-rule install failed after 5 attempts; aborting"; exit 1; }
log "Base now ships: steam-devices + the gstreamer bad/ugly codecs (negativo17)"

# ---------------------------------------------------------------------------
# Native gaming: align the image with the layer, do not bake the layer
# ---------------------------------------------------------------------------
# `ujust margine-gaming-native` layers steam, whose 32-bit (i686) chain is
# about 200 packages: mesa/llvm, SDL3, gtk3, glycin, NetworkManager-libnm,
# ... rpm-ostree cannot touch an image package while it layers, so every
# i686 library must fit the x86_64 packages the image ships. The base
# (silverblue-main) is built from its own snapshot of Fedora and lags the
# repositories by days; on a branched release (Fedora 45 until its GA)
# superseded builds vanish from the repositories, so the base's versions
# have no i686 twin left to install.
#
# Until 2026-10-18 the whole chain was installed here and the four
# applications removed again (--no-autoremove): 209 i686 packages, about
# 731 MiB installed in every image, so that the layer only ever added the
# applications. Installing the chain had a side effect that mattered as
# much: dnf upgraded the image packages the chain needed newer (30 of them
# on 2026-10-18: NetworkManager, glib2, glycin, libcurl, expat...).
#
# Now only that side effect is kept. dnf plans the layer's transaction
# without running it; every x86_64 or noarch package of the plan that
# replaces an image package (an upgrade, or an obsolete: negativo17's
# openh264 replaces Fedora's noopenh264 stub, as it did in the bake) is
# installed at exactly that build; the i686 chain itself is not
# installed. The plan is then asked again, and the build stops unless the
# layer resolves with installs only, which is what rpm-ostree needs.
# Weak dependencies stay out of the plan, as they did in the bake: lutris
# recommends wine and the mingw libraries (1.9 GB).
#
# This makes the layer resolvable against the image as built. It still
# downloads its chain when someone runs the recipe, against whatever the
# repositories hold that day: on a branched release a build pushed after
# the image can replace the version the image needs, until the next image.
# CI checks the full layer twice: build.yml right after the build
# (.github/scripts/gaming-native-resolve.sh, every installed package locked
# at its version) and smoke-boot with rpm-ostree on the booted image; a
# failure of either stops the image.
mapfile -t GAMING_LAYER < <(grep -vE '^[[:space:]]*(#|$)' /ctx/60-ujust-services/gaming-native-packages.txt)
(( ${#GAMING_LAYER[@]} )) || { err "gaming-native-packages.txt lists no package"; exit 1; }
gaming_plan() {
  local out attempt
  for attempt in 1 2 3 4 5; do
    out="$(dnf install --assumeno --refresh --setopt=install_weak_deps=False --enablerepo=fedora-multimedia "${GAMING_LAYER[@]}" 2>&1 || true)"
    if grep -q '^Transaction Summary' <<<"$out"; then printf '%s\n' "$out"; return 0; fi
    if grep -qE '^Failed to resolve the transaction|^Problem' <<<"$out"; then
      printf '%s\n' "$out" | tail -n 40 >&2
      err "the gaming-native layer does not resolve against the image even with upgrades allowed"
      return 1
    fi
    log "gaming plan attempt $attempt: no verdict from dnf, retrying in 30 s" >&2
    sleep 30
  done
  err "dnf gave no gaming plan in five attempts (repositories down?)"
  return 1
}
log "Planning the gaming-native layer (${GAMING_LAYER[*]}) against the image"
_plan="$(gaming_plan)" || exit 1
# Rows are " <name> <arch> <epoch:version-release> <repo> <size>", and a
# row that takes the place of an installed package is followed by
# "   replacing <old>" rows. Install exactly those builds (not the i686 ones).
mapfile -t _align < <(awk '
  /^ [^ ]/          { cand = ($2 == "i686") ? "" : $1 "-" $3 "." $2; next }
  /^   replacing /  { if (cand != "") print cand; cand = ""; next }
                    { cand = "" }' <<<"$_plan" | sort -u)
if (( ${#_align[@]} )); then
  log "Aligning ${#_align[@]} image packages with the gaming-native layer: ${_align[*]}"
  retry 5 30 bash -c 'dnf -y clean metadata >/dev/null 2>&1 || true; exec dnf -y install --refresh --setopt=install_weak_deps=False --enablerepo=fedora-multimedia "$@"' _ "${_align[@]}" \
    || { err "aligning the image packages failed after 5 attempts; aborting"; exit 1; }
else
  log "No image package needs upgrading for the gaming-native layer"
fi
_plan="$(gaming_plan)" || exit 1
if grep -qE '^ ?(Upgrading|Downgrading|Replacing|Reinstalling|Removing)' <<<"$_plan"; then
  printf '%s\n' "$_plan" | tail -n 40 >&2
  err "the gaming-native layer still needs to change image packages after the alignment"
  exit 1
fi
log "gaming-native layer resolves against the image with installs only: $(grep -E '^ Installing:' <<<"$_plan" | tr -s ' ')"
_n686="$(rpm -qa --qf '%{ARCH}\n' | awk '$1 == "i686"' | wc -l)"
if (( _n686 > 0 )); then
  err "$_n686 i686 packages in the image: the gaming chain must not be baked"; exit 1
fi

# ---------------------------------------------------------------------------
# Signing
# ---------------------------------------------------------------------------
log "Signing kernel image with MOK"
sign_kernel

log "Signing kernel modules with MOK"
sign_kernel_modules
# Signing rewrites every module, so each one carried the build time and the
# modules' layers (and the initramfs that packs them) changed on every build
# with identical bytes inside. Back to the kernel package's build time, the
# same clock vmlinuz is signed with.
_mod_epoch=$(rpm -q --qf '%{BUILDTIME}\n' "$KERNEL_PKG" | head -n1)
[[ "$_mod_epoch" =~ ^[0-9]+$ ]] || { err "no build time for $KERNEL_PKG"; exit 1; }
find "/usr/lib/modules/${KERNEL_VERSION}" -type f \( -name '*.ko' -o -name '*.ko.*' \) \
  -exec touch -h -d "@${_mod_epoch}" {} +
touch -h -d "@${_mod_epoch}" "/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"

log "Creating MOK enroll unit for first-boot import"
create_mok_enroll_unit

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
log "Removing transient build-only packages: ${TRANSIENT[*]}"
dnf -y remove "${TRANSIENT[@]}" || true

# Drop a dracut config to disable host-only mode for every subsequent
# dracut invocation in this image (build.sh's Plymouth regeneration too,
# and any user-triggered `rpm-ostree initramfs` post-install). Without
# this, dracut runs in the build container — where there's no LUKS,
# no btrfs root, no virtio-net — and bakes an initramfs that boots only
# on hardware exactly like the build container. End users with LUKS
# encryption (every real install) get a kernel panic at early boot:
#   VFS: Cannot open root device "UUID=..."
# because the crypto/dm/btrfs modules are not in the initramfs.
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/01-margine-no-hostonly.conf <<'CONF'
# Required for bootc / OCI image builds: the build environment is not
# the deployment environment, so initramfs must be generic.
hostonly="no"
hostonly_cmdline="no"
CONF

# NB: we deliberately do NOT force virtio_gpu into the initramfs. It proved
# UNNECESSARY — Plymouth renders fine in UEFI VMs via the EFI framebuffer
# (efifb, built-in) once it isn't deferred by a serial console (handled by
# plymouth.ignore-serial-consoles in 10-margine-plymouth.toml). It was also
# unlandable here: `dracut --add-drivers virtio_gpu` includes the module on a
# host but the build container's dracut silently skipped it (the 2026-06-19
# builds failed an assertion proving it never made the initramfs). The brief
# efifb->virtio_gpu mode switch mid-boot is handled by the theme re-centering on
# resize (margine.script refresh_callback). On bare metal the real GPU driver
# (e.g. amdgpu) is already in the generic set. So: no virtio_gpu drop-in.

# Regenerate initramfs at the **bootc/ostree-expected path**:
#   /usr/lib/modules/<KVER>/initramfs.img
# Bluefin DX (and every Universal Blue image) puts initramfs there.
# bootc/ostree picks it up at deployment time from that exact path.
# Dracut's default output is /boot/initramfs-<KVER>.img — the traditional
# Anaconda/non-ostree location — which ostree IGNORES, falling back to
# auto-generating a host-only initramfs (no crypto/btrfs/virtio_blk
# modules → kernel panic on real installs with LUKS).
#
# We pass the output path as a positional argument so dracut writes
# exactly where ostree expects.
# Suppress the dracut-install ERROR: installing '/root' / FAILED warnings
# that have been showing up in every build for months. Source: dracut's
# 95ssh-client module-setup.sh probes for /root/.ssh/known_hosts +
# /root/.ssh/config; even though the `[[ -f ... ]]` guards skip them when
# absent, dracut-install still tries to mkdir the parent dir /root/.ssh/
# inside the staging tree, and barfs if /root doesn't exist as an actual
# directory in the build sysroot. Creating /root as a vacant chmod-700
# dir satisfies the dracut-install parent-mkdir path; the `-f` guard in
# the ssh-client module still skips the keyfiles themselves (they're not
# there in a bootc image-build environment).
#
# Pure cosmetic fix — image semantics unchanged. The alternative
# (`omit_dracutmodules+=" ssh-client "`) would silence the warnings but
# also lose the dracut-side hook used for remote LUKS unlock via dropbear,
# which is unrelated baggage.
ROOT_HOME="$(realpath -m /root)"
mkdir -p "$ROOT_HOME"
chmod 700 "$ROOT_HOME"

log "Regenerating initramfs for all installed kernels (generic, bootc-path, ostree)"
# --add ostree: ESSENTIAL for bootc/ostree systems. Without it the
# initramfs doesn't include ostree-prepare-root, which is what pivots
# /sysroot from the raw btrfs root (where there's no /etc/os-release
# at the top level — just home/root/var subvolumes) to the actual
# deployment content under /ostree/deploy/.../.../. Without this,
# systemd's switch-root check `openat(fd, "etc/os-release",
# O_NOFOLLOW)` fails because /sysroot is the wrong filesystem view.
# Symptom: "Failed to switch root: ... os-release file is missing"
# even when the deployment is fully present on disk.
# Verified missing 2026-05-30: `lsinitrd <initramfs> | grep ostree`
# returned ZERO lines on our published image. `--no-hostonly` alone
# is insufficient; ostree dracut module must be EXPLICITLY requested.
# The initramfs MUST be zstd-compressed (today this only works by
# inheriting Bluefin's 10-compression.conf; nothing pins it). Pass --zstd
# explicitly AND fail loudly if the tool is missing, so dracut can never
# silently fall back to gzip (slower boot, bigger initramfs).
# regenerate_initramfs (00-common.sh) passes --zstd and fails when zstd is
# missing, and makes the result byte-reproducible.
for kver_dir in /usr/lib/modules/*/; do
  kver=$(basename "$kver_dir")
  regenerate_initramfs "$kver" || { err "dracut failed for $kver"; exit 1; }
  log "Wrote ${kver_dir}initramfs.img ($(du -h "${kver_dir}initramfs.img" | cut -f1))"
done

# Final integrity check (Origami pattern): vmlinuz must still be the
# exact bytes sign_kernel produced — a post-signing rewrite would ship
# a kernel Secure Boot rejects with the cryptic "bad shim signature".
sha256sum -c /tmp/vmlinuz.sha >/dev/null \
  || { err "vmlinuz was modified AFTER signing — refusing to ship"; exit 1; }
rm -f /tmp/vmlinuz.sha
log "vmlinuz signature integrity verified end-of-build"

log "custom-kernel install complete: $KERNEL_VERSION"
