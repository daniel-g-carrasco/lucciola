# =============================================================================
# Lucciola: a bootc image on Fedora Silverblue (Universal Blue main), CachyOS
# kernel, Umbriel with the Noctalia shell
# =============================================================================
#
# This Containerfile composes the Lucciola image as:
#
#   FROM ghcr.io/ublue-os/silverblue-main:45  (Universal Blue main: Fedora Silverblue 45)
#   + custom kernel from CachyOS COPR (signed with our MOK in a stage of
#     its own, the only place the private key is mounted)
#   + the layer inherited from Margine OS (build_files/: update flow, Secure Boot and TPM
#     tooling, branding, the GTK defaults, Flatpaks)
#   + the Lucciola layer (lucciola/: Umbriel, Noctalia, the Lucciola session;
#     GNOME stays as a stock fallback session)
#
# Until 2026-10 Lucciola was a second build FROM the published Margine image
# (lucciola/Containerfile); now one build produces it, so this repository
# alone decides what ships.
#
# Built by GitHub Actions on every push, pushed to:
#   ghcr.io/daniel-g-carrasco/lucciola:candidate, promoted to :stable by
#   smoke-boot.yml
# =============================================================================

# ----- Base image, as a build argument ---------------------------------------
# Universal Blue's silverblue-main: Fedora Silverblue plus their automation
# (ujust, the update services, signing policy, udev rules) and nothing else.
# Margine built on Bluefin DX until 2026-10-11; what DX added is Margine's
# own now (build_files/15-devstack, 12-base-trim, the flatpak-preinstall
# unit, uupd from the COPR) and the switch was proven by trial builds and a
# smoke-boot of the trial image (ADR 0010). Still an ARG, so a build can be
# pointed at another base without editing this file:
#
#   buildah build --build-arg BASE_IMAGE=ghcr.io/ublue-os/silverblue-main:45
#
# (build.yml: workflow_dispatch with base_image publishes :trial only.)
# CI never builds FROM the tag: build.yml resolves it to a digest once
# (.github/scripts/resolve-base.sh) and passes repository@digest here, the
# same digest it writes in the base.digest label, so both stages below and
# the label name one base.
ARG BASE_IMAGE=ghcr.io/ublue-os/silverblue-main:45
# Noctalia Greeter's pinned tag and the sha256 of its archive: declared here,
# before any FROM, so the stage that builds it and the step that installs it
# read the same value (see the greeter-rpm stage).
ARG NOCTALIA_GREETER_VERSION=1.7.1
ARG NOCTALIA_GREETER_SHA256=79344d9629393ab3f4d605068eec94d2bfe8e12402618e1521f46111e27ff6ed
# xdg-desktop-portal-luminous's pinned tag and archive sha256, the same way
# (see the luminous-rpm stage).
ARG LUMINOUS_VERSION=0.1.21
ARG LUMINOUS_SHA256=d6df0ac024409de9e38f0890799b0ef3eaf71156692cc48fc0fe9059f79e8b58
# Umbriel (the compositor of the Lucciola session) and its portal backend:
# pinned commits and the sha256 of their archives (see the umbriel-rpm stage).
ARG UMBRIEL_COMMIT=edd40d573452251c1bc1bf1d299107c08acf3887
ARG UMBRIEL_SHA256=e1738f9b886417f23fa335946022219d96f50ac073160182446d039f9f9e843d
ARG UMBRIEL_PORTAL_COMMIT=04aa9870411e367f7dd87c00a23488f549624119
ARG UMBRIEL_PORTAL_SHA256=cb5fec41482ae7d68e6e9f8f8f94b1371a143f5f6996b8d61bc3b5c68a10cb17

# ----- Build context: scripts that should NOT end up in the final image -----
FROM scratch AS ctx
COPY build_files /
# Make installer/flatpaks-base reachable from build.sh at
# /ctx/installer-flatpaks-base. Single source of truth for the BAKE
# Flatpak list (audit §3.5: drop the duplicate here-doc in build.sh).
# (The old BIB installer image that also consumed it was retired in
# time via the installer/ working dir. The gaming variant was retired
# 2026-06-06 so there is no installer/flatpaks-gaming any more.
COPY installer/flatpaks-base    /installer-flatpaks-base
# Lucciola's brand (logos, wallpaper, the Plymouth theme), for 50-branding.
# In ctx rather than a stage of its own because the boot splash must be in
# place before 50-branding writes the initramfs, in the same RUN as the
# kernel; an asset change costs that layer's cache, like any other
# build_files change does.
COPY lucciola/assets            /lucciola-assets

# lucciola/build.sh gets a context stage of its own, not a place in ctx:
# the kernel RUN below mounts the whole ctx, and an edit to the Lucciola
# step must not throw away that layer's cache. (A bind mount straight from
# the build context would do the same, but a rootless podman build on an
# SELinux host cannot read it: "Permission denied", tried 2026-10-17.)
FROM scratch AS lucciola-ctx
COPY lucciola/build.sh /build.sh

# The MOK signer alone, so the mok-sign stage's cache depends on it and on
# the files it signs, not on every build_files edit.
FROM scratch AS mok-sign-ctx
COPY build_files/custom-kernel/mok-sign.sh /mok-sign.sh

# ----- Noctalia Greeter: an RPM built from its pinned upstream tag -----
# Lucciola's login screen (greetd + Noctalia Greeter, lucciola/build.sh step
# 5). Fedora packages greetd but not the greeter. Built here, from the tag,
# rather than installed from Terra (Fyra Labs' repository, which has a
# signed build of the same tag):
#   - Terra keeps only the newest build of a package, so a pinned
#     version-release vanishes at the next upstream release (v1.5.0 and
#     v1.6.0 came 17 days apart), and every image build, security updates
#     included, would stop until the pin moves;
#   - here nothing runs that Fedora did not build, except the greeter's own
#     source, checked against a sha256 of the tag's archive: no third-party
#     binaries, signing key or repository in the build.
# The stage runs on the same base, so the RPM links against the libraries
# the image ships; lucciola/build.sh installs it with dnf, which pulls its
# runtime libraries from Fedora. To move to a new tag: set the version and
# the sha256 of https://github.com/noctalia-dev/noctalia-greeter/archive/refs/tags/v<version>.tar.gz
# (the ARGs at the top), check the spec's BuildRequires against the tag's
# meson.build, test-boot. v1.7.1 is commit
# 2726e75375d95d5458d021f76c330ab14f6a5d03 (a signed tag). On top of the
# tag the spec applies Lucciola's patches (the .patch files in
# lucciola/greeter/, each says why) and puts Lucciola's mark in place of the
# Noctalia logo; check that the patches still apply when the tag moves.
FROM ${BASE_IMAGE} AS greeter-rpm
ARG NOCTALIA_GREETER_VERSION
ARG NOCTALIA_GREETER_SHA256
COPY lucciola/greeter/ /src/
COPY lucciola/assets/lucciola-mark.svg /src/
RUN --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    env NOCTALIA_GREETER_VERSION="${NOCTALIA_GREETER_VERSION}" \
        NOCTALIA_GREETER_SHA256="${NOCTALIA_GREETER_SHA256}" \
        bash /src/build-rpm.sh

# ----- xdg-desktop-portal-luminous: an RPM built from its pinned tag -----
# The RemoteDesktop portal backend of the Lucciola session (lucciola/build.sh
# step 5g): mouse and keyboard from the phone through KDE Connect, which
# needs the RemoteDesktop portal, and neither the GNOME backend nor Umbriel's
# offers it there. Not in Fedora; built here like the greeter, from the tag's archive
# checked against its sha256, the crates at the versions Cargo.lock pins.
# v0.1.21 is commit 5674aa3b89cc3456085909ce0c9a4d701d8e5981. To move the
# tag: set the version and the sha256 of
# https://github.com/waycrate/xdg-desktop-portal-luminous/archive/refs/tags/v<version>.tar.gz
# (the ARGs at the top), check the spec's BuildRequires against the tag's
# Cargo.toml, test remote input from the phone.
FROM ${BASE_IMAGE} AS luminous-rpm
ARG LUMINOUS_VERSION
ARG LUMINOUS_SHA256
COPY lucciola/luminous/ /src/
RUN --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    env LUMINOUS_VERSION="${LUMINOUS_VERSION}" \
        LUMINOUS_SHA256="${LUMINOUS_SHA256}" \
        bash /src/build-rpm.sh

# ----- Umbriel and its portal: RPMs built from their pinned commits -----
# The compositor of the Lucciola session (lucciola/build.sh step 2) and its
# xdg-desktop-portal backend. Umbriel has no releases yet, so commits are
# pinned and each archive is checked against its sha256; Terra's nightly
# builds cannot be pinned. Built on the image's own base, so they link
# against the wlroots 0.20 the image ships. To move a commit: set it and the
# sha256 of https://github.com/noctalia-dev/<repo>/archive/<commit>.tar.gz
# (the ARGs at the top), check the specs' BuildRequires against meson.build
# and that Lucciola's patches (lucciola/umbriel/*.patch) still apply.
FROM ${BASE_IMAGE} AS umbriel-rpm
ARG UMBRIEL_COMMIT
ARG UMBRIEL_SHA256
ARG UMBRIEL_PORTAL_COMMIT
ARG UMBRIEL_PORTAL_SHA256
COPY lucciola/umbriel/ /src/
RUN --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    env UMBRIEL_COMMIT="${UMBRIEL_COMMIT}" UMBRIEL_SHA256="${UMBRIEL_SHA256}" \
        UMBRIEL_PORTAL_COMMIT="${UMBRIEL_PORTAL_COMMIT}" UMBRIEL_PORTAL_SHA256="${UMBRIEL_PORTAL_SHA256}" \
        bash /src/build-rpm.sh

# ----- The build: Universal Blue silverblue-main:45 unless overridden -----
FROM ${BASE_IMAGE} AS system

# ----- Custom kernel (CachyOS via COPR) + the Margine layer -----
# custom-kernel/install.sh installs the kernel and builds v4l2loopback
# against it, then lists in /usr/share/margine/mok-sign.list what the MOK
# must sign; build.sh runs every build_files/NN-*/install.sh. NO secret in
# this RUN (review N1, 2026-10-20): it installs packages from COPR and RPM
# Fusion, runs their scriptlets as root and executes downloaded programs,
# and until then the MOK private key was mounted next to all of it. The
# key is mounted in the mok-sign stage below and nowhere else; build.sh and
# custom-kernel stop the build if they ever find it
# (refuse_signing_key, 00-common.sh). tests/mok-secret-scope.test.sh keeps
# it that way.
# The whole ctx is mounted: a build_files edit rebuilds this layer.
# /tmp is a tmpfs mount. buildah gives the tmpfs the mode of the
# directory underneath, and the plain Bluefin image ships /tmp as 0755
# (bluefin-dx has 1777); the unprivileged akmods user could not create
# its tempdir there (v4l2loopback silently missing on the trial base,
# 2026-08-25). buildah's tmpfs-mode=1777 option would fix it here, but
# hadolint cannot parse it, so custom-kernel/install.sh chmods /tmp and
# /var/tmp to 1777 before akmods runs instead. At runtime systemd's
# tmp.mount owns /tmp, so this only matters during the build.
# custom-kernel and the Margine modifications share ONE layer on
# purpose (2026-08-18). Committing the kernel layer on its own is what
# tore the rpmdb on current runners: the RUN after it opened with a
# database rpm could not even read to rebuild. Everything that needs a
# healthy rpmdb now lives on the same side of that commit. (--layers=false
# would also work and is what proved the diagnosis, but the runner's
# buildah drops --mount=type=secret in that mode.) Signing no longer needs
# to be in this RUN, so the split stays where it was: the signing reads
# the kernel's files and writes no rpmdb.
# Kernel flavour (2026-10-18). cachyos = kernel-cachyos from COPR, built
# for x86-64-v3, MOK-signed: every published tag but one. fedora = the
# kernel reserve: the base's own Fedora kernel stays, signed by Fedora and
# built for any x86-64 CPU; everything else is the same build.
# build-fedora-kernel.yml passes --build-arg KERNEL_FLAVOR=fedora and
# publishes :fedora-kernel (custom-kernel/install.sh says what differs).
ARG KERNEL_FLAVOR=cachyos
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    env KERNEL_FLAVOR="${KERNEL_FLAVOR}" /ctx/custom-kernel/install.sh \
 && /ctx/build.sh

# ----- MOK signing: the only RUN that sees the private key -----
# FROM the clean base, not from the build above: every program the signer
# calls (bash, openssl, systemd-sbsign, xz, zstd, gzip) is the base's own,
# so no package scriptlet or build step can have replaced one of them to
# catch the key. Nothing is installed here, the RUN has no network, and the
# build's kernel and modules come in read-only as data, with the list of
# what to sign. Out come the signed files, a manifest (sha256 before and
# after) and the public certificate, which the last RUN puts in place
# after checking that the image still holds exactly the files signed here.
# Cache: this stage reruns when the build above or mok-sign.sh changes, not
# for Lucciola-only edits (it reads the system stage, before lucciola/).
FROM ${BASE_IMAGE} AS mok-sign
RUN --network=none \
    --mount=type=bind,from=mok-sign-ctx,source=/mok-sign.sh,target=/ctx/mok-sign.sh \
    --mount=type=bind,from=system,source=/usr/lib/modules,target=/in/modules \
    --mount=type=bind,from=system,source=/usr/share/margine/mok-sign.list,target=/in/mok-sign.list \
    --mount=type=tmpfs,dst=/tmp \
    --mount=type=secret,id=mok-key,target=/run/margine-certs/MOK.key \
    --mount=type=secret,id=mok-cert,target=/run/margine-certs/MOK.pem \
    bash /ctx/mok-sign.sh /in/modules /in/mok-sign.list /out

# ----- The image: the build above, then Lucciola, then the signed kernel -----
FROM system

# ----- Lucciola: Umbriel + Noctalia, GNOME kept stock as the fallback session -----
# What used to be the second build FROM the published Margine image
# (lucciola/Containerfile until 2026-10), now a step of this one: the
# Lucciola files, then lucciola/build.sh, which installs Umbriel, Noctalia and
# the greetd login screen and sets the public name. It still assumes it runs
# on the finished Margine tree, so it stays after every Margine step.
# Bump only together with a test boot: see the comment in lucciola/build.sh.
# Version and release only: build.sh adds the base's Fedora tag (.fc44, .fc45).
# The build does not depend on the repositories still having that build:
# when they drop it, build.sh installs Koji's signed copy of it (2026-10-20).
ARG NOCTALIA_VR=5.6.0-1
# The greeter RPM comes from the greeter-rpm stage; build.sh installs exactly
# the version that stage built (the ARG at the top).
ARG NOCTALIA_GREETER_VERSION
ARG LUMINOUS_VERSION
ARG UMBRIEL_COMMIT
COPY lucciola/system_files/ /
# The website's single page carries the guide; a copy ships so the Lucciola
# Guide launcher opens it without a network (/usr/libexec/margine/guide-open).
COPY site/index.html /usr/share/lucciola/guide/index.html
# 00-common.sh alone from ctx, for the shared helpers build.sh sources: the
# whole ctx would tie this layer's cache to every build_files edit.
RUN --mount=type=bind,from=lucciola-ctx,source=/build.sh,target=/ctx/lucciola/build.sh \
    --mount=type=bind,from=ctx,source=/00-common.sh,target=/ctx/00-common.sh \
    --mount=type=bind,from=greeter-rpm,source=/out,target=/ctx/greeter-rpm \
    --mount=type=bind,from=luminous-rpm,source=/out,target=/ctx/luminous-rpm \
    --mount=type=bind,from=umbriel-rpm,source=/out,target=/ctx/umbriel-rpm \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    env NOCTALIA_VR="${NOCTALIA_VR}" NOCTALIA_GREETER_VERSION="${NOCTALIA_GREETER_VERSION}" \
        LUMINOUS_VERSION="${LUMINOUS_VERSION}" UMBRIEL_COMMIT="${UMBRIEL_COMMIT}" \
        bash /ctx/lucciola/build.sh

# ----- Signed kernel in place, initramfs, residue sweep, lint -----
# custom-kernel/finalize.sh puts the mok-sign stage's signed vmlinuz and
# modules in place (refusing them unless the image still holds exactly the
# files that were signed), installs the MOK certificate, checks the
# signatures and writes the initramfs, which packs the signed modules.
# No secret here either: what it mounts from mok-sign is public.
# 99-cleanup.sh removes the /var state the build's dnf/rpm transactions
# leave behind (dead weight on installed systems — bootc only uses image
# /var as a first-boot seed). Chained into the same RUN so the lint
# always judges the cleaned tree.
RUN --mount=type=bind,from=ctx,source=/00-common.sh,target=/ctx/00-common.sh \
    --mount=type=bind,from=ctx,source=/custom-kernel/finalize.sh,target=/ctx/custom-kernel/finalize.sh \
    --mount=type=bind,from=mok-sign,source=/out,target=/ctx/signed \
    --mount=type=bind,from=ctx,source=/99-cleanup.sh,target=/ctx/99-cleanup.sh \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/custom-kernel/finalize.sh && /ctx/99-cleanup.sh && bootc container lint
