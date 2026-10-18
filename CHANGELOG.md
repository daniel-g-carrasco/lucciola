# Changelog

All notable changes to the Lucciola bootc image build are recorded here.
Image tags follow `stable`, `stable.YYYYMMDD`, `YYYYMMDD`.
Semantic versioning (`v0.X.Y`) will start once the first user-facing
stable release is cut.

## [Unreleased]

### Removed (GNOME customisation)
- **The build no longer adds Margine's GNOME customisation only to delete
  it.** GNOME has been a stock fallback session since 2026-10-11, but the
  image still built and installed Margine's GNOME layer and then
  `lucciola/build.sh` took it apart. These left the build:
  - the GNOME Shell extensions step and its script
    (`build-margine-extensions.sh`: o-tiling with its patches, hide-cursor,
    the Smile, Gradia and Bazaar companions, Caffeine from EGO, the icon
    shims for o-tiling), the AppIndicator, Dash to Dock, Caffeine and
    GSConnect packages, and the weekly EGO pin watcher
    (`check-upstream-pins.yml`);
  - the Shell, mutter and window-manager sections of the zz1 gschema
    override and the five dconf keyfiles (extension settings, the tiling
    keybindings, the Smile shortcut);
  - wayland-scroll-factor (45-wsf, `ujust wsf-preload`), which only loads
    into gnome-shell; niri sets the scroll speed itself;
  - Smile and Extension Manager from the preinstalled and baked Flatpaks
    (an install that has them keeps them);
  - the GNOME first-login helpers (`margine-configure-gnome-*`,
    `margine-install-user-extensions`) and the two first-login autostart
    entries. `ujust margine-bootstrap` keeps its other steps (home layout,
    default applications, Zen, darktable) and runs only by hand.

  `lucciola/build.sh` now checks instead that GNOME arrives stock and fails
  the build otherwise. What stays for GTK applications: the accent colour,
  the wallpaper and the virt-manager connections. GSConnect's port 1716 is
  gone from the reviewed listeners (decision D5 closed).
  libappindicator-gtk3, which came in as an extension dependency, is now
  installed on its own: Koofr's tray needs it.
  Measured on two local builds of the same base (before, and after without
  the libappindicator fix): the same files and packages except the ones
  above (four packages, 68 paths); installed tree 1.5 MiB smaller (under
  1 MiB with libappindicator kept); 98 MiB less in the image's layers,
  nearly all of it the extensions step's own layer, which the published,
  re-chunked image did not carry as such; build time unchanged within
  noise (1125 s against about 1117 s), since the kernel and package steps
  dominate. The gain is a shorter build with seven fewer downloads (six
  extensions, the WSF package) and no extension patches to rework at every
  GNOME release.

### Changed (login screen)
- **The login screen is Noctalia Greeter on greetd**, in place of GDM: the
  same look as the desktop (dark, the Lucciola palette, JetBrains Mono, the
  Margine wallpaper), Lucciola preselected, GNOME and GNOME Classic in the
  session list. The greeter remembers the session picked last. Noctalia's
  Settings > Security > Noctalia Greeter > Sync Now copies the desktop's
  colours, font, wallpaper and screen layout to it (with the administrator
  password).
  - A password login still opens the Login keyring (pam_oo7 is in greetd's
    PAM stack, as in GDM's). Fingerprint login, if turned on with
    authselect, works one step at a time: press Enter on the empty password
    field, then touch the reader.
  - `ujust margine-autologin on|off|status` now sets greetd's autologin. A
    GDM autologin moves over by itself at the first boot of this image.
  - GDM stays installed: if the greeter cannot start, GDM takes over after a
    few attempts, so there is always a way to log in. To go back to GDM for
    good: `sudo systemctl enable --force gdm.service`, then restart (and
    `greetd.service` to return).
  - GNOME started from greetd has no lock screen: GNOME Shell locks the
    screen only when GDM is running. Lock with Lucciola, or switch back to
    GDM if you use GNOME every day.
  - Noctalia Greeter is built from its v1.6.0 tag by this repository's
    build (Fedora does not package it); greetd comes from Fedora.

### Fixed (2026-10-18, from Margine)
- **The fixes Margine got on 2026-10-17 (margine-image #517), brought over.** The system app compares the machine with the tag it follows instead of always `:stable`; the Secure Boot notice and `ujust margine-secureboot` say "Lucciola" (from `product-name`); `margine-collect-diagnostics` writes under `~/.local/state/margine/diagnostics/` instead of the read-only `/usr`; `lucciola-keep-awake` is on the PATH; Extension Manager is no longer preinstalled; `bar-widths` speaks of two workspaces.

### Fixed (2026-10-18)
- **New system accounts on machines installed from the ISO.** There `/etc/passwd` gets seeded from the image, and a new system account (greetd, after the move from `margine:lucciola`) arrived without its `/etc/shadow` line, so PAM could not look it up and the greeter's user manager failed. `margine-seed-etc-passwd` now adds a locked shadow or gshadow line for every account or group that lacks one, at every boot, and never touches existing lines.
- **No Secure Boot warning on firmware that has no Secure Boot.** On a machine whose firmware does not implement Secure Boot at all (a virtual machine with plain OVMF, for one), `mok-enroll.service` failed at every boot, because mokutil refuses to import a key there, and the login notice asked the user to fix something that cannot be fixed. The helper now recognises that firmware (no `SecureBoot` EFI variable), reports `unsupported` and stays quiet. A missing opt-out file no longer logs a "No such file" error either.

### Changed (Noctalia 5.3.0)
- **Noctalia 5.3.0.** Fedora 44 replaced 5.2.1 with 5.3.0 on 2026-10-17, and its updates repository keeps only the newest build, so the old pin stopped installing; on Fedora 45 5.3.0 is in updates-testing until it goes stable. Lucciola's config validates with no warnings, Keep Awake's plugin API is supported, and every `noctalia msg` command it uses is unchanged. Workspace labels no longer take the palette's hover colour, which was nearly the bar's own; the screens now go off one minute after the idle lock, as intended. Checked on screen in a VM with GPU-accelerated graphics (margine-image #518).

### Changed (Fedora 45)
- **Lucciola is built on Fedora 45** (`silverblue-main:45`). The `:stable`
  image waits for Fedora 45's release on 27 October: until then Fedora
  keeps its testing repository on, and test builds may carry packages that
  have not finished their checks. Saved passwords move from gnome-keyring
  to oo7:
  - a password login opens the Login keyring as before, and oo7 moves a
    Fedora 44 keyring over the first time it opens it;
  - for fingerprint and autologin, `ujust margine-keyring tpm` stores the
    keyring password as a credential encrypted for the user with the TPM,
    and oo7 opens the keyring with it at login (oo7 has no empty keyring
    password);
  - a keyring left with an empty password by `ujust margine-keyring blank`
    is in a format oo7 0.7.0 beta cannot read: the image sets it aside
    before oo7 starts and imports its passwords at login (or with
    `ujust margine-keyring import`);
  - the niri session starts oo7, as its developers intend: oo7 has no D-Bus
    activation of its own on purpose (linux-credentials/oo7#603); the image
    also lets an application start it on demand.
  Fedora 45's base dropped the SSH VPN plugin and the network connection
  editor: the image installs them. Fedora 45 retired the vpnc VPN plugin
  and Nautilus's AFP and archive backends.

### Changed (2026-10-17)
- **Lucciola is built on its own.** One build from Universal Blue's
  `ghcr.io/ublue-os/silverblue-main:44` produces the whole image: the
  CachyOS kernel signed with the same MOK, the Margine OS layer, then
  niri, Noctalia and the Lucciola session, with GNOME kept as a stock
  fallback. Until now Lucciola was a second build on top of the published
  Margine image. Same content as `margine:lucciola`; trimming comes in
  later changes.
- **New image: `ghcr.io/daniel-g-carrasco/lucciola`** (`:candidate`,
  promoted to `:stable` by the smoke-boot gate), signed with the same key
  as Margine. Installed systems verify it against a signature-required
  scope for the new repository; the Margine scope stays.
- No NVIDIA or LTS variant, and no ISO yet.
- Margine's history up to this point is kept in
  [docs/margine/CHANGELOG.md](docs/margine/CHANGELOG.md).
