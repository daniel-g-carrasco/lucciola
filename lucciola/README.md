# Lucciola

Lucciola is niri with the Noctalia shell on top of Margine OS, built as one
image from Universal Blue's silverblue-main by this repository (until 2026-10
it was a second build FROM the published Margine image). Experimental.

Everything below the desktop comes from Margine unchanged: the CachyOS kernel
signed with the Margine key, Secure Boot, TPM2 disk unlock, image signatures
verified by the device, rollback, and every Margine fix. This layer adds:

- `niri` and `xwayland-satellite` from Fedora, and `noctalia` from Fedora at a
  pinned version (`NOCTALIA_VR` in the Containerfile, the Fedora tag comes
  from the base: bump it only together with a test boot, since upstream
  supports only its latest release);
- the niri defaults in `/usr/share/lucciola/niri/config.kdl`, loaded through
  `/etc/niri/config.kdl`, with Margine's keybindings; personal settings go in
  `~/.config/niri/lucciola.kdl`;
- Noctalia defaults in `/usr/share/lucciola/noctalia/`, seeded once per user
  by `/usr/libexec/lucciola/session-start`: idle lock on, polkit agent on, and
  the look of the first Margine (dark floating bar, monospace, windows rounded
  like libadwaita; palette `palettes/Margine.json`, linked into the user's
  `palettes/` folder at login);
- niri's border colours follow the Noctalia palette through Lucciola's own
  Noctalia template (`noctalia/25-niri-colors.toml`, rendered to
  `~/.config/niri/lucciola-colors.kdl`, which the system niri config
  includes): the same colours as Noctalia's built-in "Niri" template (beige
  focused border, unfocused ones in the bar background), without touching
  any user niri file;
- `/usr/libexec/lucciola/bar-widths`: the bar keeps a fixed width on large
  monitors, and secondary screens get a single workspace, as in GNOME;
- `/usr/libexec/lucciola/color-calibration`: niri has no colour management
  yet, so this loads the calibration curves (vcgt) of the screens' ICC
  profiles in `~/.local/share/icc`, as GNOME does. Per-screen choices go in
  `~/.config/lucciola/color-profiles`; `color-calibration --list` shows what
  each screen gets, and Super+Shift+C (`color-calibration --toggle`) switches
  the calibration off and on to compare. The curves and Noctalia's night light use the same
  mechanism, so the night light cannot change a calibrated screen;
- `~/.config/niri/config.kdl`, created at login when missing, starting with
  `include "/etc/niri/config.kdl"`: niri reads the user file *instead of* the
  system one, and Noctalia's niri template (Templates > Built-in > Niri)
  adds its include to that file: up to Noctalia 5.2.1 it created the file
  holding nothing but that include, dropping every Lucciola default; from
  5.3.0 it creates none while `/etc/niri/config.kdl` exists, so without
  this file the template would do nothing. A file holding only Noctalia's
  include is repaired;
- one scroll speed for every application: toolkits turn a unit of touchpad
  scrolling into 2.5 (GTK 4), 4 (Firefox, Zen, Thunderbird) or 5.3
  (Chromium, Electron) logical pixels, so window rules scale the second
  and third families down to the first; the touchpad `scroll-factor`
  (0.15) is the one value to change, in `~/.config/niri/lucciola.kdl`
  (repeat the whole `touchpad` block: niri replaces it, it does not merge);
- Ptyxis in the Noctalia palette: a Noctalia template writes a Ptyxis palette
  (`noctalia.palette`) and selects it once in the default profile; another
  palette picked later in Ptyxis stays;
- Keep Awake, a Noctalia plugin over `/usr/libexec/lucciola/keep-awake`: no
  suspend, no idle lock and the lid does nothing, now, until a time, or from a
  scheduled time. A bar indicator is lit while it is on, a clock while it is
  scheduled, dim when off; notifications carry the bar's glyphs; the
  control-centre tile takes the place of Noctalia's
  caffeine; the panel (click the indicator, right-click the tile) has quick
  durations and a scheduler; the launcher answers "awake", "sveglio", "2h",
  "18:30". From a terminal: `lucciola-keep-awake on [UNTIL] | tomorrow |
  schedule START [UNTIL] | off | cancel | status [--json]`;
- `ddcutil`, so Noctalia's brightness slider also drives external monitors
  over DDC/CI (the package's udev rule opens the i2c devices to the
  logged-in user, its modules-load entry loads i2c-dev);
- the login screen: Noctalia Greeter on greetd, in place of GDM. Noctalia
  Greeter is built from its pinned tag (`NOCTALIA_GREETER_VERSION` and its
  sha256 in the Containerfile, spec in `greeter/`) with two Lucciola
  touches: the firefly as the logo at the bottom of the screen, and a patch
  that says a failed login in words ("Wrong password, try again" instead
  of `pam_authenticate: AUTH_ERR`); greetd comes from Fedora. `/etc/greetd/config.toml` (reference copy in
  `/usr/share/lucciola/greetd/`) runs the greeter as the `greetd` account;
  its fixed settings are `/usr/share/lucciola/greeter/greeter.toml` (linked
  into `/var/lib/noctalia-greeter/`), its starting look (dark, the Margine
  palette, JetBrains Mono, Lucciola's wallpaper, Lucciola preselected) is
  `sync.toml`, copied once and then replaced by Noctalia's "Sync with
  Noctalia". greetd uses Fedora's PAM file with pam_oo7 added to the
  password stack and the Wayland session type set for autologin
  (`ujust lucciola-autologin`). GDM stays installed and takes over when
  greetd cannot start (`greetd.service.d/50-lucciola.conf`);
  `lucciola-login-migrate.service` moves an install from GDM once,
  autologin included. GNOME under greetd has no lock screen (GNOME Shell
  locks only when GDM runs);
- the "Lucciola" session on the login screen, the one a new user gets
  (preselected by the greeter until someone picks another; the
  AccountsService user templates for autologin and GDM), and the public
  name in os-release;
- GNOME as a stock fallback session: the build adds no GNOME Shell
  extension (only Fedora's GNOME Classic set is there), none of Margine's
  Shell, window-manager or settings-daemon defaults and no GNOME
  first-login bootstrap (`build.sh` fails if one of them shows up), and
  no wayland-scroll-factor. The defaults that also serve GTK applications
  under niri (accent colour, wallpaper, virt-manager connections) stay.

Images: `ghcr.io/daniel-g-carrasco/lucciola`, built by `.github/workflows/build.yml`
as `:candidate` and promoted to `:stable` by `.github/workflows/smoke-boot.yml`,
signed with the same key as Margine. The layer is the last step of the main
`Containerfile`: `lucciola/system_files/` copied in, then `lucciola/build.sh`.
Until 2026-10 the images were `ghcr.io/daniel-g-carrasco/margine:lucciola`,
which is still what the switch below points to.

Switch a Margine install to it (and back with the previous boot entry, or by
rebasing to `:stable`):

```sh
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/daniel-g-carrasco/margine:lucciola
systemctl reboot
```

From another Fedora Atomic system (Silverblue, Bluefin, Aurora, Bazzite),
rebase on the unverified transport: Margine's signature policy arrives with
the image, and at the first boot `margine-signed-origin.service` stages the
same tag on the signed transport (it applies at the next restart):

```sh
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/daniel-g-carrasco/margine:lucciola
systemctl reboot
```

Coming from another system with Secure Boot on, turn it off before rebasing
(a Margine install already has the key): the kernel is signed with the
Margine key, and until that key is enrolled Secure Boot refuses to start it.
After the first boot `mok-enroll.service` stages the key;
`ujust lucciola-secureboot enroll` makes the blue MOK Manager screen at the
next restart wait for you (Enroll MOK, Continue, Yes, password `margine`).
Turn Secure Boot back on when `ujust lucciola-secureboot` says so.

## Brand

`assets/` holds Lucciola's identity; `docs/BRANDING.md` maps every place it
appears.

- The wordmark: "lucciola" in JetBrains Mono Light converted to outlines,
  with the firefly as its last dot (`lucciola-wordmark.svg` for dark
  backgrounds, `lucciola-wordmark-light.svg` for light ones). The outlines
  derive from a font under the SIL Open Font License 1.1, so its licence
  travels with them (`JetBrainsMono-OFL.txt`).
- The firefly alone, the compact mark (`lucciola-mark.svg`,
  `lucciola-mark-light.svg`, and `lucciola-mark-symbolic.svg` for symbolic
  icon slots), and the mark on a dark rounded tile for app and OS icons
  (`lucciola-logo.svg`, the icon `lucciola-logo` and os-release `LOGO=`).
- Palette: surface `#121212`, beige `#e6d5bf` (primary, the firefly), sand
  `#c2a180`, lavender `#cba6f7`, text `#ece6df`.
- `wallpaper/`: dusk over dark hills with a few fireflies, written by
  `make-wallpaper.py` (a 3840x2400 master anchored at the bottom) and
  rendered at 3840x2160, 2880x1920 and 2560x1600.
- `plymouth/`: the boot splash, the wordmark on `#121212` with its firefly
  breathing (6 s, opacity 1 to 0.4 and back) and a disk password prompt in
  the same palette.
- `fastfetch-logo.txt`: the firefly in shaded blocks over the name.

Every PNG is rendered from these sources by `assets/render.sh` and
committed (the build has no SVG renderer, and Plymouth reads PNG only):
after changing a source, run it (its header has a container one-liner) and
commit the result.
