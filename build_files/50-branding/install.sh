#!/usr/bin/env bash
# Margine image build — section: 50-branding
# Sub-script of the build.sh orchestrator. Decomposed on 2026-06-06
# (audit §8 rec #22 — split build.sh into per-area install scripts).
# See build_files/00-common.sh + build_files/build.sh.
set -euo pipefail
. /ctx/00-common.sh

# 4. Visual branding: Lucciola's (logo, wallpaper, Plymouth, /etc/issue, fastfetch)
# ---------------------------------------------------------------------------
# The assets are Lucciola's brand, lucciola/assets/ in the repository
# (mounted at /ctx/lucciola-assets; the PNGs are rendered there by
# render.sh and committed). They go to the standard system locations so
# every surface that shows the system's identity (About panel, wallpaper,
# login screens, boot splash, console, fastfetch, notifications) shows
# Lucciola's, not the base's. Margine OS's own assets left on 2026-10-18;
# the names Fedora, GNOME and older files hardcode stay, as aliases.
log "Installing Lucciola visual branding"
A=/ctx/lucciola-assets
need() { [[ -s "$1" ]] || { log "FATAL: required branding asset is empty or missing: $1"; exit 1; }; }

# (a) Logo. Two icon names, both in hicolor so the icon theme finds them:
#   lucciola-logo  the firefly on its dark rounded tile: the OS and app icon
#                  (os-release LOGO=, notifications, the About panel);
#   lucciola-mark  the firefly alone, for places with a dark background of
#                  their own (and lucciola-mark-symbolic, its symbolic form).
# Each as scalable SVG; the tile also at the fixed hicolor sizes, because
# notification daemons and the lock screen pick a raster size when one
# exists, and in /usr/share/pixmaps for consumers outside the icon theme.
# The GNOME About panel looks LOGO= up in the icon theme only (GTK4
# FORCE_REGULAR lookup, no pixmaps fallback), so the scalable SVG is the
# one that matters there.
for f in lucciola-logo.svg lucciola-mark.svg lucciola-mark-symbolic.svg; do need "$A/$f"; done
install -Dm0644 "$A/lucciola-logo.svg" /usr/share/icons/hicolor/scalable/apps/lucciola-logo.svg
install -Dm0644 "$A/lucciola-mark.svg" /usr/share/icons/hicolor/scalable/apps/lucciola-mark.svg
install -Dm0644 "$A/lucciola-mark-symbolic.svg" /usr/share/icons/hicolor/symbolic/apps/lucciola-mark-symbolic.svg
for n in 16 24 32 48 64 128 256 512; do
  need "$A/icons/lucciola-logo-$n.png"
  install -Dm0644 "$A/icons/lucciola-logo-$n.png" "/usr/share/icons/hicolor/${n}x${n}/apps/lucciola-logo.png"
done
need "$A/icons/lucciola-mark-256.png"
install -Dm0644 "$A/icons/lucciola-mark-256.png" /usr/share/icons/hicolor/256x256/apps/lucciola-mark.png
# The firefly as the default account picture: lucciola-default-avatar.service
# copies it into AccountsService for every account without a picture, and
# the login screen shows it (64 px, 128 at scale 2; 256 leaves room).
install -Dm0644 "$A/icons/lucciola-mark-256.png" /usr/share/lucciola/avatar/lucciola.png
install -Dm0644 "$A/icons/lucciola-logo-256.png" /usr/share/pixmaps/lucciola-logo.png
# margine-logo: the old name, now carrying the Lucciola tile. The live
# ISO's installer icon (docs/history/margine/live-env/src/build.sh), a notification sent by an
# older helper or a launcher a user copied may still name it.
install -Dm0644 "$A/lucciola-logo.svg" /usr/share/icons/hicolor/scalable/apps/margine-logo.svg
install -Dm0644 "$A/icons/lucciola-logo-256.png" /usr/share/pixmaps/margine-logo.png
gtk-update-icon-cache -f -t -q /usr/share/icons/hicolor 2>/dev/null || true
log "Installed lucciola-logo (tile) and lucciola-mark: hicolor scalable + raster sizes, pixmaps; margine-logo kept as an alias"

# (b) Wallpaper: dusk over dark hills with a few fireflies
#     (lucciola/assets/wallpaper/make-wallpaper.py). lucciola.png is the 16:9
#     render and the default everywhere (GNOME and its lock screen, GDM,
#     Noctalia through 15-wallpaper.toml); the 3:2 and 16:10 renders sit
#     next to it for screens of those shapes. The login screen has no
#     picture (the greeter's greeter.toml: a plain #121212).
install -d -m0755 /usr/share/backgrounds/lucciola
for size in 3840x2160 2880x1920 2560x1600; do
  need "$A/wallpaper/lucciola-$size.png"
  install -m0644 "$A/wallpaper/lucciola-$size.png" "/usr/share/backgrounds/lucciola/lucciola-$size.png"
done
ln -sf lucciola-3840x2160.png /usr/share/backgrounds/lucciola/lucciola.png
# Margine's paths stay, as links to the new wallpaper: the login screen's
# sync.toml on installed systems (copied once, never rewritten) and anyone
# who picked the old file by its path get the new wallpaper instead of a
# blank screen. autumn-leaves.png is the name from before 2026-05-30.
install -d -m0755 /usr/share/backgrounds/margine
ln -sf ../lucciola/lucciola.png /usr/share/backgrounds/margine/margine.png
ln -sf ../lucciola/lucciola.png /usr/share/backgrounds/margine/autumn-leaves.png
log "Installed: /usr/share/backgrounds/lucciola/ (+ margine.png, autumn-leaves.png compat links)"

# Desktop background gschema override: appended to the zz1 file
# 30-gnome-defaults writes, so it loads after the base's own.
cat >> /usr/share/glib-2.0/schemas/zz1-margine.gschema.override <<'OVERRIDE'

[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/lucciola/lucciola.png'
picture-uri-dark='file:///usr/share/backgrounds/lucciola/lucciola.png'
picture-options='zoom'
primary-color='#121212'
secondary-color='#121212'

[org.gnome.desktop.screensaver]
picture-uri='file:///usr/share/backgrounds/lucciola/lucciola.png'
picture-options='zoom'
primary-color='#121212'
OVERRIDE

# (c) Plymouth theme: /usr/share/plymouth/themes/lucciola/ (the wordmark,
# its breathing firefly, the disk unlock prompt; lucciola.script says how).
# A script theme: it needs the script plugin (script.so), which the base
# does not ship.
log "Installing plymouth-plugin-script (required by the script-based theme)"
dnf -y install plymouth-plugin-script

P=/usr/share/plymouth/themes/lucciola
install -d -m0755 "$P"
need "$A/plymouth/lucciola.plymouth"; need "$A/plymouth/lucciola.script"
install -m0644 "$A/plymouth/lucciola.plymouth" "$A/plymouth/lucciola.script" "$P/"
for f in "$A"/plymouth/{wordmark,firefly,field,bullet}-*.png; do
  need "$f"; install -m0644 "$f" "$P/"
done
# Every image the script asks for must be there: it builds the names
# (wordmark-<size>.png), so a size added to a ladder without its render
# would only show at boot, as a missing logo.
python3 - "$P" <<'PYCHECK'
import os, re, sys
d = sys.argv[1]
s = open(os.path.join(d, "lucciola.script")).read()
def ladder(name):
    return [int(v) for v in re.findall(name + r"\[\d+\]\s*=\s*(\d+);", s)]
missing = []
for prefix, ladder_name in (("wordmark", "word_ladder"), ("firefly", "word_ladder"),
                            ("field", "field_ladder"), ("bullet", "field_ladder")):
    sizes = ladder(ladder_name)
    if not sizes:
        sys.exit(f"ERROR: lucciola.script: no {ladder_name} sizes found")
    missing += [f"{prefix}-{n}.png" for n in sizes if not os.path.isfile(os.path.join(d, f"{prefix}-{n}.png"))]
if missing:
    sys.exit("ERROR: Plymouth images missing: " + ", ".join(missing))
PYCHECK
log "Installed: $P ($(find "$P" -name '*.png' | wc -l) images)"

# Lucciola as the default theme, and DeviceScale=1. With Plymouth's own
# HiDPI scale (2 on the 2880x1920 reference laptop) every image and text
# label of a script theme is drawn at scale 1 and stretched 2x, soft; the
# theme sizes everything from the screen in device pixels instead. A boot
# with plymouth.force-scale=2 on the kernel command line (which wins)
# still shows it, only softer. plymouth-populate-initrd copies this file
# into the initramfs, with the theme.
plymouth-set-default-theme lucciola
conf=/etc/plymouth/plymouthd.conf
grep -q '^\[Daemon\]' "$conf" || printf '[Daemon]\n' >> "$conf"
sed -i '/^DeviceScale=/d' "$conf"
sed -i '0,/^\[Daemon\]/s//[Daemon]\nDeviceScale=1/' "$conf"
grep -qx 'Theme=lucciola' "$conf" && grep -qx 'DeviceScale=1' "$conf" \
  || { log "ERROR: $conf does not select the lucciola theme at DeviceScale=1: $(tr '\n' ' ' < "$conf")"; exit 1; }
log "Set Plymouth default theme: lucciola, DeviceScale=1"
# THE initramfs of the build (2026-10-18: custom-kernel no longer makes a
# first one that this run always replaced). Output goes to
# /usr/lib/modules/<KVER>/initramfs.img, the bootc/ostree-expected path.
# regenerate_initramfs (00-common.sh): generic (custom-kernel's
# 01-margine-no-hostonly.conf), --add ostree (without which switch-root
# fails, see custom-kernel/install.sh), zstd, and byte-reproducible (same
# packages, same bytes, whatever the build date).
command -v dracut >/dev/null 2>&1 || { log "ERROR: dracut missing: no initramfs, no boot"; exit 1; }
for kver_dir in /usr/lib/modules/*/; do
  kver=$(basename "$kver_dir")
  regenerate_initramfs "$kver" || { log "ERROR: dracut failed for $kver"; exit 1; }
  [[ -s "${kver_dir}initramfs.img" ]] || { log "ERROR: no initramfs written for $kver"; exit 1; }
  # The splash is only what the initramfs carries: the theme, its plugin,
  # the text renderer and the configuration with DeviceScale.
  ird="$(lsinitrd "${kver_dir}initramfs.img" 2>/dev/null || true)"
  for want in usr/share/plymouth/themes/lucciola/lucciola.script usr/share/plymouth/themes/lucciola/wordmark-720.png \
              usr/lib64/plymouth/script.so usr/lib64/plymouth/label-freetype.so; do
    grep -q " ${want}\$" <<<"$ird" || { log "ERROR: the initramfs for $kver lacks $want"; exit 1; }
  done
  lsinitrd -f etc/plymouth/plymouthd.conf "${kver_dir}initramfs.img" 2>/dev/null | grep -qx 'DeviceScale=1' \
    || { log "ERROR: the initramfs for $kver has no DeviceScale=1 in plymouthd.conf"; exit 1; }
  log "Wrote ${kver_dir}initramfs.img ($(du -h "${kver_dir}initramfs.img" | cut -f1), Plymouth theme lucciola)"
done
# vmlinuz must still be the bytes custom-kernel signed (its checksum,
# left in this RUN's /tmp): a rewrite would ship a kernel Secure Boot
# rejects with the cryptic "bad shim signature".
if [[ -f /tmp/vmlinuz.sha ]]; then
  sha256sum -c /tmp/vmlinuz.sha >/dev/null || { log "ERROR: vmlinuz changed after signing"; exit 1; }
  rm -f /tmp/vmlinuz.sha
  log "vmlinuz still the signed bytes after dracut"
fi

# (d) GDM login screen background — system dconf override.
mkdir -p /etc/dconf/db/gdm.d /etc/dconf/profile
cat > /etc/dconf/profile/gdm <<'EOF'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
EOF
cat > /etc/dconf/db/gdm.d/01-margine-background <<'EOF'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/lucciola/lucciola.png'
picture-uri-dark='file:///usr/share/backgrounds/lucciola/lucciola.png'
picture-options='zoom'
primary-color='#121212'
EOF
# (d.ter) Replace Bluefin's "F"-logo SVG with a fully transparent one.
# Bluefin DX drops its own logo into
# /usr/share/icons/hicolor/scalable/places/fedora-logo-sprite.svg (the
# file is not owned by any RPM — it's overlaid by Bluefin's build).
# GNOME greeter / about widgets that look up "fedora-logo-sprite" by
# icon name therefore render the Bluefin "F" in our images too.
# Overwrite with a 296×296 empty SVG so any consumer of that icon
# name renders nothing.
SPRITE=/usr/share/icons/hicolor/scalable/places/fedora-logo-sprite.svg
if [[ -f "$SPRITE" ]]; then
  cat > "$SPRITE" <<'SVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="296" height="296" viewBox="0 0 296 296"/>
SVG
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
  fi
  log "Replaced Bluefin's fedora-logo-sprite.svg with transparent placeholder"
fi

# (d.bis-pre) Nuke Fedora/Bluefin logo fallbacks GNOME might resolve by
# icon name, but keep the two Fedora pixmap paths that Fedora's
# gnome-control-center build hard-codes for the About panel:
#
#   /usr/share/pixmaps/fedora_logo_med.png
#   /usr/share/pixmaps/fedora_whitelogo_med.png
#
# Those are not lookup fallbacks; they are compile-time filenames in
# Fedora's gnome-control-center.spec. Deleting them makes the About
# panel show no distributor logo, so overwrite them with Lucciola's
# wordmark instead.
#
# Confirmed on 2026-06-06 diagnose dump (daniel margine VM):
#   /usr/share/pixmaps/fedora-gdm-logo.png        (5.6 KB,  150×61)
#   /usr/share/pixmaps/fedora-logo-icon.png       (336 KB,  733×501)
#   /usr/share/pixmaps/fedora_logo_med.png        (10 KB,   250×102)
#   /usr/share/pixmaps/fedora-logo.png            (41 KB,   256×256)
#   /usr/share/pixmaps/fedora-logo-small.png      (3.3 KB,  48×48)
#   /usr/share/pixmaps/fedora-logo-sprite.png     (32 KB,   400×400)
#   /usr/share/pixmaps/fedora-logo-sprite.svg     (243 KB,  scalable)
#   /usr/share/pixmaps/fedora_whitelogo_med.png   (11 KB,   250×102)
#   /usr/share/pixmaps/system-logo-white.png      (41 KB,   256×256)
#   /usr/share/icons/hicolor/scalable/apps/fedora-logo-icon.svg
#   /usr/share/icons/hicolor/scalable/apps/fedora-logo-sprite.svg
# Plus /usr/share/icons/hicolor/scalable/places/fedora-logo-sprite.svg
# which we already blank at (d.ter) below — leave that alone.
rm -f /usr/share/pixmaps/fedora-gdm-logo.png \
      /usr/share/pixmaps/fedora-logo.png \
      /usr/share/pixmaps/fedora-logo-small.png \
      /usr/share/pixmaps/fedora-logo-sprite.png \
      /usr/share/pixmaps/fedora-logo-sprite.svg \
      /usr/share/pixmaps/system-logo-white.png \
      /usr/share/icons/hicolor/scalable/apps/fedora-logo-sprite.svg

# fedora-logo-icon is NOT deleted but REPLACED with the Lucciola tile
# (Bluefin pattern: keep Fedora icon NAMES, swap content). The name is
# HARDCODED in components we cannot rebuild: anaconda-live's
# fedora-welcome dialog (Adw.StatusPage iconName) + its autostart
# .desktop on the live ISO, and gnome-initial-setup's language page
# (maps os-release ID=fedora -> fedora-logo-icon). Deleting it (as we
# did before) renders the image-missing placeholder on both welcomes.
cp /usr/share/icons/hicolor/scalable/apps/lucciola-logo.svg \
   /usr/share/icons/hicolor/scalable/apps/fedora-logo-icon.svg
cp /usr/share/pixmaps/lucciola-logo.png /usr/share/pixmaps/fedora-logo-icon.png
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t -q /usr/share/icons/hicolor 2>/dev/null || true
fi
log "fedora-logo-icon now carries the Lucciola tile (fedora-welcome + gnome-initial-setup hardcode this name)"
# About-panel distributor logo = the Lucciola WORDMARK, not the tile.
# fedora_logo_med.png is shown on LIGHT backgrounds (the dark word,
# lucciola-wordmark-light.svg); fedora_whitelogo_med.png on DARK
# backgrounds (the light word, lucciola-wordmark.svg). gnome-control-center
# renders these with GtkPicture can-shrink=false: intrinsic pixel size ==
# logical size, so the renders are 256x59 (Fedora's originals are
# 250x102); a 1200x300 one rendered 5x oversized at 200% scale.
need "$A/about/wordmark-on-light.png"; need "$A/about/wordmark-on-dark.png"
install -m0644 "$A/about/wordmark-on-light.png" /usr/share/pixmaps/fedora_logo_med.png
install -m0644 "$A/about/wordmark-on-dark.png" /usr/share/pixmaps/fedora_whitelogo_med.png
log "About-panel distributor logo set to the Lucciola wordmark (dark word on light, light word on dark)"

# (d.bis) GDM greeter logo — explicitly DISABLED.
# The default org.gnome.login-screen.logo points at
# /usr/share/pixmaps/fedora-gdm-logo.png which on Bluefin DX is
# physically replaced with Bluefin's logo file. Pointing it at
# /usr/share/pixmaps/margine-logo.png produced a horrible result:
# our logo asset is a 2400×700 horizontal banner sized for headers,
# and GDM scales it to nearly fullscreen behind the password field.
# Cleanest fix: empty-string the key so GDM renders no logo at all.
cat > /etc/dconf/db/gdm.d/02-margine-logo <<'EOF'
[org/gnome/login-screen]
logo=''
EOF
mkdir -p /etc/dconf/db/gdm.d/locks
cat > /etc/dconf/db/gdm.d/locks/02-margine-logo <<'EOF'
/org/gnome/login-screen/logo
EOF
# Compile the gdm dconf db (best-effort; safe to skip if dconf is absent).
if command -v dconf >/dev/null 2>&1; then
  dconf update || { log "ERROR: dconf update failed — distro defaults database would ship stale/absent"; exit 1; }
fi
log "Installed: GDM background + greeter logo overrides"

# (e) /etc/issue — text-mode banner shown on console (e.g. emergency shell)
# The kernel reserve (custom-kernel's kernel-flavor marker) names its own.
kernel_desc="CachyOS signed kernel"
[[ "$(cat /usr/share/margine/kernel-flavor 2>/dev/null)" == fedora ]] && kernel_desc="Fedora's kernel"
cat > /etc/issue <<EOF
Lucciola \\r (\\m): Fedora Silverblue + ${kernel_desc}
\\d \\t

EOF
chmod 0644 /etc/issue
log "Installed: /etc/issue"

# (f) Fastfetch config + lucciola-fetch wrapper.
# Fetch the ASCII logo and use it as fastfetch's --logo source.
mkdir -p /usr/share/fastfetch /usr/share/margine
# Lucciola's firefly in shaded blocks over the name; margine.jsonc colours
# it in the palette ($1 beige, $2 sand, $3 the halo, $4 the text).
need "$A/fastfetch-logo.txt"
cp "$A/fastfetch-logo.txt" /usr/share/margine/ascii-logo.txt
chmod 0644 /usr/share/margine/ascii-logo.txt

# margine.jsonc + the lucciola-fetch wrapper ship as tracked files via
# system_files (migrated out of heredocs 2026-06-12 so linters and
# reviewers actually see them).

# (f.bis) System-wide fastfetch default config.
# Without this, vanilla `fastfetch` (no --config) walks its own search
# path: $XDG_CONFIG_HOME/fastfetch/config.jsonc (user, empty on a fresh
# install) → /etc/fastfetch/config.jsonc (we own this slot) →
# built-in default (= Fedora ASCII logo). `fastfetch` was noticed
# was showing Fedora art instead of Margine even though
# /usr/share/margine/ascii-logo.txt was correctly installed.
# /etc/fastfetch/config.jsonc is a system_files symlink to
# margine.jsonc (was a build-time copy — one less divergence point).
log "fastfetch default config: system_files symlink /etc/fastfetch/config.jsonc → margine.jsonc"

# Recompile glib schemas so the appended background override takes effect.
glib-compile-schemas /usr/share/glib-2.0/schemas

# ---------------------------------------------------------------------------
# 4.bis Strip residual Bluefin/ublue branding from the inherited image
# ---------------------------------------------------------------------------
# Bluefin DX ships a pile of assets that bleed through into Margine's
# user-facing surfaces: app menu entries pointing at projectbluefin.io,
# a "/usr/share/backgrounds/bluefin/" wallpaper collection that shows
# up in Settings → Background, /usr/share/ublue-os/bluefin-logos/
# (chicken.png, dolly.png, karl.png mascots etc.), and a Firefox
# distribution config that injects Bluefin homepage/bookmarks.
#
# We can't avoid pulling them at build time (they're in the upstream
# RPMs), but we can scrub them after install. The dirs we DO keep
# under /usr/share/ublue-os/ are the functional ones: etc/ (akmods
# repos + certs), homebrew/, bling/, just/ — they're behavior, not
# branding.
log "Stripping Bluefin/ublue branding leftover from /usr/share + /usr/share/applications"

# (a) Visible app-menu entries that point at Bluefin docs/community.
# `discourse.desktop` opens github.com/ublue-os/bluefin/discussions →
# not a Margine resource at all → delete.
# `documentation.desktop` opens docs.projectbluefin.io → delete. Margine's
# offline docs launcher replaced it until 2026-10-18; Lucciola's guide is
# online and has no address of its own yet, so there is no launcher.
# `system-update.desktop` says "Update Bluefin, Flatpaks, …" → keep
# the underlying uupd flow (Margine uses it too) but rebrand.
rm -f /usr/share/applications/discourse.desktop

SCHEDULER_ICON="/usr/share/icons/hicolor/scalable/apps/margine-scheduler.svg"

# Lightning-bolt app icon for the CPU scheduler — ties to Margine's perf /
# "snappier under load" theme, shipped locally instead of a generic MoreWaita
# system glyph.
cat >"$SCHEDULER_ICON" <<'SCHEDULER_ICON_SVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <defs>
    <linearGradient id="m-sched-bg" x1="64" y1="8" x2="64" y2="120" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#2b2018"/>
      <stop offset="1" stop-color="#171210"/>
    </linearGradient>
    <linearGradient id="m-sched-bolt" x1="64" y1="20" x2="64" y2="108" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#ffc06a"/>
      <stop offset="0.55" stop-color="#f97316"/>
      <stop offset="1" stop-color="#d9480f"/>
    </linearGradient>
  </defs>
  <rect x="8" y="8" width="112" height="112" rx="28" fill="url(#m-sched-bg)"/>
  <rect x="8.5" y="8.5" width="111" height="111" rx="27.5" fill="none" stroke="#ffffff" stroke-opacity="0.06"/>
  <path d="M74 18 L36 70 H58 L54 110 L92 58 H70 Z" fill="url(#m-sched-bolt)" stroke="#ffe0b0" stroke-opacity="0.5" stroke-width="2" stroke-linejoin="round"/>
</svg>
SCHEDULER_ICON_SVG
chmod 0644 "$SCHEDULER_ICON"
# The offline mirror of margine.dev (fetched here at build time, refreshed
# by margine-docs-refresh.timer, opened by margine-docs-open and its
# "Margine Documentation" launcher) left on 2026-10-18: Lucciola's guide
# is online.

# The rebranded system-update entry (margine-system-update) ships as a
# tracked system_files entry; only the Bluefin originals get removed here.
rm -f /usr/share/applications/documentation.desktop
rm -f /usr/share/applications/system-update.desktop

# (b) Icons that only served the deleted/rebrand entries.
rm -f /usr/share/icons/hicolor/scalable/places/ublue-discourse.svg \
      /usr/share/icons/hicolor/scalable/places/ublue-docs.svg \
      /usr/share/icons/hicolor/scalable/places/ublue-update.svg \
      /usr/share/icons/hicolor/scalable/actions/ublue-logo-symbolic.svg

# (b.bis) gnome-initial-setup's Language page renders
# <GtkImage icon_name='start-here-symbolic' pixel_size=96> as a 96px
# header above the locale list. Bluefin DX overrides this Adwaita icon
# with its mascot glyph. Replace it with Lucciola's symbolic firefly (two
# circles, lucciola-mark-symbolic.svg); GTK4 symbolic icons do not accept
# embedded raster <image> nodes.
cp "$A/lucciola-mark-symbolic.svg" /usr/share/icons/Adwaita/symbolic/places/start-here-symbolic.svg
[[ -s /usr/share/icons/Adwaita/symbolic/places/start-here-symbolic.svg ]] || { log "FATAL: required branding asset is empty: /usr/share/icons/Adwaita/symbolic/places/start-here-symbolic.svg"; exit 1; }
chmod 0644 /usr/share/icons/Adwaita/symbolic/places/start-here-symbolic.svg
if grep -Eiq '<image[[:space:]>]|data:image/' /usr/share/icons/Adwaita/symbolic/places/start-here-symbolic.svg; then
  log "FATAL: start-here-symbolic.svg contains an embedded raster image; GTK4 symbolic icons require path/circle/rect primitives"
  exit 1
fi
log "Replaced start-here-symbolic.svg with Lucciola's symbolic firefly ($(stat -c %s /usr/share/icons/Adwaita/symbolic/places/start-here-symbolic.svg) bytes)"

# (c) Bluefin wallpaper collection (Settings → Background spam).
rm -rf /usr/share/backgrounds/bluefin

# (d) Bluefin mascot logos (chicken.png, dolly.png, karl.png, bluefin.png)
# referenced by some Bluefin custom fastfetch configs / banner scripts
# that we override anyway. Safe to remove.
rm -rf /usr/share/ublue-os/bluefin-logos

# (e) Bluefin Firefox distribution config (bookmarks + start page injection).
# Margine ships Zen Browser via Flatpak; the Bluefin Firefox config is
# noise.
rm -rf /usr/share/ublue-os/firefox-config

# (f) Bluefin's fastfetch config (we ship our own at /etc/fastfetch/
# and /usr/share/fastfetch/margine.jsonc).
rm -f /usr/share/ublue-os/fastfetch.jsonc

# (g) Bluefin docs in /usr/share/doc/ — non-functional, just clutter.
rm -rf /usr/share/doc/bluefin

# (h) Bazaar app-store carousel wallpapers from Bluefin (16 .jxl files
# in /usr/etc/bazaar/, named NN-bluefin-{day,night}.jxl). They show up
# in Bazaar's spotlight banner / promo carousel. Replaced at build
# time with nothing — Bazaar falls back to its own placeholders. If
# we ever want Margine-branded promo art in Bazaar, drop matching
# 01-margine-{day,night}.jxl into /usr/etc/bazaar/ here.
rm -f /usr/etc/bazaar/*-bluefin-*.jxl /etc/bazaar/*-bluefin-*.jxl

# (i) Bluefin/ublue custom helper binaries that were dropped into
# /usr/bin by image-build scripts (not RPM-owned, so rpm verify
# misses them). Most are no-ops on Margine because the surrounding
# Bluefin infrastructure isn't here. Keep the ublue-image-info.sh +
# ublue-rollback-helper which integrate with bootc/ostree (functional);
# drop the rest. ublue-motd in particular spawns Bluefin's tipline at
# every shell login, very visible regression for a Margine user.
#
# IMPORTANT — bluefin-dx-groups KEPT (un-deleted 2026-06-04 after
# debugging fresh install): the Bluefin DX `bluefin-dx-groups.service`
# unit (inherited too) calls /usr/bin/bluefin-dx-groups at boot to add
# every wheel user to docker, incus-admin, libvirt groups. Useful for
# Margine too (same use case: admin user runs `docker ps`, `incus
# launch`, `virsh list` without sudo). When we deleted the binary the
# unit kept retrying with status=203/EXEC (Restart=on-failure
# RestartSec=30 forever) and daniel ended up only in `wheel`, not in
# docker/incus-admin/libvirt. Now both the binary AND the unit stay.
#
# For the ones we DO delete (ublue-system-setup, ublue-user-setup,
# etc.): also delete their systemd .service units so we don't hit the
# same 203/EXEC retry-loop. See "(j.bis)" block below.
#
# ublue-bling KEPT (un-deleted 2026-07-07, issue #291): the Bluefin
# `bluefin-cli` recipe (/usr/share/ublue-os/just/system.just) runs
# `@ublue-bling`, and we keep that recipe + bling.sh + the bling tools
# (brew installs eza/atuin/zoxide via cli.Brewfile). ublue-bling is just
# the toggle that appends `source .../bling.sh` to the user's shell rc;
# it needs only gum (present). Deleting the binary while keeping the
# recipe made `ujust bluefin-cli` fail with "ublue-bling: command not
# found". We still drop ublue-bling-fastfetch (fastfetch branding).
rm -f /usr/bin/ublue-bling-fastfetch \
      /usr/bin/ublue-fastfetch \
      /usr/bin/ublue-motd \
      /usr/bin/ublue-privileged-setup \
      /usr/bin/ublue-system-setup \
      /usr/bin/ublue-user-setup

# (i.bis) Service units that ExecStart= the binaries we just deleted.
# Without removing these, systemd retries the failing service every
# 30s forever (Restart=on-failure StartLimitInterval=0). Observed on
# the 2026-06-04 fresh install: ublue-system-setup.service stuck in
# activating/failed loop.
for unit in ublue-system-setup.service ublue-user-setup.service; do
  rm -f "/usr/lib/systemd/system/$unit" \
        "/etc/systemd/system/$unit" \
        "/usr/lib/systemd/user/$unit" \
        "/etc/systemd/user/$unit"
  # Also remove from preset enable list (so systemctl preset doesn't
  # re-enable a now-missing unit).
  sed -i "/^enable $unit/d" /usr/lib/systemd/system-preset/*.preset 2>/dev/null || true
  sed -i "/^enable $unit/d" /usr/lib/systemd/user-preset/*.preset 2>/dev/null || true
done

# (j) /etc/profile.d/ Bluefin shell init.
# - ublue-fastfetch.sh sets   alias fastfetch=ublue-fastfetch (which we
#   just deleted), making vanilla `fastfetch` crash with "command not
#   found". Same for neofetch/neowofetch aliases.
# - ublue-motd.sh calls ublue-motd (deleted) at every shell login →
#   prints "ublue-motd: command not found" before the prompt.
# - 91-bluefin-aliases.sh ships `alias rl=ramalama`. Branding, not
#   functional for Margine.
# - 90-bluefin-starship.sh wires up Bluefin's starship theme; Margine
#   doesn't ship starship by default so the file is a no-op, but the
#   'bluefin' in the name is misleading.
# All four also live in /usr/etc/profile.d/ (ostree factory). We
# strip both copies so the 3-way merge at user-boot doesn't restore
# them.
rm -f /etc/profile.d/ublue-fastfetch.sh \
      /etc/profile.d/ublue-motd.sh \
      /etc/profile.d/91-bluefin-aliases.sh \
      /etc/profile.d/90-bluefin-starship.sh \
      /usr/etc/profile.d/ublue-fastfetch.sh \
      /usr/etc/profile.d/ublue-motd.sh \
      /usr/etc/profile.d/91-bluefin-aliases.sh \
      /usr/etc/profile.d/90-bluefin-starship.sh

# (k) /etc/dconf/db/distro.d/ — Bluefin dconf overrides for app folder
# layout, keybindings, Ptyxis colour palette, and extension prefs.
# Several actively conflict with Margine intent:
# - 02-bluefin-keybindings: Bluefin window-manager binds collide with
#   the Hyprland-style ones margine-bootstrap applies (Super+1..0
#   workspaces, Super+arrow focus, Super+return terminal).
# - 03-bluefin-ptyxis-palette: Bluefin terminal colours — Margine
#   should pick its own palette (yellow accent, autumn-warm) later.
# - 04-bluefin-logomenu-extension: logo-menu prefs that point at the
#   Bluefin LogoMenu icon — extension is in zz0's enabled-extensions
#   but our zz1 overrides remove it from enabled set anyway.
# - 05-bluefin-searchlight-extension: search-light prefs, partially
#   useful but tinted with Bluefin defaults.
# - 01-bluefin-folders: Gaming/Utilities/Games app folder layout.
#   Margine has its own folder layout via configure-gnome-folders
#   (margine-fedora-atomic).
# - locks/01-bluefin-locked-settings: dconf locks that prevent the
#   user from overriding any of the above. With the overrides gone,
#   the locks reference non-existent keys.
# Plus the /usr/etc/ factory copies (same 3-way-merge concern as
# profile.d above).
rm -f /etc/dconf/db/distro.d/*bluefin* \
      /etc/dconf/db/distro.d/locks/*bluefin* \
      /usr/etc/dconf/db/distro.d/*bluefin* \
      /usr/etc/dconf/db/distro.d/locks/*bluefin*
# Rebuild dconf db so removed overrides don't keep being compiled.
if command -v dconf >/dev/null 2>&1; then
  dconf update || { log "ERROR: dconf update failed (final pass)"; exit 1; }
fi

# Update the icon-theme cache so removed SVGs disappear from icon
# lookups immediately at first boot.
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t -q /usr/share/icons/hicolor 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# HiDPI GRUB: bake a large console font for the boot menu.
# ---------------------------------------------------------------------------
# GRUB has no DPI scaling, and the old gfxmode-low trick is firmware-dependent
# (the GOP/VBE must expose the chosen mode or GRUB falls back to native ->
# tiny glyphs again — which is why every gfxmode iteration was a no-op). A
# baked LARGE .pf2 is resolution-independent. Generate it from **Noto Sans
# Mono** (present in the base image: google-noto-sans-mono-vf-fonts) with an
# explicit family name so the embedded font name is the stable "Margine
# Regular 36" that 05_margine-gfxmode.cfg selects via gfxterm_font.
# IMPORTANT — why Noto, not Liberation Mono: GRUB's gfxterm menu border is drawn
# with box-drawing glyphs (U+2500 block). Liberation Mono LACKS that block, so a
# font baked from it rendered the menu border as rows of missing-glyph boxes
# (┌┐└┘─│ → "?"). Noto Sans Mono ships the full U+2500-25FF range, fixing the
# border. Place the font under the bootupd static tree: a FRESH install's
# `bootupctl install --with-static-configs` ships it to /boot automatically;
# EXISTING installs pull it via the margine-grub-hidpi service / ujust recipe
# (bootupd does NOT re-render the static grub.cfg on `bootc upgrade`).
log "Baking HiDPI GRUB font (margine.pf2)"
# Variable-font filename carries an axis suffix (NotoSansMono[wght].ttf); glob it.
_grub_ttf="$(ls /usr/share/fonts/google-noto-vf/NotoSansMono*.ttf 2>/dev/null | head -1)"
[[ -n "$_grub_ttf" && -f "$_grub_ttf" ]] || { log "ERROR: Noto Sans Mono TTF not found under /usr/share/fonts/google-noto-vf/, cannot bake GRUB font"; exit 1; }
# grub2-mkfont lives in grub2-tools-extra. bluefin-dx ships it; the plain
# Bluefin image does not (measured on projectbluefin/bluefin:testing,
# 2026-08-25), so install it only when the base lacks it. Same rule as the
# other "the base used to bring this" layers: a no-op on today's base.
# Pin it to the EVR of the grub2-tools already in the base: the grub2
# subpackages require each other at the exact version, so a bare install
# would upgrade the whole bootloader stack (grub2-efi-x64, grub2-pc,
# grub2-common) as a side effect of fetching a 5 MiB build tool. Fedora's
# updates-archive repo (enabled by default) keeps every pushed build, so
# the matching EVR is always there: measured transaction on the new base
# is grub2-tools-extra + mtools, nothing else.
if ! command -v grub2-mkfont >/dev/null 2>&1; then
  _grub_evr="$(rpm -q --qf '%{EVR}' grub2-tools)"
  log "base lacks grub2-tools-extra (grub2-mkfont), installing it at the base's grub2 EVR ${_grub_evr}"
  retry 3 30 dnf -y install --setopt=install_weak_deps=False "grub2-tools-extra-${_grub_evr}"
fi
command -v grub2-mkfont >/dev/null 2>&1 || { log "ERROR: grub2-mkfont missing, cannot bake GRUB font"; exit 1; }
install -d -m0755 /usr/lib/bootupd/grub2-static/fonts
grub2-mkfont -s 36 -n "Margine" \
  -o /usr/lib/bootupd/grub2-static/fonts/margine.pf2 "$_grub_ttf" \
  || { log "ERROR: grub2-mkfont failed"; exit 1; }
log "GRUB font baked: $(stat -c %s /usr/lib/bootupd/grub2-static/fonts/margine.pf2) bytes (name 'Margine Regular 36')"

log "Bluefin branding stripped"

# ---------------------------------------------------------------------------
