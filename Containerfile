# =============================================================================
# Lucciola: a bootc image on Fedora Silverblue (Universal Blue main), CachyOS
# kernel, niri with the Noctalia shell
# =============================================================================
#
# This Containerfile composes the Lucciola image as:
#
#   FROM ghcr.io/ublue-os/silverblue-main:44  (Universal Blue main: Fedora Silverblue 44)
#   + custom kernel from CachyOS COPR (signed with our MOK)
#   + the Margine OS layer (build_files/: update flow, Secure Boot and TPM
#     tooling, branding, the GTK defaults, Flatpaks)
#   + the Lucciola layer (lucciola/: niri, Noctalia, the Lucciola session;
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
ARG BASE_IMAGE=ghcr.io/ublue-os/silverblue-main:45
# Noctalia Greeter's pinned tag and the sha256 of its archive: declared here,
# before any FROM, so the stage that builds it and the step that installs it
# read the same value (see the greeter-rpm stage).
ARG NOCTALIA_GREETER_VERSION=1.6.0
ARG NOCTALIA_GREETER_SHA256=f23ebf07cbe4508971c08b0b81d2b5bfc4ec1ec45605d8f8fb01b799743a70b6

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

# lucciola/build.sh gets a context stage of its own, not a place in ctx:
# the kernel RUN below mounts the whole ctx, and an edit to the Lucciola
# step must not throw away that layer's cache. (A bind mount straight from
# the build context would do the same, but a rootless podman build on an
# SELinux host cannot read it: "Permission denied", tried 2026-10-17.)
FROM scratch AS lucciola-ctx
COPY lucciola/build.sh /build.sh

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
# meson.build, test-boot. v1.6.0 is commit
# 44337ecba043749c29de6f3d563315b91987a908 (a signed tag).
FROM ${BASE_IMAGE} AS greeter-rpm
ARG NOCTALIA_GREETER_VERSION
ARG NOCTALIA_GREETER_SHA256
COPY lucciola/greeter/ /src/
RUN --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    env NOCTALIA_GREETER_VERSION="${NOCTALIA_GREETER_VERSION}" \
        NOCTALIA_GREETER_SHA256="${NOCTALIA_GREETER_SHA256}" \
        bash /src/build-rpm.sh

# ----- Base: Universal Blue silverblue-main:44 unless overridden -----
FROM ${BASE_IMAGE}

# ----- Custom kernel: CachyOS via COPR + MOK signing -----
# Mounts the custom-kernel scripts from the ctx layer and the MOK signing
# keys from BuildKit secrets. After this layer, /usr/lib/modules/<KVER>/vmlinuz
# is the CachyOS kernel image signed with our MOK key — boots cleanly under
# Secure Boot once the user enrolls MOK.der via mokutil (one-time).
# Mount ONLY what the kernel layer reads (its own scripts + the shared
# helpers): with the whole ctx mounted, ANY build_files edit — a
# branding tweak, a just recipe — invalidated this 25-minute layer's
# cache (review P2.5). Narrow mounts keep the cache key tied to the
# files that actually matter here.
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
# buildah drops --mount=type=secret in that mode, and the kernel layer
# is the one place we need the MOK key.)
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    --mount=type=secret,id=mok-key,target=/run/margine-certs/MOK.key \
    --mount=type=secret,id=mok-cert,target=/run/margine-certs/MOK.pem \
    /ctx/custom-kernel/install.sh \
 && /ctx/build.sh

# ----- Lucciola: niri + Noctalia, GNOME kept stock as the fallback session -----
# What used to be the second build FROM the published Margine image
# (lucciola/Containerfile until 2026-10), now a step of this one: the
# Lucciola files, then lucciola/build.sh, which installs niri, Noctalia and
# the greetd login screen and sets the public name. It still assumes it runs
# on the finished Margine tree, so it stays after every Margine step.
# Bump only together with a test boot: see the comment in lucciola/build.sh.
# Version and release only: build.sh adds the base's Fedora tag (.fc44, .fc45).
ARG NOCTALIA_VR=5.3.0-1
# The greeter RPM comes from the greeter-rpm stage; build.sh installs exactly
# the version that stage built (the ARG at the top).
ARG NOCTALIA_GREETER_VERSION
COPY lucciola/system_files/ /
RUN --mount=type=bind,from=lucciola-ctx,source=/build.sh,target=/ctx/lucciola/build.sh \
    --mount=type=bind,from=greeter-rpm,source=/out,target=/ctx/greeter-rpm \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    env NOCTALIA_VR="${NOCTALIA_VR}" NOCTALIA_GREETER_VERSION="${NOCTALIA_GREETER_VERSION}" \
        bash /ctx/lucciola/build.sh

# ----- Build-residue sweep + lint: verify final image is a valid bootc container -----
# 99-cleanup.sh removes the /var state the build's dnf/rpm transactions
# leave behind (dead weight on installed systems — bootc only uses image
# /var as a first-boot seed). Chained into the same RUN so the lint
# always judges the cleaned tree.
RUN --mount=type=bind,from=ctx,source=/99-cleanup.sh,target=/ctx/99-cleanup.sh \
    /ctx/99-cleanup.sh && bootc container lint
