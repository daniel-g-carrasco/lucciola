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
# The system update launcher's icon
# ---------------------------------------------------------------------------
# margine-system-update.desktop uses its own icon, margine-system-update,
# a tracked file in system_files in the family style (docs/BRANDING.md,
# "App icons: the family style"). Until 2026-10-21 it used the stock name
# system-software-update, whose only copy in the base image was a 48 px
# PNG, so a pinned high-res SVG was downloaded from MoreWaita at build time
# and placed in Adwaita's scalable/ directory. Nothing in Lucciola names
# system-software-update now, and no third-party asset is fetched here.

log "Compiling glib schemas"
glib-compile-schemas /usr/share/glib-2.0/schemas

# ---------------------------------------------------------------------------
