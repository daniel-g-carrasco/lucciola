# Lucciola branding: the complete map

**Purpose.** Every place the image overrides Fedora/Universal Blue identity (logos,
names, boot splash, login screen, installer, notifications, CLI) lives here, so
changing one thing later doesn't silently break another. Since 2026-10-18 the
identity is Lucciola's: its sources are in `lucciola/assets/`, installed by
`build_files/50-branding` (inherited from Margine OS); the Margine names that stay
are internal (paths, units, `VARIANT_ID`) or kept as aliases (see section 11). Each entry says **where** it is,
**what** it sets, **how** (the mechanism), and the **gotchas** that bite.

> **Anchors, not line numbers.** This doc points at files and *grep-able strings*
> (keys, function names, literals) instead of line numbers, which rot on every
> edit. To jump to a touchpoint: `grep -n "<anchor>" <file>`.

> **Two build surfaces.** Branding is split across two images:
> - **Base image** (`build_files/…`) → the installed system. Built by `just build`.
> - **Live image** (`live-env/src/…`) → the ISO / installer only. Built on top of
>   the published base by Titanoboa (see `live-env/build-iso-local.sh`).
> A change in `live-env/` is visible **only in the ISO**, never on an installed
> system, and vice-versa. Mixing these up is the #1 source of "I changed it but it
> didn't change."
>
> Lucciola has no ISO yet: no workflow builds `live-env/`, which is still
> Margine's live image and says "Margine" throughout (sections 3, 6, 7 and 8,
> and the rows marked "Margine's ISO" below). It becomes Lucciola's when the
> ISO comes.

---

## Golden rules (read these first)

These five cut across almost every touchpoint below:

1. **ostree `/etc` is three-way merged.** Deleting a file under `/etc` is not
   enough if a copy also exists under `/usr/etc` (the ostree factory tree) — the
   merge restores it. Always remove/replace **both**. (Affects shell-init deletes,
   dconf profiles.)
2. **dconf needs `dconf update`.** Writing a keyfile under `/etc/dconf/db/*.d/`
   does nothing until `dconf update` recompiles the binary db. GDM and the user
   session are **separate dconf databases**.
3. **Icon themes need a cache rebuild.** After dropping an SVG/PNG under
   `/usr/share/icons/hicolor/…`, run `gtk-update-icon-cache -f -t
   /usr/share/icons/hicolor`. Use `-t` (ignore-theme-index): a bare `--force`
   silently aborts early in the build when `index.theme` isn't there yet, leaving
   a stale cache and "missing" icons.
4. **GNOME 50+ killed `X-GNOME-Autostart-Phase`.** Setting that key in an
   autostart `.desktop` makes `gnome-session` **skip the entry entirely**. Never
   add it. (Verified 2026-06-04.)
5. **`.desktop Exec=` can't carry shell syntax.** No quotes, `&&`, pipes, or
   redirection — `desktop-file-validate` rejects them and GNOME won't launch them.
   Always point `Exec=` at a wrapper script under `/usr/libexec/…`.

---

## Quick reference

| What you want to change | File | Anchor to grep |
|---|---|---|
| Brand sources: logos, wallpaper, boot splash, fastfetch logo, and the PNGs rendered from them | `lucciola/assets/` (`render.sh` renders, the PNGs are committed) | `render.sh`, `make-wallpaper.py` |
| Distro name / version / URLs / accent | `build_files/10-os-identity/install.sh` (re-checked by `lucciola/build.sh` step 3) | `PRETTY_NAME`, `VARIANT_ID`, `LOGO`, `ANSI_COLOR` |
| The logo: `lucciola-logo` (the tile, everywhere) and `lucciola-mark` (the firefly alone) | `build_files/50-branding/install.sh` | `lucciola-logo.svg`, `gtk-update-icon-cache` |
| GNOME **About** logo | `build_files/50-branding/install.sh` | `lucciola-logo`, `LOGO=` in os-release |
| GNOME About distributor wordmark | `build_files/50-branding/install.sh` | `fedora_logo_med`, `fedora_whitelogo_med` |
| Boot splash (Plymouth) | `lucciola/assets/plymouth/`, `build_files/50-branding/install.sh` + `…/kargs.d/10-margine-plymouth.toml` | `plymouth-set-default-theme`, `DeviceScale`, `rhgb` |
| GRUB menu text (Margine's ISO) + HiDPI font | `live-env/src/iso.yaml` + `…/grub2-static/configs.d/05_margine-gfxmode.cfg` | `Install Margine`, `grub2-mkfont`, `margine.pf2` |
| GDM background / logo (Lucciola's fallback login screen) | `build_files/50-branding/install.sh` | `gdm.d/01-margine-background`, `login-screen` |
| **Lucciola** login screen (Noctalia Greeter on greetd): look, logo, preselected session, failed-login text | `lucciola/system_files/usr/share/lucciola/greeter/{sync,greeter}.toml`, `lucciola/greeter/` (spec, patch), `lucciola/build.sh` (step 5) | `hide_logo`, `Source1`, `authErrorText`, `[appearance.palette]`, `last = "Lucciola"` |
| Desktop wallpaper (GNOME, GDM, Noctalia, the greeter) / accent colour (GTK; GNOME itself stock) | `build_files/50-branding/install.sh`, `lucciola/system_files/usr/share/lucciola/noctalia/15-wallpaper.toml`, `build_files/30-gnome-defaults/install.sh` | `picture-uri`, `wallpaper.default`, `accent-color` |
| Live ISO "Welcome to Margine" (Margine's ISO) | `live-env/src/build.sh` | `Welcome to Fedora` (the sed targets) |
| Anaconda installer **window icon** (Margine's ISO) | `live-env/src/build.sh` | `AnacondaInstaller`, `_wmid in`, `StartupWMClass` |
| Installer product/storage config (Margine's ISO) | `live-env/src/anaconda/profile.d/margine.conf` | `variant_id`, `default_partitioning` |
| "Secure Boot is disabled" notice (Margine's ISO) | `live-env/src/build.sh` | `margine-live-sb-notice` |
| MOK passphrase / enrollment | `build_files/custom-kernel/install.sh` | `margine`, `mok-enroll` |
| First-login bootstrap + notification (no autostart in Lucciola: `ujust lucciola-bootstrap` by hand) | `build_files/system_files/usr/libexec/margine/first-boot-bootstrap`, `…/usr/libexec/margine-first-boot-status` | `first-boot-bootstrap`, `first-boot-status` |
| Update notifications | `build_files/system_files/usr/libexec/margine*` (units in `…/usr/lib/systemd/user/`) | `margine-notify` |
| Notification icon and sender (lock screen included) | `build_files/system_files/usr/libexec/margine/margine-notify` | `app_icon`, `image-path`, `APP_NAME` |
| Lucciola System app (name/icon/id) | `…/applications/dev.margine.System.desktop` + `…/icons/hicolor/scalable/apps/dev.margine.System.svg` + `…/libexec/margine/system-gui` | `dev.margine.System`, `Lucciola System` |
| Lucciola CPU Scheduler, system update launcher | `…/applications/margine-scheduler.desktop`, `…/libexec/margine/scheduler-picker`, `…/applications/margine-system-update.desktop` | `Lucciola CPU Scheduler`, `Lucciola system update` |
| Phone Camera app (name/icon/id), virtual webcam label | `…/applications/dev.margine.PhoneCam.desktop` + `…/icons/hicolor/scalable/apps/dev.margine.PhoneCam.svg` + `…/libexec/margine/phone-cam-gui` + `…/modprobe.d/margine-phone-cam.conf` | `dev.margine.PhoneCam`, `Lucciola Phone Cam` |
| fastfetch / MOTD / `/etc/issue` | `build_files/50-branding/install.sh`, `lucciola/assets/fastfetch-logo.txt`, `…/fastfetch/margine.jsonc`, `build_files/60-ujust-services/install.sh` | `ascii-logo.txt`, `no-show-user-motd`, `/etc/issue` |
| Command names: `lucciola-*` in /usr/bin and ujust, `margine-*` kept as links and aliases | `build_files/system_files/usr/bin/`, `build_files/40-spec-scripts/install.sh`, `build_files/60-custom.just` | `lucciola-status`, `alias margine-` |
| **Lucciola**: public name, login session, validator name | `lucciola/build.sh`, `lucciola/system_files/usr/share/margine/product-name` | `NAME="Lucciola"`, `lucciola.desktop`, `product-name` |
| Product name in messages (`lucciola-status`, Secure Boot notice and `ujust lucciola-secureboot`, the System app's "Built from"): `product-name`, else os-release `NAME`, else "Lucciola"; "Margine key" stays, it is the MOK's own name ("Margine MOK Signing Key") | `…/usr/bin/lucciola-status`, `…/libexec/margine/mok-notify`, `build_files/60-custom.just`, `…/libexec/margine/system-gui` | `product-name` |

---

## The foundation: one logo, many names

All visual branding resolves to **two icon names**, installed once and then
aliased to every name Fedora/GNOME hardcodes. Sources in `lucciola/assets/`
(the PNGs rendered by `render.sh`).

Installed by `build_files/50-branding/install.sh`:

- `lucciola-logo`: the firefly on its dark rounded tile, the OS and app icon
  (os-release `LOGO=`, notifications). `hicolor/scalable/apps/lucciola-logo.svg`
  (**primary**), the same at 16 to 512 px under `hicolor/NxN/apps/` (raster
  consumers, notification badges), and `/usr/share/pixmaps/lucciola-logo.png`.
- `lucciola-mark`: the firefly alone (`hicolor/scalable/apps/`, plus a 256 px
  render), and `lucciola-mark-symbolic` for symbolic slots.

Then **aliased** (copied onto names other software hardcodes; these cannot be
renamed or deleted):

- `margine-logo.{svg,png}`: the old name, now carrying the tile. The live
  ISO's installer icon (`live-env/src/build.sh`) and older references use it.
- `fedora-logo-icon.{svg,png}`: hardcoded by **anaconda-live's welcome dialog**
  (`Adw.StatusPage iconName`) and by **gnome-initial-setup** (which maps
  `os-release ID=fedora` to this icon name). Must be *replaced*, never deleted.
- `start-here-symbolic` (Adwaita): the symbolic firefly, for
  gnome-initial-setup's language page.
- `org.fedoraproject.AnacondaInstaller.{svg,png}`: the installer window icon name
  (see [Anaconda installer icon](#7-anaconda-installer--window-icon-the-hard-one)).
  Lives in the **live image** (`live-env/src/build.sh`), not the base.

**Gotchas**
- The GNOME **About** panel looks up `LOGO=` via the **icon theme only**; the
  `/usr/share/pixmaps` fallback does *not* apply there. The SVG under
  `hicolor/scalable/apps/` is mandatory.
- Rebuild the icon cache after every drop (Golden Rule 3).
- Symbolic icons **cannot embed raster images**: GTK4 refuses them. The build
  validates this (greps for `<image`/`data:image/`) and fails if violated.
- The SVGs use `feGaussianBlur` for the glow. librsvg (GTK, the greeter,
  `render.sh`) draws it; a consumer that cannot will show the bare dot.

---

## 1. System identity — os-release & GNOME About

**File:** `build_files/10-os-identity/install.sh` → writes `/usr/lib/os-release`
(`/etc/os-release` is a *relative* symlink to it, so it resolves in any chroot).

Fields that matter for branding:

**Lucciola (2026-10-18):** `10-os-identity` writes Lucciola's public
identity (`NAME`, `VERSION`, `PRETTY_NAME`, `VARIANT`, `LOGO`, `ANSI_COLOR`,
`HOME_URL`, `DEFAULT_HOSTNAME`) from the first step, so the initramfs
50-branding writes (which carries os-release: the initrd's "Welcome to ..."
line) has it too; `lucciola/build.sh` step 3 re-asserts it. The values below
are the image's.

**Naming policy (2026-10-18):** the public name is **"Lucciola"**:
os-release, the login session, notifications, commands, documentation. The
technical identifiers inherited from Margine OS keep `margine` and never
change, because installed machines depend on them: `VARIANT_ID=margine`
(countme keys on it), `margine-*` unit, script and icon names, paths such as
`/usr/libexec/margine` and `/etc/margine`, and the signing key's own name
(section 9). The full list is in section 11.

| Key | Value | Consumed by |
|---|---|---|
| `NAME` | `Lucciola` | GNOME About title, many tools, countme `os_name` |
| `PRETTY_NAME` | `Lucciola <ver> (<build-date>)` | login banners, `hostnamectl`, BLS boot entries |
| `VERSION` | `<ver> (Lucciola)` | About |
| `VARIANT` | `Lucciola` | About |
| `VARIANT_ID` | `margine` | **the authoritative discriminator** (anaconda profile, scripts, countme) — do not change |
| `ID` | `fedora` | kept for bootc-image-builder / tooling compat — **do not change** |
| `ID_LIKE` | `fedora` | family (was `bluefin` until the base switch of 2026-10-11) |
| `LOGO` | `lucciola-logo` | GNOME About logo (icon-theme lookup), margine-notify's default icon |
| `ANSI_COLOR` | `0;38;2;230;213;191` | terminal accent = **#e6d5bf** (the firefly's beige) |
| `HOME_URL` / `DOCUMENTATION_URL` | the Lucciola repository / its README | About "Website", links |
| `SUPPORT_URL` / `BUG_REPORT_URL` | GitHub issues | About links |
| `DEFAULT_HOSTNAME` | `lucciola` | first-boot hostname |

**About panel extras** (`build_files/50-branding/install.sh`):
- The lower **distributor wordmark** uses two *hardcoded* filenames from
  `gnome-control-center.spec` — replace, don't rename:
  `/usr/share/pixmaps/fedora_logo_med.png` (light) and `fedora_whitelogo_med.png`
  (dark). These are **horizontal wordmarks**, not the square logo.
- Stray Fedora pixmaps (`fedora-logo*.png`, `system-logo-white.png`, etc.) are
  deleted to avoid clutter; `fedora-logo-icon` is the one exception (replaced, see
  foundation).

**Gotchas**
- `ID` stays `fedora` on purpose. Detect Lucciola (and Margine) via `VARIANT_ID=margine`.
- Identity (section `10-`) must run **before** branding (section `50-`); the logo
  aliasing and About config assume os-release is already Lucciola's.
- About reads only `NAME`, `PRETTY_NAME`, `VARIANT`, `LOGO` from os-release; other
  fields come from elsewhere.
- **`NAME` feeds Fedora countme's `os_name`.** Renaming it splits the public
  device-count series: the 2026-07-11 "Margine" → "Margine OS" rebrand moved
  updated devices to a new `os_name` and Margine's site chart silently
  undercounted until its counting script learned to accept **both** names.
  That script stayed with Margine (it left this repository with the
  status-page workflows), so nothing here charts Lucciola's devices yet.

---

## 2. Plymouth boot splash

**Theme name:** `lucciola` → `/usr/share/plymouth/themes/lucciola/`
(`lucciola.plymouth`, `lucciola.script`, and the images below). Source:
`lucciola/assets/plymouth/`.

**What it shows:** the wordmark centred on `#121212`, its firefly breathing as
on the website (6 s, opacity 1 to 0.4 and back: 300 frames of the script
plugin's 50 per second, a cosine); the disk unlock prompt in the same palette
(the prompt text, a field drawn like the greeter's, one small firefly per
typed character, a "Caps Lock is on" hint in sand); boot messages near the
bottom.

**Images:** committed PNGs, rendered by `lucciola/assets/render.sh` (the build
has no SVG renderer, the plugin reads PNG only). Each comes in a **ladder of
sizes** (`wordmark-`/`firefly-` 320 to 1620 px wide, `field-`/`bullet-` for
fields 32 to 108 px high); the script picks the smallest one at least as
large as needed and scales it down. `Image.Scale` is a bilinear sample:
sharp down to about half size, ragged beyond. The firefly is a layer of its
own, cut from x 4600 of the wordmark's 5675-unit canvas (the script knows
those numbers; `render.sh` refuses a wordmark of another shape).

**Mechanism** (`build_files/50-branding/install.sh`):
- Installs `plymouth-plugin-script` (the base does not ship `script.so`).
- Copies the theme from `/ctx/lucciola-assets/plymouth/` (the Containerfile's
  ctx stage copies `lucciola/assets/`), and checks every image the script
  builds a name for exists.
- `plymouth-set-default-theme lucciola` and **`DeviceScale=1`** in
  `/etc/plymouth/plymouthd.conf`.
- **Regenerates the initramfs** once, for every kernel (`regenerate_initramfs`:
  generic, `--add ostree`, zstd, reproducible), then checks with `lsinitrd`
  that it carries the theme, `script.so`, `label-freetype.so` and
  `DeviceScale=1`.

**Kargs** (`build_files/system_files/usr/lib/bootc/kargs.d/10-margine-plymouth.toml`):
`rhgb quiet plymouth.ignore-serial-consoles`: `rhgb` enables graphical splash;
`ignore-serial-consoles` stops Plymouth from treating a VM serial console as
headless and skipping the splash.

**Gotchas**
- **Device pixels.** With Plymouth's own HiDPI scale (2 on the 2880x1920
  reference laptop) a script theme's images and `Image.Text` labels are drawn
  at scale 1 and stretched 2x. The theme sizes everything from
  `Window.GetHeight()` in device pixels instead (wordmark canvas 40% of the
  height), which needs `DeviceScale=1`. Side effect: Plymouth's own text (the
  Esc console view) is small on HiDPI panels; `plymouth.force-scale=2` on the
  kernel command line (it wins over the file) brings it back for a debugging
  boot.
- **No `Window.GetX()`/`GetY()`** in the layout (validate-branding fails on
  it): plymouth 24.004.60 returned the smallest display's offset there and
  the logo landed off-centre on a laptop plus monitor.
- A name a function assigns that is not global yet becomes **local** to that
  function: globals the layout fills are initialised before its first call.
- The initramfs has `label-freetype` only (no pango) and the C locale: text
  stays ASCII; a family containing "Mono" picks the packed monospace face,
  "NNpx" sets the size.
- To look at it without booting: plymouthd's X11 renderer (in
  `plymouth-devel`) under Xvfb, `plymouthd --no-daemon --tty=/dev/console`
  in a container started with `-t`, then `plymouth --show-splash`,
  `plymouth ask-for-password`, and a screenshot of the root window;
  `PLY_CREATE_FAKE_MULTI_HEAD_SETUP=1` gives two heads. Remove
  `label-pango.so` first to draw text as the initramfs does.
- `bootc upgrade` does **not** re-embed the theme: it's baked into the initramfs
  at build time only. `--add ostree` is required or switch-root fails. Don't
  drop `plymouth.ignore-serial-consoles` or VMs lose the splash.

---

## 3. GRUB / boot menu

**Menu text** (`live-env/src/iso.yaml`, Margine's ISO): entries explicitly read **"Install
Margine"** (+ *Basic Graphics Mode*, + *verbose, no splash, no serial*, +
*Enroll Secure Boot key (MokManager)*). The ISO volume label must stay
`Margine-Live` (the CDLABEL the boot config references).

**HiDPI font** — GRUB has no DPI scaling, so the only legibility lever is a baked
large font:
- Built in `build_files/50-branding/install.sh` with
  `grub2-mkfont -s 36 -n "Margine"` → `margine.pf2`, shipped under
  `…/bootupd/grub2-static/fonts/`.
- Selected in `…/grub2-static/configs.d/05_margine-gfxmode.cfg` via
  `gfxterm_font="Margine Regular 36"`, `gfxpayload=keep`.
- Uses **Noto Sans Mono** (has box-drawing glyphs U+2500–25FF; Liberation Mono
  doesn't → menu borders render as `?`).

**Gotchas**
- `bootupd` renders `grub.cfg` from the static configs only at install /
  `bootupctl install`, **not** on `bootc upgrade`. Existing installs must run
  `ujust lucciola-grub-hidpi` once to pick up the font.
- `gfxpayload=keep` (native res) beats mode-switching, which is flaky on AMD
  amdgpu UEFI.

---

## 4. GDM / login screen

**File:** `build_files/50-branding/install.sh` → dconf db `gdm.d/` (compiled with
`dconf update`; GDM uses its **own** dconf profile at `/etc/dconf/profile/gdm`).

- **Background** (`gdm.d/01-margine-background`): `picture-uri[-dark]` →
  `/usr/share/backgrounds/lucciola/lucciola.png`, `picture-options='zoom'`,
  `primary-color='#121212'`.
- **Greeter logo** (`gdm.d/02-margine-logo`): `[org/gnome/login-screen] logo=''`
  is **intentionally empty**, and **locked** (`gdm.d/locks/…`). Margine's mark was
  a wide banner GDM stretched across the password field; GDM is only the
  fallback now, so it stays off.

**Gotchas**
- GDM dconf ≠ user-session dconf. Edit the `gdm.d/` db, not the user one.
- The wallpaper must live under `/usr/share/` (mounted before /home at greeter
  time).
- Run `dconf update` or GDM keeps the old compiled db.

### 4b. Lucciola: Noctalia Greeter on greetd

Lucciola's login screen is not GDM (GDM stays installed as the fallback greetd
starts when the greeter cannot come up, and keeps the dconf branding above).

- **Look** (`lucciola/system_files/usr/share/lucciola/greeter/sync.toml`, copied
  once to `/var/lib/noctalia-greeter/sync.toml` by tmpfiles): `scheme =
  "Synced"`, dark, the Margine palette (`palettes/Margine.json` with the keys
  renamed: `mPrimary` becomes `primary`, `mOnSurfaceVariant` becomes
  `on_surface_variant`, and so on), `JetBrains Mono`, Lucciola's wallpaper
  (`/usr/share/backgrounds/lucciola/lucciola.png`), `[session] last = "Lucciola"`.
  Installed systems keep their copy, which names
  `/usr/share/backgrounds/margine/margine.png`: that path is a link to the
  new wallpaper, so they change too.
- **Logo** (`.../greeter/greeter.toml`, linked as
  `/var/lib/noctalia-greeter/greeter.toml`): `hide_logo = false`. The greeter
  has no setting for its logo: it draws `assets/noctalia.svg` 64 px high at the
  bottom centre, **tinted** with the palette's `on_surface` (multiplied).
  `noctalia-greeter.spec` installs `lucciola-mark.svg` in its place
  (`Source1`; the Containerfile copies the mark into the greeter-rpm stage).
- **Failed login text**: greetd reports `<PAM call>: <PAM result>` and the
  greeter showed it as is (`pam_authenticate: AUTH_ERR`).
  `lucciola/greeter/0001-say-pam-results-in-words.patch` (`authErrorText` in
  `src/greeter/greeter_surface.cpp`) maps the common results to sentences
  ("Wrong password, try again", too many attempts, expired account or
  password, login not allowed, auth service not answering); anything else and
  the log stay raw. Upstream candidate. When the pinned tag moves, check the
  patch still applies (`%autosetup -p1` fails the build otherwise).
- **Session name**: the greeter lists sessions by the `.desktop` file's
  `Name=`, so the seeded `last` must stay equal to `Name=Lucciola` in
  `lucciola.desktop` (lucciola/build.sh 5d checks it).

**Gotchas**
- `greeter.toml` wins over `sync.toml`. Anything visual put in `greeter.toml`
  (palette, font, wallpaper) silently disables Noctalia's "Sync with Noctalia"
  for that value: keep the look in `sync.toml`.
- An installed system keeps its `/var/lib/noctalia-greeter/sync.toml` (the
  greeter and Sync own it); a new look in the image reaches it only where the
  file is deleted (it comes back from the image at the next boot).
- The greeter only reads fonts installed system-wide (Fontconfig, as the
  `greetd` account).

---

## 5. Desktop defaults (installed system)

**Wallpaper**: dusk over dark hills with a few fireflies, the scene of the
website's desktop picture (`lucciola/assets/wallpaper/make-wallpaper.py`, a
3840x2400 master anchored at the bottom: other shapes crop sky or sides,
never the hills). `/usr/share/backgrounds/lucciola/` has the 3840x2160,
2880x1920 and 2560x1600 renders; `lucciola.png` links to the 16:9 one and is
the default everywhere:
- GNOME and its lock screen: gschema override
  `/usr/share/glib-2.0/schemas/zz1-margine.gschema.override` (named **zz1** so
  it loads *after* the base's own overrides), `picture-uri[-dark]`;
- GDM: `gdm.d/01-margine-background` (section 4);
- Noctalia: `lucciola/system_files/usr/share/lucciola/noctalia/15-wallpaper.toml`
  (`[wallpaper.default] path`; a wallpaper picked in Noctalia goes to its
  `settings.toml`, which wins);
- the greeter: `sync.toml` (section 4b).

Compat links `/usr/share/backgrounds/margine/{margine,autumn-leaves}.png` →
`../lucciola/lucciola.png` keep every old path (user dconf, installed
greeters' `sync.toml`) showing the new wallpaper.

**Accent** (`build_files/30-gnome-defaults/install.sh`): `accent-color='yellow'`,
read by the GTK applications of the Lucciola session. GNOME is Lucciola's stock
fallback session since 2026-10-18: no dock favourites, workspace count or other
Shell default of Margine's (Margine OS keeps them in its own tree).

**Gotcha:** after editing any `.gschema.override`, `glib-compile-schemas
/usr/share/glib-2.0/schemas` must run (the build does this).

**App menu entries** (`build_files/50-branding/install.sh`): Bluefin's
`discourse.desktop` and `documentation.desktop` are removed, `system-update.desktop`
gives way to `margine-system-update.desktop`. The **Margine Documentation**
launcher (`margine-documentation.desktop`, icon `margine-documentation`,
`margine-docs-open`) left on 2026-10-18 with the offline docs: Lucciola's guide
is online and nothing replaces the entry.

---

## 6. Live ISO: "Welcome to Margine" (Margine's ISO)

**File:** `live-env/src/build.sh` (live image only). anaconda-live ships a GJS
welcome app + an autostart `.desktop`, both saying "Welcome to Fedora":
- GJS source patched: `sed 's/Welcome to Fedora/Welcome to Margine/g'` on
  `…/anaconda/gnome/fedora-welcome` (and `…/org.fedoraproject.welcome-screen`).
- Autostart `Name=` patched: `s/^Name=Welcome to Fedora$/Name=Welcome to Margine/`.
- **Last-resort fallback** greps `/usr/share/anaconda` + `/etc/xdg/autostart` for
  the string and patches whatever it finds (survives anaconda file moves).

**Gotchas**
- Anaconda **moves/renames** these files between releases — that's why the script
  tries multiple paths + a grep fallback. If a future anaconda breaks the rebrand,
  extend the path list, don't hardcode one.
- The dialog **title** reads os-release `NAME` (already "Margine"); the
  alt-tab/overview label reads the `.desktop Name=` — both are handled.
- The dialog **icon** is `fedora-logo-icon` (provided by the base image, see
  foundation).

---

## 7. Anaconda installer: window icon (Margine's ISO, the hard one)

> This one has bitten us repeatedly. Read the whole thing before touching it.

**Goal:** the installer window shows the Margine logo (not a generic placeholder)
in the overview/dock, with the label "Install Margine" instead of "Anaconda Web
UI".

**How GNOME picks a window's icon (Wayland):** it matches the window's **app_id**
(== Wayland `app_id`, the modern WM_CLASS) to a `.desktop` by either
(a) a `.desktop` whose `StartupWMClass=` equals the app_id, or
(b) a `.desktop` whose **basename** equals `<app_id>.desktop`. It then shows that
`.desktop`'s `Icon=`. **`QIcon::fromTheme` / `setWindowIcon` are ignored** by the
overview on Wayland — only the in-window titlebar uses them.

**The installer engine** is `slitherer` (a Qt6 webengine running anaconda-webui).
It calls `setDesktopFileName("org.fedoraproject.AnacondaInstaller")`. On Qt6
Wayland that value **becomes the app_id** → the real app_id is almost certainly
`org.fedoraproject.AnacondaInstaller`. The packages ship **no** matching
`.desktop`: anaconda ships only `liveinst*.desktop` + welcome-screen, and the
`slitherer` RPM ships **no `.desktop`/icon at all** (verified by inspecting the
built live image, 2026-06-30). With no `<app_id>.desktop` present, nothing matched
→ generic placeholder + "Anaconda Web UI" label.

**The fix** (`live-env/src/build.sh`, anchors `AnacondaInstaller`, `_wmid in`):
1. Alias `margine-logo` onto the icon name the window expects, in **two sizes**
   (SVG can render blank on the overview's raster badge):
   `…/hicolor/scalable/apps/org.fedoraproject.AnacondaInstaller.svg` and
   `…/256x256/apps/org.fedoraproject.AnacondaInstaller.png`, then refresh the cache.
2. Ship a **NoDisplay window-matcher `.desktop` for every realistic app_id** —
   `slitherer`, `org.fedoraproject.AnacondaInstaller`, `anaconda-webui`,
   `org.fedoraproject.Anaconda` — each `Icon=margine-logo`. Whichever the real
   app_id is, one matches.
3. After `anaconda-live` installs, `desktop-file-edit` its `liveinst.desktop`:
   `Icon=margine-logo` + `StartupWMClass=slitherer` (the Aurora-proven path; covers
   an XWayland fallback where the app_id would be the binary name `slitherer`).

**VERIFIED WORKING 2026-07-04** — Daniel confirmed the Margine icon on the
Anaconda WebUI window on the published `margine-20260703.iso` (the multi-matcher
build). Do not remove any of the three layers above without re-testing on a
fresh ISO in the SB test VM.

**Gotchas**
- **Ordering:** the matchers + icon alias run *before* the `dnf install
  anaconda-live anaconda-webui …` (note: `slitherer` is **not** installed
  explicitly — it arrives as a dependency selected by `webui_web_engine =
  slitherer` in `margine.conf`). That's currently safe **only because those
  packages ship none of these files** (verified). If a future anaconda/
  slitherer starts shipping `org.fedoraproject.AnacondaInstaller.desktop` or that
  icon, the dnf install will **clobber** our versions — then move the alias +
  matcher block to *after* the dnf install. (Re-verify with
  `rpm -ql slitherer anaconda-core anaconda-webui | grep -E 'desktop|icons'` inside
  the built live image.)
- **Get ground truth if it ever regresses:** boot the ISO, open the installer, then
  `Alt+F2 → lg → Windows` tab and read the window's `wm-class`/`app` — that is the
  definitive app_id. `xprop WM_CLASS` only works if it's an XWayland window.
- Don't bother with `setWindowIcon`/theme icon hacks — the overview ignores them.
- `liveinst.desktop` is renamed to `anaconda.desktop` by livesys at boot; the
  `StartupWMClass` edit survives the rename.

**Installer config** (`live-env/src/anaconda/profile.d/margine.conf`): profile id
`margine`, detected by `os_id=fedora` **and** `variant_id=margine`; BTRFS +
`zstd:1`, `default_partitioning` enforced (don't add explicit `part` directives —
anaconda-webui v68 then shows CUSTOM); hidden Network/Password/User spokes (WebUI
handles them). The `%include` post-scripts are wired from
`live-env/src/anaconda/interactive-defaults.ks`.

---

## 8. Live ISO: "Secure Boot is disabled" notice (Margine's ISO)

**File:** `live-env/src/build.sh` (anchor `margine-live-sb-notice`).
A one-shot autostart (`/etc/xdg/autostart/margine-live-sb-notice.desktop` →
`/usr/libexec/margine-live-sb-notice`) that, **only in the live session and only
if SB is off** (`mokutil --sb-state`), shows a `zenity --info` explaining that
Margine supports Secure Boot, how to enroll (boot-menu MokManager or first-boot,
passphrase `margine`), and links the docs. Idempotent via a marker in
`$XDG_RUNTIME_DIR` (falls back to `/tmp`).

**Gotchas**
- It uses a **plain `zenity --info`** (the default info icon). An earlier
  `--icon-name=margine-logo` was reverted — Daniel did **not** want the Margine
  logo inside the dialog body.
- The zenity *overview* icon (the taskbar/alt-tab entry for the dialog window) is
  still generic — zenity gives no control over its Wayland app_id. Fixing that
  needs replacing zenity with a tiny Adwaita app whose app_id we own. **Deferred.**
- Live-only: the autostart entry exists on the ISO, never on the installed system.

---

## 9. Secure Boot / MOK (installed system)

**File:** `build_files/custom-kernel/install.sh`.
- **Passphrase:** `margine`: **public by design** (printed in the guide,
  `SECURITY.md` and `lucciola/README.md`; users type it into MokManager). Only the *signing key* is secret.
  The key is the one Margine OS signs with, so its certificate is named
  "Margine MOK Signing Key" and the password stays `margine`: an install that
  came from Margine already has it enrolled.
- Kernel + all modules signed with the MOK at build; a
  sha256 check fails the build if the kernel changes after signing. One key → one
  enrollment.
- Installed cert: `/usr/share/cert/MOK.der`. `mok-enroll.service` imports it on
  every boot until shim has it, **with Secure Boot on or off** (the key must be
  in shim before SB is turned on); a login notification explains the MOK Manager
  screen; `ujust lucciola-secureboot` shows the state (2026-10-04).
- Margine's ISO offers `Enroll Secure Boot key (MokManager)` (chainloads `mmx64.efi`) so the
  key can be enrolled from the boot menu before install.

**Gotcha:** keep the passphrase LETTERS ONLY. MokManager runs in the
firmware with a US layout assumed, so a hyphen or any symbol lands on a
different key for Italian/German/French users, who are typing it blind
(issue #353). It protects nothing, so there is nothing to trade against
typability.

**Gotcha:** Margine's installer stages its own MOK cert via
`…/anaconda/post-scripts/secureboot-enroll-key.ks`; the installed-system path
(`/usr/share/cert/MOK.der` + `mok-enroll.service`) is separate. See the handbook
for the user-facing provenance/SB docs (now in `docs/history/margine/spec/`).

---

## 10. First-login experience & notifications (installed system)

All under `build_files/system_files/`. All autostart entries follow Golden Rules
4 & 5 (no `X-GNOME-Autostart-Phase`; `Exec=` → a `/usr/libexec` wrapper).

- **Bootstrap** (`usr/libexec/margine/first-boot-bootstrap`): runs `ujust
  lucciola-bootstrap unattended` (default applications, Zen, darktable; the
  Margine home layout left it on 2026-10-18, new accounts keep the standard
  XDG folders). Idempotent marker `~/.config/margine/bootstrapped`. Margine
  starts it from a GNOME-only autostart entry; Lucciola ships no autostart for
  it (2026-10-18), so in Lucciola it runs only by hand.
- **First-boot status** (`usr/libexec/margine-first-boot-status`): notifies if
  `flatpak-preinstall.service` is still installing the deferred heavy apps
  ("installing extra apps… ~5–15 min"), and "Lucciola is ready" when done (the name from `product-name`). Marker
  `~/.cache/margine/first-boot-notified`. Same as the bootstrap: no autostart in
  Lucciola.
- **Upgrade notify** (`usr/lib/systemd/user/margine-upgrade-notify.service`):
  post-reboot **confirmation** — at login, if the booted deployment digest
  differs from the recorded one, toasts "Lucciola updated / Now running: …".
  The "reboot to apply" role belongs to staged-update notify, not here. State
  advances only after the notification succeeds, so a missed toast retries at
  the next login.
- **Staged-update notify** (`…/margine-staged-update-notify.{timer,service}` →
  `usr/libexec/margine/staged-update-notify`): timer is `OnStartupSec=20min` +
  `OnCalendar` at 09/13/17/21 with `Persistent=true` (wall-clock on purpose —
  monotonic `OnUnitActiveSec` never fires on a suspending laptop). The script
  posts three distinct notice classes: (1) "Update ready" once per staged
  checksum, at the first tick that sees it; (2) a once-per-day "staged for N
  days" nag only once the staged deployment is ≥2 days old; (3) a once-per-app
  notice when the update watchdog excludes an extra-data app.

**Gotchas**
- Notifications go through **`margine-notify`** (see section 12) — not
  `notify-send`. Only `margine-upgrade-notify.service` is actually bound to
  `graphical-session.target`; the timer and the autostart entries can tick
  without a session, and headless safety comes from the scripts themselves
  (a failed notification exits non-zero and the stamp/marker is not written).
- Every notifier is idempotent via a marker — don't remove the marker checks or
  users get spammed each login.

---

## 11. CLI branding

**File:** `build_files/50-branding/install.sh` + `60-ujust-services/install.sh`.

- **fastfetch:** logo `/usr/share/margine/ascii-logo.txt` (from
  `lucciola/assets/fastfetch-logo.txt`: the firefly in shaded blocks over the
  name), config `…/fastfetch/margine.jsonc` (logo colours `$1` beige, `$2`
  sand, `$3` the halo, `$4` text; keys in sand), wired as the system default
  via a `/etc/fastfetch/config.jsonc` symlink; `lucciola-fetch` runs it.
- **MOTD off:** Bluefin's tipline is suppressed by pre-creating
  `/etc/skel/.config/no-show-user-motd`; the Bluefin shell-init files
  (`ublue-motd.sh`, `ublue-fastfetch.sh`, `90-bluefin-starship.sh`,
  `91-bluefin-aliases.sh`) are deleted from **both** `/etc/profile.d` and
  `/usr/etc/profile.d` (Golden Rule 1).
- **`/etc/issue`:** first line `Lucciola \r (\m): Fedora Silverblue + CachyOS signed
  kernel`, second line `\d \t` (emergency console only). The kernel reserve
  (`:fedora-kernel`, `/usr/share/margine/kernel-flavor` = `fedora`) writes
  `Fedora's kernel` in place of `CachyOS signed kernel`; the CPU Scheduler's
  description and `lucciola-status` name the kernel that runs the same way.
- **ujust:** recipes live in `build_files/60-custom.just`, mostly under
  `[group('Lucciola')]` (`lucciola-bootstrap`, `lucciola-ai`, `lucciola-test-vm`, …;
  `lucciola-gaming` sits under `[group('Gaming')]`), discoverable via
  `ujust --list`. They were `margine-*` until 2026-10-18; each old name is a
  just `alias` (the block at the end of the file), which `ujust --list` shows
  as `[alias: margine-…]` on the recipe's line. `margine-tpm2-enroll` stays a
  deprecated recipe of its own. A `[doc('...')]` attribute gives a recipe its
  one-line description where the comment above it is long.
- **Commands:** `/usr/bin/lucciola-*` (status, autologin, keyring, tpm-unlock,
  fetch, dev-groups, and the `validate-*`/`configure-*` helpers that
  `40-spec-scripts` installs) are the real files; each `margine-*` name is a
  relative link to its `lucciola-*` file (`validate-image-rootfs.sh` A.4.names
  checks them).
- **Names that keep `margine`** on purpose: paths (`/usr/libexec/margine`,
  `/etc/margine`, `/usr/share/margine`, `~/.local/state/margine`), unit names,
  `VARIANT_ID`, the app ids (`dev.margine.System`, `dev.margine.PhoneCam`:
  the Wayland app_id must match the `.desktop` name, and dock pins refer to
  it), the managed-block markers written into users' Zen `user.js`
  (`margine-configure-zen-browser`, `margine-netflix-1080p`: they are found by
  them), the test VM names (`margine-test-*`), "Margine key" (the MOK's own
  name), and the GRUB static config (any byte change makes
  `margine-grub-hidpi` rewrite `/boot/grub2/grub.cfg` on every install).

---

## 12. Notification icons — the lock screen trap

**Symptom (found 2026-07-15, GNOME 50):** every Margine notification showed the
Margine logo in the tray/banner but the generic `application-x-executable`
gears on the **lock screen**, for all our notifiers at once.

**Root cause (wire-verified with `dbus-monitor`):** libnotify's `notify-send`
sends the fdo `Notify` call with the **`app_icon` field empty** and carries
`--icon` only in the `image-path` **hint**. GNOME Shell renders two different
icons:
- the **notification's own icon** (tray banner + message list) comes from the
  `image-data`/`image-path` hints → looked right;
- the **source icon** — the ONLY thing the lock screen shows — comes from the
  `app_icon` field (or a matching `.desktop` app) and **never** from
  `image-path` → empty → `St.Icon` falls back to `application-x-executable`.

**Fix:** `usr/libexec/margine/margine-notify`, a notify-send stand-in that
calls `Notify` over D-Bus (gdbus) with **both** `app_icon` and `image-path`
set. Defaults (2026-10-18): the icon is os-release `LOGO` (`lucciola-logo`),
the sender name `/usr/share/margine/product-name` (Lucciola), with os-release
`NAME` and "Lucciola" as fallbacks; `-i` and `-a APP_NAME` override them. All the notifiers (staged-update, upgrade, staleness, first-boot
status) go through it. Matrix-tested on the lock screen 2026-07-15: themed
name, absolute path and Adwaita icons via notify-send all fail; the same
themed name via `app_icon` shows the logo.

**Gotchas**
- **Don't "simplify" back to `notify-send`** — its empty `app_icon` is
  hardcoded upstream; every regression here reintroduces the gears.
- **`desktop-entry` hints are not a substitute:** sources attributed to a
  `.desktop` via hint never appeared on the lock screen at all in the same
  tests (twice). `-d` in margine-notify only adds in-session app attribution
  (e.g. Bazaar for first-boot status), it does not fix the lock screen alone.
- The `--` in the helper's gdbus call is load-bearing: without it gdbus parses
  the `-1` expire-timeout as an option.
- Upstream: GNOME Shell `js/ui/unlockDialog.js` binds `source.icon` with
  `fallback_icon_name: 'application-x-executable'`; `notificationDaemon.js`
  only sets the source icon from `app_icon` (`_iconForNotificationData(appIcon)`)
  when the source has no app. Same class of bug reported against GSConnect in
  2019 (grey gear on lock screen) — this is old, unfixed upstream behavior.


---

## When you add a NEW branding touchpoint

1. Decide the surface: installed system (`build_files/`) or ISO (`live-env/src/`)?
2. If it's an icon: install the SVG under `hicolor/scalable/apps/`, add a raster
   size if anything renders it as a small badge, then rebuild the cache (`-f -t`).
3. If it's dconf: write the keyfile, then `dconf update`; remember GDM is a
   separate db; consider a lock if users shouldn't override it.
4. If it's an autostart `.desktop`: no `X-GNOME-Autostart-Phase`; `Exec=` a
   wrapper; `desktop-file-validate` it.
5. If it reuses a name Fedora hardcodes (logos, icon names): **replace, don't
   delete** — and note *who* hardcodes it here.
6. If it's a window icon: confirm the real Wayland **app_id** (`Alt+F2 → lg →
   Windows`) before shipping a matcher; don't guess.
7. **Add a row to this doc.** A touchpoint that isn't here is a touchpoint that
   gets broken later.

---

*Updated for Lucciola's own identity on 2026-10-18 (logo, wallpaper, boot
splash, greeter, names). Source map assembled 2026-07-01 from a full sweep of
`build_files/` and `live-env/`. Re-verified claim-by-claim against the code 2026-07-15 (stale
notifier semantics, timer schedule, anchors and package lists corrected; the
icon-cache `-t` rule is now actually enforced in `50-branding`). Line numbers
deliberately omitted — grep the anchors.*
