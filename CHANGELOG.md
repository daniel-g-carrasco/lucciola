# Changelog

All notable changes to the Lucciola bootc image build are recorded here.
Image tags follow `stable`, `stable.YYYYMMDD`, `YYYYMMDD`.
Semantic versioning (`v0.X.Y`) will start once the first user-facing
stable release is cut.

## [Unreleased]

### Changed (boot splash on black)
- **The boot splash is drawn on black instead of #121212,** like the
  firmware, GRUB and the console around it, so the screen keeps the same
  shade from power-on to the login screen.

### Added (the kernel reserve: Lucciola with Fedora's kernel)
- **A second image, `:fedora-kernel`, the same Lucciola with Fedora's own
  kernel instead of the CachyOS one.** A bootc image carries one kernel,
  so the fallback is an image: built from the same commit and the same
  base as the current `:stable`, right after each promotion, signed the
  same way (with its SBOM) and published only after the same QEMU boot
  test with Secure Boot and a TPM. Fedora's kernel is generic x86-64 and
  signed by Fedora: it starts on processors without x86-64-v3, and it is
  the way out when a CachyOS kernel update misbehaves.
  - **Switching:** `ujust lucciola-kernel fedora`, `ujust lucciola-kernel
    cachyos`, and `ujust lucciola-kernel` to see which kernel runs. It
    moves the install to the other image at the next restart, keeps the
    signature-checked transport and layered packages, and leaves the
    previous system in the boot menu. It refuses the CachyOS kernel on a
    processor without x86-64-v3, or with Secure Boot on and the Margine key
    not enrolled.
  - **TPM disk unlock:** with Secure Boot on, PCR 7 records which key
    signed the kernel, so the first boot after a switch asks for the disk
    passphrase. The command says so before it switches, and what to run
    after that boot: `ujust lucciola-tpm-unlock enable`.
  - **The same everywhere else:** the phone camera's v4l2loopback is built
    against Fedora's kernel and signed with the Margine key, the CPU
    scheduler picker works (Fedora's kernel has sched_ext; its default is
    EEVDF instead of BORE), same firmware, same apps. Fedora's kernel and
    its modules keep Fedora's signature.
  - Under the hood: `--build-arg KERNEL_FLAVOR=fedora` (default `cachyos`,
    so `:stable` is built as before), `build-fedora-kernel.yml` (after each
    promotion, and a manual run that publishes only `:fedora-kernel-test`),
    `/usr/share/margine/kernel-flavor` in both images, and the validators,
    `lucciola-status` and the boot probes accept Fedora's kernel on the
    reserve only. The tag name lives in
    `/usr/share/margine/kernel-reserve-tag`.

### Added
- **A welcome window at the first login.** New users of the Lucciola
  session get one short page in the website's look: the keys first, then
  how updates work (what Lucciola System does and does not do, where
  Homebrew fits), apps arriving in the background, and a button for the
  guide. It comes back at each login until it is closed once, and
  "Lucciola Welcome" in the launcher reopens it. Accounts that already used
  Lucciola see it once too, at their first login after the update. Not in
  the GNOME session.
- **The developer layer: `ujust lucciola-devmode`.** One command, in the
  spirit of Universal Blue's `ujust devmode`, brings what Bluefin DX gave
  developers and the image no longer carries: VS Code from Microsoft's
  repository (signing key pinned, repository kept so VS Code updates with
  the system), gcc, g++ and make, flatpak-builder and
  git-credential-libsecret, layered with rpm-ostree, plus Homebrew in
  /home/linuxbrew/.linuxbrew from Homebrew's own installer. Homebrew stays
  out of the image: its payload would add to every update of every
  install. `status` shows what is in place, `remove` takes the packages
  away and asks separately before deleting Homebrew. The shells pick
  Homebrew up by themselves (bash, zsh, fish), after the system's own
  commands. Like the gaming layer, the build resolves the package list
  against each new image before pushing it, and the smoke test dry-runs it
  on the booted image.
- **A content editor for the website and the welcome window.** `just edit`
  opens a local page in the browser: on the website, click a text to change
  it and use the small bar on a section, paragraph, command or key to move,
  hide, copy or delete it; the welcome window is a form with a live preview.
  Save checks first and changes only what was edited; "Propose changes"
  puts the saved changes in a pull request, never on main. See
  `tools/content-editor/README.md`.

### Changed
- **The welcome window's texts are data.** Its sections, their order and
  every text now live in `/usr/share/lucciola/welcome/content.json`; the
  window looks exactly as before. A check in CI and on the built image
  stops a broken file.

### Changed (Lucciola's own identity)
- **Lucciola looks like Lucciola from the boot to the desktop.** Until now
  the boot splash, the About page, notifications and the commands still
  showed Margine OS, and the login screen and the desktop showed Margine's
  and Noctalia's wallpapers.
  - **Boot splash:** the lucciola wordmark centred on the dark surface, its
    firefly breathing slowly as on the website (6 seconds, bright to dim
    and back). The disk password prompt matches: a field in the login
    screen's colours, a small firefly for each character typed, and a
    "Caps Lock is on" hint. Sharp on HiDPI screens: the splash sizes itself
    in the screen's own pixels.
  - **Wallpaper:** dusk over dark hills with a few fireflies, on the
    desktop, the login screen and the GNOME session (renders for 16:9, 3:2
    and 16:10 screens in `/usr/share/backgrounds/lucciola/`). A wallpaper
    picked by hand stays. The login screen of an existing install changes
    too: its old wallpaper path now leads to the new one.
  - **Logo:** the firefly on a dark tile is the system's logo (the About
    page, notifications on the desktop and the lock screen), with the
    wordmark as the About page's distributor logo; the login screen shows
    the firefly at the bottom. fastfetch draws the firefly over the name
    in the palette, and the console banner and the boot messages name
    Lucciola, in its beige.
  - **Login screen:** a wrong password reads "Wrong password, try again"
    instead of `pam_authenticate: AUTH_ERR` (and too many attempts, an
    expired account or password are said in words too).
  - **Names:** the commands are `lucciola-*`: `ujust lucciola-update`,
    `ujust lucciola-status`, `lucciola-fetch`, and the rest in
    `ujust --list`. **The old `margine-*` names keep working**, as aliases
    that `ujust --list` shows next to the new ones. The System app is
    "Lucciola System", with an icon in Lucciola's colours (a dock pin of
    it keeps working), next to "Lucciola CPU Scheduler"; the phone webcam
    appears to apps as "Lucciola Phone Cam" after the next restart;
    `ujust lucciola-report` writes `~/lucciola-report.txt`; new installs
    are called `lucciola` on the network.
  - Under the hood, unchanged on purpose: paths, unit names and
    `VARIANT_ID` keep `margine`, and Secure Boot still asks for the
    "Margine key" with the password `margine`.

### Changed (Margine's name, where Lucciola's belongs)
- **The texts that still said Margine now say Lucciola.** The README,
  with the wordmark as its title, the security policy and the security
  claims register are written for Lucciola; the bug report form asks how
  you got Lucciola. A few messages the rename had missed are fixed:
  `lucciola-status` and `lucciola-tpm-unlock` pointed at the old
  `ujust margine-*` names, the validator called itself "Margine", and
  some notices could fall back to "Margine OS". Margine's design
  documents (the handbook, ADRs, notes and changelog) moved to
  `docs/history/margine/`. The Secure Boot key keeps its name, "Margine
  MOK Signing Key", with the password `margine`: Lucciola signs with the
  key Margine used, and MOK Manager shows that name.
- The smoke boot's security probe now checks that the device verifies
  signatures for Lucciola's own repository, not only Margine's.

### Removed (lighter image: on demand instead of in every install)
- **What only some people use is installed when they ask for it.** Measured
  on two local builds of the same base (this branch and its parent): 450
  packages fewer (221 of them i686), btop added; installed tree 1.33 GiB
  smaller (14.16 to 12.82 GiB); 47 enabled units and three setuid helpers
  fewer. An install keeps what it has where noted.
  - **The 32-bit Steam libraries** (221 i686 packages, 723 MiB). They were
    in every image so that `ujust margine-gaming-native` only had to add
    the applications; the recipe now layers the whole chain (432 packages,
    about 750 MiB to download the first time, against 132 and 540 before).
    What the old bake also did, bringing the image packages the chain
    needs to the versions the repositories have (31 of them on this build:
    NetworkManager, glib2, glycin, libcurl, openh264 in place of the
    noopenh264 stub...), the build still does, without installing the
    chain, and it stops unless the layer then resolves with installs only.
    Two CI checks guard it: right after the build,
    `gaming-native-resolve.sh` resolves the layer in a throwaway container
    of the image with every package locked at its version, the way
    rpm-ostree layers, and fails the build when it does not resolve;
    smoke-boot's rpm-ostree dry run still blocks promotion, and a missing
    package list now fails there too. mangohud and goverlay (vkBasalt came
    as their weak dependency) left as well: both gaming recipes layer them,
    so running the recipe again brings them back, and the validator no
    longer reports "gaming remnants: vkBasalt" on every system. RPMFusion
    is enabled at build time only for v4l2loopback now. zenity, which only
    came with the bake, is installed on its own: Noctalia and
    distrobox-export call it.
  - **The VM stack** (290 MiB): libvirt, QEMU/KVM, virt-manager,
    virt-viewer, virt-install, OVMF, swtpm and podman-machine.
    `ujust margine-vm` layers them and enables the libvirt sockets for the
    next boot, when wheel users join the libvirt group; `ujust
    margine-test-vm` points to it when they are missing.
  - **Six preinstalled apps:** VS Code, Bitwarden, GNOME Weather, GNOME
    Maps, Blanket and Fragments, all in Bazaar (`ujust margine-vscode`
    still layers the VS Code RPM). An install that has them keeps them.
  - **The Koofr tray shim** (47-koofr-tray-fix): it downloaded gcc and
    glibc-devel on every build and left cpp (42.6 MiB) behind, for a
    client Spola replaced. libappindicator-gtk3 went with it. `ujust
    install-koofr` stays, but Koofr's tray icon may not work under
    Noctalia.
  - **The offline docs**, their refresh timer and the Margine Documentation
    launcher: Lucciola's guide is online.
  - **The tuned profiles** balanced-margine, powersave-margine and
    throughput-performance-margine, which nothing selected.
  - **mesa-demos, glow, podman-tui and python3-pip** (87 MiB), which nothing
    in the image calls. btop comes in: Mod+Ctrl+T opens it and it was
    missing.

### Changed (home folders)
- **New accounts keep the standard folders** (Documents, Downloads,
  Pictures...). `ujust margine-bootstrap` no longer applies Margine's
  layout (`~/data`, `~/dev`, `~/scratch` with the XDG folders inside
  them); `margine-configure-home-layout --apply` still does, on purpose,
  and `ujust margine-home-stock` goes back. No file is moved. Screenshots
  follow the XDG Pictures folder from the first login.

### Changed (build)
- **The initramfs is generated once per build**, after the Plymouth theme,
  instead of twice (one dracut run is about 26 s on a 12-core laptop); the
  result is the same file.
- **The HIP compiler is no longer downloaded and deleted on every build.**
  The package that stands in for hipcc is installed before rocm-hip, so
  dnf never pulls the compiler: 7 packages and 44 MiB instead of 84
  packages, 437 MiB and 3 GiB unpacked. rocm-llvm-libs and rocm-clang-libs
  (192 MiB), which the old order left in the image, are gone too; an
  OpenCL kernel still builds on a Radeon 760M (gfx1103) and HIP sees the
  GPU. Together with the items above, a build downloads 618 MiB of
  packages instead of 1517 MiB.

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
- **A calmer login screen.** The wallpaper behind the login card is
  Lucciola's own, blurred and a little darker, so the card and the firefly
  logo stand out; the card and the fields take the deep blues of its sky
  instead of the desktop's greys, and the palette button in the top right
  corner is gone. Installed systems get it with the update, nothing to do.
  The look is now fixed in the image: Noctalia's Sync Now still brings the
  screen layout, and a wallpaper you picked in Noctalia, but no longer the
  desktop's colours and font.
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
- **New system accounts on updated machines with layered packages.** rpm-ostree moves such a machine's system accounts to `/usr/lib/passwd`, while its own `/etc/shadow` survives the update without the new account's line; systemd-sysusers then finds the account and writes nothing. After the move from `margine:lucciola` that left greetd without a shadow line, PAM could not look it up and the greeter's user manager failed. At every boot `margine-seed-etc-passwd` now copies the missing shadow and gshadow lines from the image's own defaults (`/usr/etc`), or adds a locked line for an `/etc` account the image does not know, and never touches existing lines.
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
  [docs/history/margine/CHANGELOG.md](docs/history/margine/CHANGELOG.md).
