#!/usr/bin/env bash
# Margine image build — section: 30-gnome-defaults
# Sub-script of the build.sh orchestrator. Decomposed on 2026-06-06
# (audit §8 rec #22 — split build.sh into per-area install scripts).
# See build_files/00-common.sh + build_files/build.sh.
set -euo pipefail
. /ctx/00-common.sh

# Seahorse: the GUI for saved passwords (any Secret Service, oo7 from
# Fedora 45) and for SSH and GPG keys. On Fedora 44 it backed
# `ujust lucciola-keyring blank`; oo7 has no empty keyring password, and
# lucciola-keyring uses a TPM-bound credential instead (see that script).
log "Installing seahorse (saved passwords and keys GUI)"
dnf -y install --setopt=install_weak_deps=False seahorse

# 2. GTK defaults (gschema override)
# ---------------------------------------------------------------------------
# A gschema override named zz1-* so it loads after the base's own
# (00_*, 10_*). It carries only what the GTK applications of a Lucciola
# session read: the accent colour here, the virt-manager connections, and
# the wallpaper 50-branding appends. GNOME is Lucciola's stock fallback
# session (2026-10-18): Margine's Shell, mutter and window-manager defaults
# (enabled extensions, dock favourites, five fixed workspaces, sloppy focus,
# Super+D) and its dconf keyfiles for the extensions, the tiling keybindings
# and the Smile shortcut are not in the image any more.
log "Writing zz1-margine.gschema.override"

cat > /usr/share/glib-2.0/schemas/zz1-margine.gschema.override <<'OVERRIDE'
[org.gnome.desktop.interface]
accent-color='yellow'
# Fonts stay GNOME's defaults: no Margine type system has been picked yet.

# virt-manager — show the rootless USER SESSION out of the box (UX, not branding).
# `ujust lucciola-test-vm` and the ISO-creator GUI put their throwaway test VMs on
# qemu:///session (rootless: reads ISOs straight from $HOME, no polkit). But
# virt-manager's stock default is uris=[] and it only auto-adds qemu:///system on
# first launch — so those session VMs are INVISIBLE in the default window (I
# hit this 2026-06-30: 48 GB of test VMs I could not see). Seed both connections
# and autoconnect the session so a fresh Margine surfaces the test VMs the moment
# virt-manager opens. Only sets the OOTB default; the GUI can still add/remove
# connections (a user who edits the list just overrides this).
[org.virt-manager.virt-manager.connections]
uris=['qemu:///system', 'qemu:///session']
autoconnect=['qemu:///session']

# Ptyxis: a new terminal starts in the home folder. Upstream restores the
# last session, tabs and working folders included, which reopened terminals
# in whatever folder the last one was closed in (2026-10-19, seen on a
# system moved from Margine). A user who wants it back turns it on in
# Ptyxis' preferences.
[org.gnome.Ptyxis]
restore-session=false
OVERRIDE

# The dconf profile reads the distro database (authselect's defaults live
# there). The base's profile already lists it; this keeps it that way.
mkdir -p /etc/dconf/profile
if [[ ! -f /etc/dconf/profile/user ]]; then
  cat > /etc/dconf/profile/user <<'PROFILE'
user-db:user
system-db:local
system-db:site
system-db:distro
PROFILE
elif ! grep -qxF 'system-db:distro' /etc/dconf/profile/user; then
  printf '\nsystem-db:distro\n' >> /etc/dconf/profile/user
fi

if command -v dconf >/dev/null 2>&1; then
  dconf update
fi

# ---------------------------------------------------------------------------
# Surgical icon fix: replace ONE low-res Adwaita Legacy PNG
# ---------------------------------------------------------------------------
# Verified 2026-06-05: margine-system-update.desktop's `Icon=system-
# software-update` rendered as a blurry low-res sprite because the
# only system-software-update icon in Bluefin DX's image is the
# AdwaitaLegacy 48×48 PNG. Earlier attempt (PR #32) installed the
# whole MoreWaita icon theme + set it as system default — daniel
# rejected that as overkill ("anziché scaricare svg dell'icona e
# applicare quello, imposti MOREWAITA SU TUTTO IL SISTEMA?").
#
# Surgical fix: download just the ONE high-res SVG from MoreWaita
# and place it as Adwaita's scalable override for the icon name
# `system-software-update`. Adwaita's scalable/ entries win over
# its legacy PNGs at any rendering size, so the launcher draws
# crisp at any DPI without touching the user's icon theme. No
# tar download, no theme switch, no behaviour change anywhere
# else in the desktop.
# Pinned to a MoreWaita commit + sha256-verified. This is a third-party
# asset baked into the image, so a moving `main` (or a compromise of it)
# must not be able to silently swap the shipped SVG. Bump SHA + checksum
# together when refreshing the icon.
MOREWAITA_SHA="53bc2ba9c2cdc1f26ef822fcdd8a95e01cce5d58"
MOREWAITA_SHA256="5ad21425761a7b22feaa5e8ff2681dc6743dffee76fcaab97220ae7d91ea8753"
MOREWAITA_RAW="https://raw.githubusercontent.com/somepaulo/MoreWaita/${MOREWAITA_SHA}/scalable/legacy/system-software-update.svg"
SYSUPDATE_TARGET="/usr/share/icons/Adwaita/scalable/apps/system-software-update.svg"
log "Downloading high-res system-software-update.svg from MoreWaita → $SYSUPDATE_TARGET"
MOREWAITA_TMP="$(mktemp)"
if curl -fL --retry 5 --retry-delay 10 -sS -o "$MOREWAITA_TMP" "$MOREWAITA_RAW" \
   && echo "${MOREWAITA_SHA256}  ${MOREWAITA_TMP}" | sha256sum -c - >/dev/null 2>&1; then
  install -Dm0644 "$MOREWAITA_TMP" "$SYSUPDATE_TARGET"
  # Refresh Adwaita icon cache so gtk apps see the new SVG.
  gtk-update-icon-cache -q -t -f /usr/share/icons/Adwaita || true
  log "system-software-update.svg installed ($(stat -c %s "$SYSUPDATE_TARGET") bytes)"
  # Not an RPM: recorded for the SBOM (review N9, see 70-phone-cam).
  python3 /ctx/sbom-component.py --name morewaita-system-software-update --version "0+git${MOREWAITA_SHA:0:12}" \
    --supplier "Person: somepaulo" --url "$MOREWAITA_RAW" --sha256 "$MOREWAITA_SHA256" \
    --license GPL-3.0-only --purl "pkg:github/somepaulo/MoreWaita@${MOREWAITA_SHA}#scalable/legacy/system-software-update.svg" \
    --note "One icon of the MoreWaita theme, as Adwaita's scalable system-software-update." \
    "$SYSUPDATE_TARGET"
else
  log "WARN: system-software-update.svg download/verify failed — launcher icon stays blurry"
fi
rm -f "$MOREWAITA_TMP"

log "Compiling glib schemas"
glib-compile-schemas /usr/share/glib-2.0/schemas

# ---------------------------------------------------------------------------
