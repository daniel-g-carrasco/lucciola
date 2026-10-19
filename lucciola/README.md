# How Lucciola is built

Lucciola is one image, built by this repository from Universal Blue's
`silverblue-main:45`. The `Containerfile` runs two layers on top of it:

- `build_files/`, inherited from Margine OS, the GNOME image Lucciola grew
  from: the CachyOS kernel signed with the MOK, Secure Boot and TPM2 disk
  unlock, signed images that devices verify, the update services, the
  Flatpaks, the GTK defaults and the `lucciola-*` commands. Its paths and
  unit names still say `margine` (`/usr/libexec/margine`, `margine-*.service`),
  so installed machines keep working across updates;
- this directory, the desktop: `lucciola/system_files/` copied in, then
  `lucciola/build.sh`.

This layer adds:

- `niri` and `xwayland-satellite` from Fedora, and `noctalia` from Fedora at a
  pinned version (`NOCTALIA_VR` in the Containerfile, the Fedora tag comes
  from the base: bump it only together with a test boot, since upstream
  supports only its latest release);
- the niri defaults in `/usr/share/lucciola/niri/config.kdl`, loaded through
  `/etc/niri/config.kdl`, with the keybindings carried over from Margine; personal settings go in
  `~/.config/niri/lucciola.kdl`;
- Noctalia defaults in `/usr/share/lucciola/noctalia/`, seeded once per user
  by `/usr/libexec/lucciola/session-start`: idle lock on, polkit agent on, and
  a dark floating bar, monospace, windows rounded like libadwaita, and the
  palette `palettes/Margine.json` (named after Margine, where it was born;
  linked into the user's `palettes/` folder at login);
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
- a welcome window at a new user's first Lucciola session
  (`/usr/libexec/margine/welcome`, GTK 4 and libadwaita in gjs, in the
  website's look): the keys first, then updates and Lucciola System,
  Homebrew, apps, and the guide. Its texts and their order are data,
  `/usr/share/lucciola/welcome/content.json`, edited with `just edit`
  (`tools/content-editor`). session-start opens it until it has been
  closed once (`~/.local/state/lucciola/welcome-due`, `welcome-seen`);
  accounts with Lucciola sessions from before it never see it unasked, and
  "Lucciola Welcome" in the launcher opens it any time;
- the login screen: Noctalia Greeter on greetd, in place of GDM. Noctalia
  Greeter is built from its pinned tag (`NOCTALIA_GREETER_VERSION` and its
  sha256 in the Containerfile, spec in `greeter/`) with three Lucciola
  touches: the firefly as the logo at the bottom of the screen, a patch
  that says a failed login in words ("Wrong password, try again" instead
  of `pam_authenticate: AUTH_ERR`), and one that starts the login as soon
  as a user is selected (`[auth] start_on_select`), so the fingerprint
  reader listens without an Enter first; greetd comes from Fedora. `/etc/greetd/config.toml` (reference copy in
  `/usr/share/lucciola/greetd/`) runs the greeter as the `greetd` account;
  its settings and look are `/usr/share/lucciola/greeter/greeter.toml`
  (linked into `/var/lib/noctalia-greeter/`, so updates bring them: dark,
  the `Margine.json` palette with the card in the sky's blues, JetBrains
  Mono, Lucciola's wallpaper blurred), and `sync.toml` only preselects
  Lucciola (copied once; Noctalia's "Sync with Noctalia" adds the screen
  layout). greetd uses Fedora's PAM file with pam_oo7 added to the
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

## Images

`ghcr.io/daniel-g-carrasco/lucciola`, built by `.github/workflows/build.yml`
as `:candidate` and promoted to `:stable` by
`.github/workflows/smoke-boot.yml` once it boots in a VM with Secure Boot
and a TPM. Signed with the same key as Margine.

Until 2026-10 Lucciola was published as
`ghcr.io/daniel-g-carrasco/margine:lucciola`. Installs that follow that
tag move to this repository's image through a step on Margine's side, and
`.github/workflows/upgrade-smoke.yml` tests that move. To move by hand:

```sh
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/daniel-g-carrasco/lucciola:stable
systemctl reboot
```

The transport is unverified because the policy on a `margine:lucciola`
install knows only the Margine repository; the new deployment brings the
scope for this one, and `margine-signed-origin.service` moves it to the
signed transport at the first boot. The [README](../README.md#install) has the install from
another Fedora Atomic system.

The kernel is signed with the key Margine used, whose certificate is named
"Margine MOK Signing Key"; its enrollment password is `margine`. A Margine
install already has it enrolled. Anyone else turns Secure Boot off before
the switch; after the first boot `mok-enroll.service` stages the key,
`ujust lucciola-secureboot enroll` makes the blue MOK Manager screen at
the next restart wait (Enroll MOK, Continue, Yes, password `margine`), and
Secure Boot goes back on when `ujust lucciola-secureboot` says so.

## Build locally

Signing the kernel needs a MOK key and certificate (an image signed with
your own key starts with Secure Boot on only after you enroll that key):

```sh
podman build \
  --secret id=mok-key,src=MOK.key \
  --secret id=mok-cert,src=MOK.pem \
  -t localhost/lucciola .
```

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
