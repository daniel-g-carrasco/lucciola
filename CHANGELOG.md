# Changelog

All notable changes to the Lucciola bootc image build are recorded here.
Image tags follow `stable`, `stable.YYYYMMDD`, `YYYYMMDD`.
Semantic versioning (`v0.X.Y`) will start once the first user-facing
stable release is cut.

## [Unreleased]

### Added (2026-10-31, Bitwarden on Wayland)
- **A tweak puts Bitwarden on native Wayland with a working clipboard.**
  Bitwarden copies through a native module that needs the ext/wlr
  data-control protocol, which niri hides from Flatpak apps (their
  restricted, security-context connection). The module falls back to X11:
  on Wayland its copies never reach other apps, on X11 they depend on the
  xwayland-satellite bridge. Lucciola System, Apps, Tweaks, "Bitwarden on
  Wayland" (or `ujust lucciola-bitwarden-wayland enable`) gives Bitwarden
  the compositor socket under a second name, made at each login by
  `lucciola-bitwarden-wayland-link.service`, through a user Flatpak
  override: the normal connection, where the protocol is there. The price,
  said in the dialog: on that connection Bitwarden could also use niri's
  other privileged protocols. Off by default; it edits only its own
  override keys. Workaround from bitwarden/clients#21288.
  `tests/bitwarden-wayland.test.sh` (13 checks, in lint).

### Changed (2026-10-31, workspaces and Desktop)
- **Mod+1 to Mod+9 go to the workspace at that position**, Mod+Shift+1 to
  Mod+Shift+9 move the window there. Workspaces are niri's own, dynamic:
  Lucciola no longer seeds two named ones at the first login, and Mod+3 no
  longer leads nowhere.
- **The Desktop folder is `~/scratch/desktop`, not the home.** With
  XDG_DESKTOP_DIR on the home, Flatpak apps with the xdg-desktop permission
  (Pinta, Heroic, Protontricks) were given the whole home.

### Fixed (2026-10-30, build)
- **Every main build since 2026-10-27 stopped at the package-removal guard:
  Universal Blue's base dropped `ublue-os-udev-rules`.** With it went the
  udev rules for game controllers, FIDO/U2F and Titan security keys,
  Wooting keyboards and Framework input modules. The build installs the
  same package (0.10) from the ublue-os/packages COPR it already uses for
  uupd, key pinned by fingerprint, and checks that the rules are in place.
  Until a new image is published, machines with the gaming layer cannot
  update either: the last image carries nss 3.131 from a Fedora 45 nightly,
  which the frozen repositories no longer have in 32 bits.

### Added (2026-10-26, local AI models)
- **Language models on this PC, for every app that uses them.** Lucciola
  System, Apps, Local AI Models (or `ujust lucciola-models`) installs
  Ollama as a service of the user: no root, the release and the sha256 of
  its Linux archive pinned in `/usr/share/lucciola/models/ollama.release`,
  unpacked in `~/.local/share/lucciola/ollama`, `ollama` in `~/.local/bin`.
  `lucciola-ollama.service` answers on 127.0.0.1:11434 only, with Vulkan
  and integrated GPUs on (Ollama skips them otherwise) and a 16k context
  for agents. Alpaca, Meridio, editors and agents find it at the address
  they look at first. NVIDIA's CUDA libraries, about 2 GB, are left out on
  PCs without an NVIDIA GPU. `lucciola-ollama-update.timer`, enabled for
  every user, brings the users who have it to a new pin. Remove keeps the
  downloaded models unless asked.
- Measured on a Radeon 760M with the same GGUF (Qwen3.5 4B, a ~3500-token
  prompt): 293 tokens/s reading and 11.8 writing on the GPU, 80 and 7.2 on
  the processor; llama.cpp's own server gave the same numbers, as Ollama
  runs it inside. Fedora's ollama (0.24) is too old for this year's models,
  Ollama's container is 5 GB with Ubuntu's Mesa: the archive it is.
  `tests/local-models.test.sh` (20 checks, in lint), two mutants, the
  validator's 6c2, the guide's apps chapter.

### Fixed (2026-10-25, bootloader update after the move from Fedora 44)
- **The HiDPI GRUB step no longer breaks bootupd's bootloader update.**
  From Fedora 45 bootupd updates the bootloader at boot. On the first boot
  after the move from Bluefin (Fedora 44) to Lucciola it failed halfway:
  `grub2-install` could not write `/boot/grub2/i386-pc` ("Read-only file
  system"), and the EFI update after it never ran, leaving Fedora 44's shim
  and GRUB. `margine-grub-hidpi.service` started beside it, remounted the
  read-only `/boot` read-write for its own write and put it back read-only
  when done, a remount of the whole filesystem that reaches bootupd's
  mount namespace too. Fedora alone, Silverblue 44 to 45, moved cleanly.
  The HiDPI step now runs after `bootloader-update.service`, which is also
  the right order for the GRUB config bootupd may rewrite. Found by the
  weekly upgrade smoke once it printed the failed unit's journal (#56, #57).
  A check in `tests/grub-lock.test.sh`, a mutant.

### Changed (2026-10-25, upgrade smoke)
- **The upgrade smoke can run a stock Fedora move.** The bootloader update
  failed after the move from Bluefin (Fedora 44) to Lucciola, on a
  read-only `/boot`; to tell Fedora's own upgrade problems from Lucciola's,
  the same move has to run with Fedora alone, Silverblue 44 to 45. The
  Secure Boot step needed the target's MOK certificate, which a stock
  Fedora image does not carry: such a target now boots with the Microsoft
  keys alone, while an image of ours without the certificate still fails.

### Changed (2026-10-25, upgrade smoke)
- **A failed unit after the upgrade now says why.** The weekly upgrade
  smoke's first run found `bootloader-update.service` failed after the move
  from `bluefin:stable` (Fedora 44) to Lucciola, and nothing more: the
  journal dump keeps only errors, and bootupd's own messages are below
  that. The smoke now prints each failed unit's last journal lines, and
  `bootupctl status` when the bootloader update is the one that failed.
  The unit names come from the captured console text, so only real unit
  names reach journalctl (`tests/upgrade-smoke-units.test.sh`).

### Added (2026-10-24, mouse and keyboard from the phone)
- **Remote Input works under niri.** KDE Connect's remote input, and
  anything that moves the pointer or types through the portal, asks the
  RemoteDesktop portal; the GNOME backend serves it only on Mutter's D-Bus,
  which niri does not implement, so under niri it offered no device at all.
  xdg-desktop-portal-luminous (waycrate's backend for wlroots-style
  compositors, not in Fedora) now ships in the image, built from its pinned
  tag like the greeter, from the tag's archive checked against its sha256
  and the crates at the versions Cargo.lock pins. `niri-portals.conf` sends
  RemoteDesktop, and only that, to it: the GNOME backend keeps screencast,
  screenshots and the rest. Tried on a laptop on 2026-10-23: the portal
  offered keyboard, pointer and touch where it had offered nothing, and the
  phone's keyboard typed on the laptop. The guide's phone chapter says it.

### Fixed (2026-10-23, build)
- **A kernel bump no longer stops the main build at the package-removal
  guard.** akmods names the module package after the kernel it was built
  for (`kmod-v4l2loopback-7.3.0-4.cachyos1...`), so the guard that compares
  the new image's packages with the published image's read every kernel
  bump as one package removed and one added, and stopped main (7.3.0
  cachyos1 to 7.3.0-4, 2026-10-23). A module package now counts by its
  module, `kmod-<module>`, whatever kernel it was built for; a module gone
  for good still fails, by that name. Three cases in
  `tests/package-removal-guard.test.sh`, a mutant.

### Fixed (2026-10-23, the first day with the phone)
- **No red line at login.** niri-session handed the session's environment
  to the user manager with a blanket `systemctl --user import-environment`,
  and systemd 258+ prints "Calling import-environment without a list of
  variable names is deprecated" on the login screen's terminal, for a
  moment, at every login. The script now does what upstream niri does:
  `dbus-update-activation-environment --systemd --all`, one call for D-Bus
  activation and the user manager, no warning; `dbus-tools` joins the image
  for it. Patched by content in `lucciola/build.sh`, checked by the build
  and by the validator.
- **A folder opens in Files under niri, not in Disk Usage Analyzer.** GNOME
  names its default applications in `gnome-mimeapps.list`, which counts
  only when the desktop calls itself GNOME; under niri nothing named a
  handler for folders, and the first registered one won: Disk Usage
  Analyzer, which is what Browse the Phone in Files opened.
  `niri-mimeapps.list` is a link to GNOME's list, so niri takes the same
  defaults for folders, images, mail and the rest; a choice made in
  Settings still wins.
- **The phone's card stays open.** Ring, Send a File, every switch ended
  in a refresh that rebuilt the card closed. The card remembers that it was
  open.
- **Use as a Webcam sits with the phone's other actions**, right after
  Browse the Phone in Files, instead of at the bottom under the switches.
- **A page shown again within half a minute keeps what it has.** Every
  click in the sidebar reread the page from the system and rebuilt it; the
  periodic and the focus refresh keep it fresh anyway.

### Fixed (2026-10-23, build)
- **Every build of main failed from 2026-10-22: Noctalia's fallback to
  Koji looked for rpm-trust where the Lucciola stage mounts nothing.**
  Fedora 45's release repositories (fedora-repos 45-1) switched
  updates-testing off, and noctalia-5.3.0-1 is only there until its update
  goes stable; the pinned-build helper then fetches Fedora's signed copy
  from Koji, as designed (#39), and verifies it with rpm-trust, which it
  read from `/ctx/system_files`. The Lucciola stage mounts only
  `00-common.sh` and its own script from the context, so the helper found
  no rpm-trust, could not read the release key, and gave up ("is in neither
  the repositories nor Koji's signed copies"). With no copy beside
  `00-common.sh` it now reads the one the image already carries,
  `/usr/libexec/margine/rpm-trust`. Two cases in
  `tests/pinned-fedora-build.test.sh`, a mutant without the fallback.

### Added (2026-10-22, app colours)
- **Apps follow the Noctalia palette, Flatpak ones included.** Noctalia's
  gtk3, gtk4 and kcolorscheme templates are on by default
  (`28-app-colors.toml`; choosing templates in Noctalia's settings replaces
  the list). Until now only apps outside Flatpak followed: checked app by
  app on 2026-10-22, Bazaar, Loupe, Snapshot, Calculator, Text Editor and
  the rest saw no stylesheet, even with access to the whole home; only
  Spola, whose manifest asks for `gtk-4.0`, did.
  `lucciola-flatpak-theme-access.service` gives every Flatpak app read-only
  access to `~/.config/gtk-3.0`, `gtk-4.0` and `kdeglobals` at boot, and
  sets `QT_QPA_PLATFORMTHEME=kde`, so the KDE runtime's platform theme
  reads the palette (ZapZap: Fusion with a blue selection before, Breeze in
  the palette after; Warehouse: the accent buttons in the palette). The
  GTK folders also hold GTK's bookmarks, the list of favourite folders,
  which apps can now read, never write.
- **Zen and Vesktop in their Flatpak versions.** Noctalia's community
  templates for them, once turned on in its settings, write where the
  Flatpaks cannot read; `lucciola-app-colors-flatpak`, a user path unit
  and the same service at login, copies their output into the Zen profiles
  and the Vesktop theme folder, with the one preference `userChrome.css`
  needs (not `devtools.chrome.enabled`, which the template also sets). The
  community repository carries no licence, so Lucciola ships no copy of the
  templates. `tests/app-colors.test.sh`, two mutants, the validator's 6d.

### Changed (2026-10-21, Phone Camera in the Phone page, rebuilt)
- **Phone Camera is a section of the Phone page**, not a window of its own
  any more, and it is rebuilt: Lucciola drives scrcpy's own server on the
  phone in raw-stream mode and decodes the bare H.264 with GStreamer
  straight into PipeWire. "Lucciola Phone Cam" is a PipeWire video source
  that the camera portal, Flatpak browsers, GNOME apps and calls see at
  once, with no kernel module in the way; when the v4l2loopback device is
  there the video is copied into it too, for apps that only speak V4L2.
  The node outlives the phone: a change of lens or a dropped link keeps
  Lucciola Phone Cam listed while the phone is picked up again, for a
  minute and a half, before the stream gives up; the apps see a few
  seconds of black and then the picture again, without picking the camera
  anew. The sizes come from the server's own list, per lens, under a jar
  name of Lucciola's: a server run with cleanup on, which is how the
  scrcpy client runs it, deletes its jar at start, and it took ours with
  it (the front camera "was not found"). Found on a real Pixel 8 while
  rebuilding it: the node now flows with no app linked (pipewiresink with
  async off: before, nothing moved until an app opened the camera, the
  preview included), keeps flowing once an app links (pipewiresink no
  longer lends its buffer pool upstream: apps got about seventeen frames
  and then a frozen or black picture), never renegotiates its format (one
  set of caps for the session: a mid-stream change made v4l2loopback
  answer "device busy" and took the node down), and the preview and the
  V4L2 copy run as pipelines of their own, so neither can hold the node
  back. The picture stands upright: a phone's camera sensor sits sideways,
  so the phone turns it by the sensor's own orientation (read from the
  phone, 90 behind and 270 in front on a Pixel), and Rotate turns it a
  quarter more for a phone on its side or upside down; a portrait picture
  lands in the landscape frame between black bars, and the turn, like the
  lens, changes without the node going away. A dark room no longer means a
  black camera: in raw-stream mode the server sends nothing until the
  camera's first frame, which a dark scene or the back camera's several
  sensors take seconds to give, and the wait for it gave up after 2.5
  seconds and hung up, so the server closed; now an accepted connection is
  kept for up to 20 seconds. The watchdog counts bytes from the phone, not
  decoded frames, over 10 seconds, so a dark scene at two frames a second
  is not taken for a dropped link, and the software decoder, when it is
  the one picked, runs one thread and holds no frames back. The resolution changes only
  while the camera is stopped, since a new size is a new node and GNOME's
  Camera closed when its node went away; the list offers 16:9 and 4:3 from
  640 pixels wide up to 1080p, not the sensor's 12 megapixels. In the
  phone's card: the
  Camera row with the real state, Use as a Webcam (lens, rotation,
  resolution, Start, preview), Stop while streaming. A Camera Over USB group covers a phone on
  the cable with or without KDE Connect. The Phone Camera launcher stays and
  opens the page.
- **Over Wi-Fi**: Set Up Wireless shows a QR code the phone scans in
  Wireless debugging (Pair device with QR code), pairs by itself when the
  phone advertises the pairing service, and connects; typing the six-digit
  code stays as the other way. Afterwards the page finds the phone through
  adb's mDNS discovery and connects by itself, or sends a reminder to the
  phone when wireless debugging is off. 720p at 4 Mbit/s over the air, 1080p
  at 8 Mbit/s over the cable. qrencode joins the image for the QR code.
- **The phone's microphone**: a switch in the camera dialog runs a second
  stream (bare PCM from scrcpy's server) into a PipeWire audio source,
  "Lucciola Phone Mic", any call can pick. Android 11 or later.
- The guide's phone chapter says it, with the native USB webcam of recent
  Pixels first for who has the cable.

### Added (2026-10-21, Phone page)
- **A Phone page in Lucciola System**, over KDE Connect's daemon on the
  session bus: the name this PC shows to the phone (editable), the devices
  on the network with their state (connected, paired but away, wanting to
  pair with the key to compare, available), Pair, Accept and Reject,
  battery, Ring the Phone, Send a File, the functions per device as
  switches (phone notifications here, this PC's notifications on the
  phone, clipboard, files and links, the phone in Files, media control,
  battery, ring, commands, volume, ping), Add Ready-Made Commands (lock the
  screen with Lucciola's lock, suspend, power off, mute, keep awake until
  midnight and stop), Forget This Phone. Notifications to the phone start
  off on Lucciola, written once through the daemon when a paired phone is
  first seen: they carry their text, the user turns them on. The page
  refreshes itself on the daemon's signals. Without the phone layer it
  points to Features; KDE Connect's own window stays one row away.

### Added (2026-10-21, phone link)
- **Phone, the first row of the Features page of Lucciola System**, and
  `ujust lucciola-phone`: KDE Connect's service (kdeconnectd), its tray
  indicator and command line (kde-connect), the Files extension
  (kde-connect-nautilus) and fuse-sshfs as an optional layer, about 260 MB,
  with an autostart entry for the indicator and the kdeconnect service in
  the firewall. With the KDE Connect app on an Android phone, same Wi-Fi:
  notifications both ways, one clipboard, files and links in a tap, the
  phone's storage in Files, media control, battery and ring, commands.
  Mouse and keyboard from the phone wait for a RemoteDesktop portal under
  niri. One list, `/usr/share/margine/phone-packages.txt`, for the helper,
  the build's resolve check, the smoke-boot dry run and the upgrade smoke,
  so a machine with the phone link always updates. The guide has a phone
  chapter.

### Added (2026-10-21, Lucciola System: Features and Apps)
- **Two more pages in Lucciola System: Features and Apps.** Features
  installs and removes the optional layers with a button each, the state
  read from the system every time: Gaming (with the native variant as an
  option), Sunshine, the Developer Layer (Homebrew included, installed as
  you), VS Code, Docker CE, Tailscale, Virtual Machines, Developer Tools
  and Alpaca (with the AMD GPU plugin when there is an AMD GPU). A banner
  offers the restart when system packages wait for one. Apps trims the
  default app set to Slim or Naked and brings the stock set back, shows the
  apps excluded from automatic updates, removes unused runtimes, installs
  Spola, and turns the per-app tweaks on and off (Netflix in 1080p in Zen,
  darktable and Blender on an AMD GPU through ROCm). Hardware gained the
  automatic dock display rescue switch, Wake a Dock Display, Repair Printer
  Queues (shown with the leftover queues) and, on a home with Margine's
  folder layout, Use the Standard Home Folders.
- **One definition per feature**: `/usr/libexec/lucciola/feature` (status,
  install, remove, for gaming, gaming-native, ai, devmode, vscode, devtools,
  docker, tailscale, vm, sunshine, slim and naked) and
  `/usr/libexec/lucciola/printers-repair`. The ujust recipes keep their
  explanations and their one question, then call the same verbs of the
  privileged helper the window calls (`<feature>-on`/`-off`, `apps-slim`,
  `apps-naked`, `apps-restore`, `brew-remove`, `printers-repair`,
  `dock-wake`, `dock-rescue`, 27 new polkit actions, one each). No recipe
  layers packages or installs system Flatpaks on its own any more;
  `lucciola-update-unblock` goes through `flatpak-unblock` too.
- Tests: the dispatcher's plans for every new verb, the helper's shape (no
  prompts, root checked, every feature known), each recipe reaching the
  dispatcher, and the pure functions behind the pages (feature states,
  the gaming variants, the app profiles, the dock switch, the printer
  queues, the home layout, the tweaks).

### Added (2026-10-21, Lucciola System pages)
- **Lucciola System has pages now: Overview, Startup & Security, Login,
  Hardware**, behind a sidebar that folds on a narrow window. Startup &
  Security shows Secure Boot and whether Lucciola's key is registered
  (with Register the Key at the Next Restart… and Stop Reminding Me),
  the disk unlock by the TPM (enable, typing the current passphrase once,
  or go back to asking it; only with Secure Boot on and the key
  registered), the boot menu lock (set a password, or remove it) and the
  kernel (CachyOS or Fedora's, what is followed and what is staged, with
  the switch). Login opens the fingerprint panel of Settings, shows the
  keyring and how it opens at login (store the password sealed to the TPM,
  or remove it) and has the automatic login switch, with its warning.
  Hardware takes the CPU scheduler in: what runs now and at startup, the
  mode, a chooser that lists the schedulers only when asked (asking
  scxctl starts the service), and the way back to the kernel's own
  scheduler. Every page reads the real state when shown and after each
  action; nothing is remembered. The guide's commands for TPM, GRUB,
  kernel, keyring and autologin now have a button.
- **One polkit action per verb for all of it**: `kernel`,
  `tpm-unlock-status/-enable/-disable`, `grub-lock-status/-on/-off`,
  `autologin-on/-off`, `secureboot-enroll/-never`, `scheduler`,
  `scheduler-off` join `update`, `rollback` and `flatpak-unblock` in
  `/usr/libexec/lucciola/admin`. The two `*-status` verbs only read and
  need no password from an active user. Secrets never travel as
  arguments: the window writes the disk passphrase, the boot-menu
  password and the keyring password on the helper's standard input, and
  they reach `systemd-cryptenroll` as a root-only key file
  (`lucciola-tpm-unlock` learned `LUCCIOLA_UNLOCK_KEY_FILE`), `grub-lock`
  on its stdin, `lucciola-keyring` on its stdin when not at a terminal.
  `autologin-on` takes the user from pkexec, never from an argument.
- **The CPU scheduler's own window and its polkit rule are gone.**
  `49-margine-scheduler.rules` gave `auth_admin_keep` on
  `org.freedesktop.policykit.exec` for one program, and polkit keeps such
  a grant for the action id, not the program: after one scheduler prompt
  the same process could run anything through pkexec for a few minutes
  without a prompt. The scheduler has its two actions now, the launcher
  "Lucciola CPU Scheduler" opens the Hardware page, and `ujust
  lucciola-scheduler` goes through the same helper. The old window also
  started `scx_loader.service` just by being opened (every poll asked
  scxctl); the page reads `/sys/kernel/sched_ext` and the service's state
  instead.

### Changed (2026-10-21, Lucciola System)
- **Lucciola System speaks to people who never open a terminal.** Pending
  app updates are named by app, not by Flatpak id; the texts no longer
  quote commands; the rows are either information or a link, and the
  actions are button rows (Run System Check…, Roll Back…, Update Apps
  Now, Update Command-Line Tools), as the HIG asks. While it checks, it
  shows a spinner instead of a frozen icon; when the registry cannot be
  reached it says so (offline, too slow, unreachable) and offers Try
  Again; it refreshes on its own every ten minutes and when the window
  comes back after a while. The window opens at once and About no longer
  freezes it while `lucciola-status` runs. A long operation shows a
  sentence and a spinner with the output under Details; the dialog can be
  closed and a message follows, with the log one click away if it failed.
  The menu gains Keyboard Shortcuts, Help (the guide, offline too) and
  Report a Problem…, which writes `~/lucciola-report.txt` and offers the
  issue page; `ujust lucciola-report` now calls the same
  `system-report`. The System Check results can be copied. Apps the
  update watchdog excluded are listed under Apps with Update Now, which
  takes them back into automatic updates; the notification that used to
  quote a command now points there and opens Lucciola System when
  clicked, as the "update ready" ones do.
- **Privileged actions go through `/usr/libexec/lucciola/admin`**, one
  polkit action each (`dev.lucciola.admin.update`, `.rollback`,
  `.flatpak-unblock`): the authentication dialog says what is about to
  happen, an administrator can allow one action without the others, and
  an active user keeps the authentication for a few minutes. The helper
  validates its arguments, runs fixed argument vectors and never a
  shell; `tests/system-logic.test.sh` checks the refusals and that every
  verb has its policy. The toolkit-free part of the app lives in
  `/usr/share/lucciola/system/lucciola_system.py`, tested without a
  display.

### Changed (2026-10-21, app icons)
- **Six app icons in one family style**: Lucciola System (the firefly),
  Welcome (the light mark), the guide (an open book), Phone Camera (an eye),
  CPU Scheduler (the lightning bolt) and the update launcher (a triangle in a
  circle). Each is a dark disc with a two-tone subject, no strokes and no
  filters; the ivory-disc and symbolic variants and the Inkscape masters are
  under `docs/branding/` (rules in `docs/BRANDING.md`, "App icons: the family
  style"). Welcome no longer borrows the system logo as its icon, and the
  update launcher has an icon of its own instead of the stock name, so the
  build no longer downloads one from MoreWaita; the scheduler icon is a
  tracked file instead of a heredoc in the branding script. The rootfs
  validator checks the six files and the two launchers.

### Added (2026-10-20, SSH agent)
- **An SSH agent in every session.** GNOME's `gcr-ssh-agent` is enabled for
  all users, socket-activated; the socket sets `SSH_AUTH_SOCK` in the user
  manager, so niri and everything it starts see it. It offers the keys in
  `~/.ssh`, asks a passphrase in a dialog the first time a key is used and
  can keep it in the keyring, which the login opens. Without an agent a
  passphrase was asked at every connection, so keys stayed unprotected on
  disk. The build refuses an image where the socket is not enabled, and
  `validate-margine-system` checks it on the installed system.

### Fixed (2026-10-21, build)
- **A build no longer fails at random on a package the mirrors have
  dropped.** While Fedora 45 is a pre-release, metadata can still list a
  build every mirror has already removed: on 2026-10-21 expat-2.8.5, gone
  after 2.9.0, failed image builds with "All mirrors were tried" and a 404
  on each mirror, five retries in a row on the same metadata. The gaming
  alignment now works in rounds, each on one view of the repositories (the
  plan and the installs it picks, as before); a round whose downloads fail
  is thrown away and the next plans again on fresh metadata, four rounds at
  most. The logic lives in `build_files/custom-kernel/gaming-align.sh`,
  tested with a fake dnf in `tests/gaming-align.test.sh`, with a mutant that
  keeps one view only.

### Fixed (2026-10-20, welcome window)
- **The welcome window no longer redraws all day.** The firefly's glow is a
  CSS animation, which has GTK redraw the window on every frame: left open
  on another workspace since the login, it had used an hour of CPU in a
  day (5% of a core, steadily). It now glows only while the window is the
  active one.

### Added (2026-10-20, checks that can fail)
- **Mutation checks.** Each guard the two reviews looked at is broken on
  purpose, one file per breakage in `tests/mutants/`, and its test must
  fail (`.github/scripts/mutation-check.py`, `just mutate`): the secret
  scanner printing a token, symlinks resolved on the runner, the staleness
  check calling `bootc status`, `rpm-trust` accepting `gpgcheck=0`, the
  signed-transport migration taking any image of the owner, the sign job
  without its condition, a `tail` hiding a failed command, a base that does
  not resolve, `flatpak-preinstall-keep` doing nothing. A mutant whose test
  stays green is a guard nobody tests. Weekly and on pull requests that
  touch the guards (`mutation.yml`, ntfy on failure); lint applies every
  mutant on every pull request so a moved guard is noticed at once.
  `tests/mutation-check.test.sh`.
- **A pull request that changes the image needs the `vm-test` label to
  merge.** A new check in lint, `build-inputs-need-vm-test`, runs on every
  pull request and fails, saying what to do, when the changed files include
  the Containerfile, `build_files/`, `lucciola/`, `installer/`,
  `disk_config/`, `build.yml`, the validators or the security baseline and
  the label is missing; adding the label re-runs it and makes `build.yml`
  build `:pr-N`. Renovate adds the label to the same paths. Meant to be a
  required check (see `tools/repo-guard.sh`). `tests/vm-test-gate.test.sh`.
- **Where the signing secrets may appear is written down and checked.**
  `tests/policy/secret-stages.txt` names the Containerfile stage whose RUN
  may mount a build secret (`mok-sign`, with `--network=none`; the final
  stage never may) and `tests/policy/secret-jobs.txt` the workflow jobs
  that may name `secrets.MOK_*` and `secrets.COSIGN*`; lint fails on a
  secret anywhere else, on a stale entry, on a secret outside a step's
  `env:`, and unless the step that stages the MOK key to disk is followed
  at once by the build and then by the wipe, with no action in between
  (`.github/scripts/check-secret-scope.py`). `build.yml` now stages the
  key right before `buildah build` and wipes it right after, instead of
  before the metadata action and at the end of the job. The Containerfile
  part is red until the signing stage (pull request #30) is in main: that
  is the state of the tree. `tests/secret-scope.test.sh`.
- **The security claims register must name its proofs.** A lint
  (`.github/scripts/check-claims.py`) fails when a claim marked verified
  or partial in `docs/SECURITY-CLAIMS.md` names no test, script or
  workflow step that exists in the tree, or names one that does not, and
  when a test under `tests/` is run by neither `lint.yml` nor
  `mutation.yml`. C1, C3, C5, C7, C12 and C14 now name the test, script or
  step that proves them (they named only words); C13, measured once and
  never re-checked, is unverified rather than partial. The register gains
  a table for the two reviews' findings, R1-R10 and N1-N9, each with its
  fix and its test, the ones whose pull request is not in main yet marked
  "pending merge"; the monthly review issue lists those until they are
  verified. `tests/check-claims.test.sh`.
- **The upgrade test runs every Sunday from every documented start.**
  `upgrade-smoke.yml` keeps its manual run and gains a schedule (08:00
  UTC, after the weekly build): from `margine:lucciola` with `cowsay`
  layered, from stock Silverblue 45, Kinoite 45 and Bluefin, all to
  `:candidate`, one VM at a time, a failed cell notifying ntfy by name
  without cancelling the others; `steam` layered on `margine:lucciola`
  joins once `:stable` is promoted (before Fedora 45's release it cannot
  resolve, a known state). `.github/scripts/upgrade-matrix.py`,
  `tests/upgrade-matrix.test.sh`.
- **No package leaves the image unnoticed.** Every main build compares
  its `rpm -qa` with the published `:candidate` and writes the added and
  removed packages in the step summary; a removed package must be listed,
  dated, in `build_files/expected-removals.txt`, and a line older than
  two weeks fails the build, so the file never becomes an allowlist. This
  is the guard against the 2026-10-11 base-trim cascade, when images
  without Nautilus and Ptyxis were published with every check green. Pull
  requests and a registry without `:candidate` are skipped; a trial build
  reports only. `.github/scripts/package-removal-guard.py`,
  `tests/package-removal-guard.test.sh`.
- **Every shell script runs in strict mode, or says why not.** A lint
  (`.github/scripts/check-strict-mode.py`) wants `set -euo pipefail` (in
  one of its spellings, or a `source` of `00-common.sh`) in the first 30
  lines of every shell script under `build_files/`, `lucciola/`,
  `.github/scripts/`, `.github/smoke/` and `tests/`; the 35 that cannot
  (validators and probes that run every check and count the failures,
  helpers that handle each command's result themselves, one-line exec
  wrappers) are listed with their reason in
  `tests/policy/strict-mode-allowlist.txt`, and an entry without a reason,
  for a missing file or for a script that is strict after all fails. One
  test had `set -u` alone and is strict now. `tests/strict-mode.test.sh`.
- **Branch protection as code.** `tools/repo-guard.sh` (`just repo-guard`)
  holds the protection `main` should have: the always-running lint jobs
  (`lint`, `flatpak-preinstall`, `build-inputs-need-vm-test`, `policy`)
  as required checks on an up-to-date branch, a pull request with no
  approval needed, conversations resolved, admins included, no force-push,
  no deletion. `check` prints the drift and `apply` sets it after a typed
  yes; neither has been run: `main` is unprotected today. A weekly
  workflow (`repo-guard.yml`) reads the public `protected` field and
  notifies when it is false. Only jobs that run on every pull request may
  be required: one that does not run blocks the merge forever (the pitfall
  is written in the script). `tests/repo-guard.test.sh`.

### Changed (2026-10-20, Keep Awake)
- **Keep Awake no longer leaves the laptop unlocked.** Its one mode kept
  sleep, the idle lock and the lid switch away together, so a laptop closed
  in a bag ran unlocked, with its session, keyring and keys open to whoever
  opened it. The default now keeps sleep away and nothing else: the screen
  locks on idle as usual, and closing the lid locks the session at once
  (unless another monitor is on: at a desk a closed lid means nothing) and
  holds the power profile on power-saver until the lid opens, so the bag is
  locked and cooler. `--screen` (the panel's "Screen on", the launcher's
  "screen") keeps the screen on and the idle lock away too, for a talk or a
  film, two hours unless told otherwise; the lid locks the session all the
  same. The unit watches the lid through UPower and locks with
  `/usr/libexec/lucciola/lock`. `tests/keep-awake.test.sh`; two mutants in
  `tests/mutants/`.
### Fixed (2026-10-21, build)
- **The gaming-native alignment uses one snapshot of the repositories.**
  The plan, the alignment and the check refreshed the metadata each, so
  each could land on a different mirror; while expat 2.9.0 propagated
  through updates-testing the build stopped with "still needs to change
  image packages after the alignment" on an image that was fine. The first
  plan refreshes, the other two reuse its metadata.

### Fixed (2026-10-20, build)
- **The pinned Noctalia build could leave the repositories and stop every
  image build.** `NOCTALIA_VR` pins noctalia to 5.3.0-1, which Fedora 45
  offers only in updates-testing (FEDORA-2026-04f44a27d9) while it is a
  pre-release: at the release (27 October) that repository goes away, and
  a newer Noctalia obsoleting the update before then would have had the
  same effect; from that day every build of the image, security updates
  included, failed on the install, at the worst possible time. Fedora
  keeps every build in Koji, with a copy signed by the release key. The
  install now asks the repositories for the exact build first and, when
  they no longer have it, fetches that copy, checks it with `rpmkeys`
  against the Fedora release key in the image (dnf does not check a local
  file) and installs it in the same transaction as niri,
  xwayland-satellite and ddcutil, weak dependencies off as before; the
  build then checks that the installed noctalia is the pinned one. The log
  says which path was taken; a bad signature, a signature by another key,
  or a build Koji does not have fail the build at once, naming the URL.
  The kernel reserve's kernel-devel install, which already did this for
  Fedora's kernel, uses the same helpers (`fetch_signed_rpm`,
  `verify_fedora_signature`, `dnf_install_pinned` in
  build_files/00-common.sh): it now also insists that the signer is the
  release key and not any key the rpmdb holds, and a 404 from Koji fails
  at once instead of after five retries. Tested with fake dnf5, curl and
  rpmkeys (tests/pinned-fedora-build.test.sh, run by lint); the real
  signed copy of noctalia-5.3.0-1.fc45 was fetched and verified with the
  same helpers in a Fedora 45 container. The Lucciola step now sources the
  shared helpers, so its installs carry `SOURCE_DATE_EPOCH` like every
  other step. Bumping `NOCTALIA_VR` when upstream moves stays a reviewed
  change with a test boot (release checklist).
### Changed (validator)
- **Apps still downloading are pending, not failures.** Since the first
  preinstall run no longer holds the boot, `lucciola-validate-margine-system`
  run in those minutes reports an app the run has not reached yet as a
  warning, not as a missing app; once the run has passed, a missing app is
  a failure as before.
- **Stock Fedora starting points.** The "fedora" and "fedora-testing"
  Flatpak remotes a Silverblue or Kinoite install leaves behind are removed
  before the first preinstall, unless apps were installed from them.
### Fixed (2026-10-20, layering)
- **An outage of Cisco's openh264 mirror no longer fails `rpm-ostree
  install`.** rpm-ostree fetches the metadata of every enabled repository
  before it layers anything and ignores `skip_if_unavailable`; on
  2026-10-20 Cisco's mirror was down for over ten minutes and every
  layering failed, in the upgrade test as on installed systems. The image
  now ships `fedora-cisco-openh264` disabled: its openh264 comes from
  negativo17 and updates with the image, nothing is layered from Cisco.
  `validate-margine-system` checks it (9f). The upgrade test also makes
  three attempts at layering, 45 seconds apart, for the older images it
  starts from, which still have the repository on.

### Fixed (2026-10-20, lint)
- **The MOK signer test runs whole on the lint runner.** The runner has no
  `systemd-sbsign` and keeps its kernel image root-only, so the test put
  no `vmlinuz` in its tree; `finalize.sh` then refused the list ("no
  vmlinuz checksum") and the three refusal checks passed for that reason
  instead of their own. The lint job now installs `systemd-sbsign` and
  signs systemd-boot's EFI binary in place of the kernel, and
  `MOK_TEST_REQUIRE_PE` makes a skip a failure there. Without the tool the
  test stands a stub in for `vmlinuz` and still exercises the install
  step, and every refusal is checked by its reason. Changes under
  `tests/` alone no longer rebuild the image.

### Fixed (2026-10-20, SBOM)
- **scrcpy is in the SBOM.** It is installed from its release tarball, not
  an RPM, so the published SBOM listed its files and no scrcpy package: no
  version, licence or advisory could be matched to it. The build now
  records each component it installs outside RPM (scrcpy, the uBlock Origin
  seed, the MoreWaita icon) in `/usr/share/margine/sbom/` with version,
  supplier, download URL and checksum, licence, purl, CPE and its files,
  and CI merges those records into the SBOM after checking each file
  against the image (`.github/scripts/sbom-add-components.py`); a build
  without scrcpy's record fails. `tests/sbom-components.test.sh`.

### Fixed (2026-10-20, checks)
- **The security scan and the SBOM describe the image that is published.**
  Both read the image as built, before chunking; the chunker then rebuilds
  the image from its files (it prunes `/run` and `/sysroot`), and that is
  what is pushed and signed. A scan of the published image of 2026-10-20
  differed from the baseline the build had called clean. They now run on
  the chunked image, loaded once and checked against the config its
  manifest names, and the push refuses a registry manifest with another
  config, so the digest the signature covers is the image that was scanned.
  The residue baseline is empty (what it held lived in `/run`). Same for
  the kernel reserve. `tests/scan-what-ships.test.sh`.

### Security (2026-10-20, scrcpy updates)
- **A scrcpy update is pinned only if upstream signed it.** Renovate
  proposes new scrcpy releases and merges them by itself; the companion
  workflow pinned whatever sha256 the release download had, so the pin
  proved nothing about who published the bytes, and a release made with a
  stolen GitHub account would have been built (as root, in the image
  build) and shipped by automation alone. The pin now comes from the
  release's `SHA256SUMS.txt`, after its OpenPGP signature checks out
  against the scrcpy maintainer's key pinned in `.github/keys`
  (`.github/scripts/scrcpy-signed-sha.sh`); the Renovate PR is checked
  again with main's copy of the script, and a release without signed
  checksums or signed by another key leaves the PR red, unmerged and
  unbuilt until someone looks. `tests/scrcpy-signed-sha.test.sh`.

### Security (2026-10-20, kernel signing)
- **The MOK private key no longer shares a build step with anything
  else.** The key that signs the kernel and its modules was mounted in the
  RUN that installed the CachyOS kernel from COPR and RPM Fusion's release
  RPM from a URL, and that then ran every build script, the downloaded
  scrcpy included: any package scriptlet or downloaded program could read
  it, and with it sign kernels every machine with the key enrolled would
  boot. That RUN now has no secret: it lists what must be signed. A stage
  of its own (`mok-sign`), FROM the clean base, with no network and nothing
  installed, runs only `custom-kernel/mok-sign.sh`, with the key mounted
  and the files to sign as read-only data; it refuses paths that leave the
  kernel's directory or go through a symbolic link. The last RUN
  (`custom-kernel/finalize.sh`) puts the signed vmlinuz and modules in
  place only if the image still holds exactly the files that were signed,
  checks the signatures and writes the initramfs (moved from 50-branding,
  since it packs the signed modules). Modules are signed with openssl the
  way the kernel's `sign-file` does, byte for byte, instead of running the
  COPR's `sign-file` with the key. The build stops if the key is ever
  mounted where build steps run. Signed as before: same key, same
  signatures, same Secure Boot behaviour. Whether earlier builds exposed
  the key cannot be told from the image; rotating it would need a migration
  for every enrolled machine and is a separate decision.
  `tests/mok-secret-scope.test.sh`, `tests/mok-sign.test.sh`.
### Fixed (2026-10-20, second review)
- **`ujust lucciola-autologin` changes both login screens or neither.** It
  writes greetd's config and mirrors the choice into GDM's, and wrote them
  one after the other in place: if the GDM file could not be written, the
  command failed with greetd's passwordless login already on. Both files
  are now prepared next to the originals first and only then swapped in;
  if the second swap fails the first is put back, and the error says that
  nothing was changed. The file that removes the password is always
  swapped last.
- **No login screen after moving from Kinoite with SDDM selected.** A
  display manager link changed on the old system survives the update; the
  login migration left any link other than GDM's alone, so one to SDDM
  (or LightDM, or any display manager Lucciola does not have) pointed at
  nothing and no login screen started. It now keeps such a link only when
  that display manager is installed; otherwise it switches to greetd,
  starts it at once and says so in the journal.
- **The content editor (`just edit`) answers only the page it opened.**
  Its key was written into the page the server handed to anyone who asked,
  so another program on the computer (a Flatpak app with network access
  reaches 127.0.0.1 too) could read it and save, commit, push and open a
  pull request with your GitHub login while the editor ran. The key now
  travels only in the address the editor opens (`#k=...`, which the browser
  never sends back), every `/api/` request needs it, and a request from a
  foreign page is refused. If the tab gets closed, open the address
  printed in the terminal again.
- **Login screen on two monitors: the password typed on one is sent from
  the other.** The login conversation follows the screen the pointer is
  on, but the text typed in the password field stayed in the first
  screen's field: Enter on the second found it empty and started the
  fingerprint over instead of logging in, and unplugging the first screen
  lost the text. The typed password now moves with the conversation and
  the old field is emptied (greeter patch 0005, release 6).
- **The guide's way back works for every starting system.** "Going back"
  gave only Fedora Silverblue 44's address, wrong for Kinoite and Bluefin
  and a step backwards from Fedora 45. "Before you start" now saves the
  name of the system you have (`~/lucciola-came-from.txt`), "going back"
  switches to it, lists the addresses for Silverblue, Kinoite and Bluefin
  on the release Lucciola is built on, and says what stays: files,
  settings and Flatpak apps, and that going back a version does not undo
  app changes. A new "fingerprint" section turns on fingerprint login
  (`authselect enable-feature with-fingerprint`, which the image does not
  enable) and registers a finger with `fprintd-enroll`.

### Removed (2026-10-20, developer tools)
- **Margine's ISO tooling is archived.** `live-env/` (the Titanoboa live
  image), `tools/iso-builder/` (the window that built it) and
  `tools/bench/` moved to `docs/history/margine/`, with a README. They
  built and tested Margine, not Lucciola, and the window dispatched a
  workflow this repository does not have. Gone with them: the `just
  build-iso`, `build-iso-fast`, `test-install-vm`, `iso-gui` and
  `install-desktop` recipes, the lint step that compared the ISO's Flatpak
  list with the image's, and the static checks of the ISO's kickstarts
  (the Flatpak preinstall check stays). Lucciola moves installs by rebase
  first; the ISO comes later, ported from the archive.
  `installer/flatpaks-base`, which the image build reads, stays.
  `tests/retired-iso-tooling.test.sh`.

### Fixed (2026-10-20, build)
- **The base an image records is the base it was built on.** The build
  looked up the digest of `silverblue-main:45` only for the
  `org.opencontainers.image.base.digest` label, and if the lookup failed
  the label stayed empty; buildah then pulled the tag again. Had the tag
  moved in between, the label named a base the image was not built on, and
  the kernel reserve, which builds on the labelled digest, would have used
  a different base from the image it stands in for. The base is now
  resolved once (`.github/scripts/resolve-base.sh`): the build is FROM that
  digest, both labels come from the same lookup (`base.name` now follows a
  trial base too), and a build whose base cannot be resolved stops.
  `tests/resolve-base.test.sh`.

### Fixed (2026-10-20, checks)
- **Some checks passed when the command they ran had failed.** The upgrade
  test sent `rpm-ostree rebase`, the layering of a package and the
  gaming-native dry run to the test machine as `command | tail`, in a shell
  without `pipefail`, so the status it read was `tail`'s, always a success;
  a missing gaming package list counted as a pass. The same held for the
  dependency check in `validate-baseline-packages`, which also reported
  every package found when its container stopped before checking any. Each
  now keeps the command's own exit status, prints only the end of its
  output, and fails on a missing list. `tests/pipeline-status.test.sh`.

### Security (2026-10-20, third-party repositories)
- **A pinned signing key now means that key alone.** The build and the
  `ujust lucciola-docker`, `lucciola-tailscale`, `lucciola-vscode` and
  `lucciola-devmode` recipes checked only the first fingerprint in a
  downloaded key file and then handed rpm the whole file, and rpm imports
  every key in it: a file with the right key first and another one after it
  passed, and packages signed by the second key would have installed. The
  repository file was kept as downloaded apart from its `gpgkey=` lines, so
  `gpgcheck=0` in any section survived too. Both now go through one helper,
  `/usr/libexec/margine/rpm-trust`: a key file with any other primary key is
  refused and only the pinned certificate (with its own subkeys) is saved or
  imported; a repository file that turns signature checking off in any
  section is refused, and every section gets `gpgcheck=1` and the local,
  verified key in place of whatever `gpgkey` it named. The same applies to
  the RPM Fusion and negativo17 repository files the build reads.
  Checked against the live Docker CE, Tailscale, VS Code, COPR, RPM Fusion
  and negativo17 keys and repositories. `tests/rpm-trust.test.sh`.
### Fixed (2026-10-20, docs)
- **The install instructions named images that do not exist yet.** The
  README, the website (home page and guide), `lucciola/README.md` and
  `SECURITY.md` send people to `:stable`, and the guide and the README to
  `:fedora-kernel`, but neither is published before Fedora 45's release
  (the promotion is held on purpose until then): following the guide meant
  turning Secure Boot off and then getting "manifest unknown". Each of
  those commands now has a short note beside it: the first `:stable`, and
  the Fedora-kernel version with it, comes out with Fedora 45, planned for
  27 October 2026, and until then `:candidate` is the test build to use.
  The notes stay true after that date and can go once it has passed. When
  `ujust lucciola-kernel` cannot stage an image, it now names "an image not
  published yet" among the causes.

### Fixed (2026-10-20, boot)
- **Every boot spent a minute and a half repairing Flatpak.**
  `flatpak-preinstall.service` relabelled all of `/var/lib/flatpak`
  (`restorecon -RF`) and ran `flatpak repair --system` before every
  preinstall, with no time limit, and `multi-user.target` waited for it: on
  a laptop with 351 refs, 34 s plus 53 s, a 15-17 GB memory peak (page
  cache) and the target reached after 1 min 41 s. Both steps exist for
  fresh installs whose bake went wrong (2026-06), and now run only then:
  when the last preinstall did not pass (a first boot, a failed or
  interrupted run) or a quick look at the repository finds it broken (a
  base directory missing, a wrong SELinux type on the top paths), at most
  once per boot (`/usr/libexec/margine/flatpak-repo-repair`). A settled
  boot does the cheap steps and the preinstall itself, about 1.5 s. The
  unit no longer holds `multi-user.target` or `graphical.target`, stops
  after an hour (the restart two minutes later resumes the download), and
  runs at the priority of the Flatpak updates (`Nice=10`, idle I/O) with
  `MemoryHigh=2G`, so the page cache it fills is reclaimed from it first.
  The first boot after this update repairs once more, since no run has
  been marked as passed yet.

### Fixed (2026-10-20, apps)
- **Apps that left the default set were uninstalled.** `flatpak preinstall`
  does not only install: it keeps a record of the apps it preinstalled (in
  the system repository's config) and uninstalls any of them the image
  stops listing. When Bitwarden, VS Code, GNOME Weather, GNOME Maps,
  Blanket and Fragments left the list on 2026-10-18, the next boot removed
  them wherever they were on that record, against what this changelog
  promised. Before every preinstall, `flatpak-preinstall-keep` now takes
  an installed app that is no longer listed off the record, so it stays as
  the user's own app; if the helper fails, the preinstall does not run. An
  app the user removed stays on the record, so Flatpak still does not
  install it again. The real `flatpak preinstall` is tested against a
  local repository, before and after (tests/flatpak-preinstall-keep.test.sh).
  Machines already affected do not get the apps back on their own, since
  some may have been removed on purpose since: their data in `~/.var/app`
  is still there, and Bazaar installs them again.
- **A default app you remove now stays removed on every install.** On
  installs whose record started after their apps were there (those that
  came from Margine), a removed default came back at the next boot. The
  same helper puts every installed default on the record, as Flatpak does
  on a fresh install. `ujust lucciola-slim-restore` now really brings the
  removed defaults back: unmasking the service was not enough, because
  Flatpak remembers the removals; the recipe now forgets them for the apps
  in the stock list.
### Changed (terminal)
- **A new terminal opens in the home folder.** Ptyxis no longer restores the
  last session by default, which reopened terminals in the folder the last
  one was closed in. It can be turned back on in Ptyxis' preferences.

### Fixed (2026-10-19, build)
- **Builds stopped on `/etc/machine-id`.** Since this morning something in
  the build writes a machine id into the image (the base ships the file
  empty), and the security scan rightly refused to publish an image whose
  installs would all share one id. The final cleanup now empties it, as
  the base has it, and says so in the build log.

### Fixed (2026-10-19)
- **Flatpak apps looked signed out (Spola, Fractal, Deja Dup...).** niri's
  portals configuration sends the Secret portal to gnome-keyring, which
  Fedora 45 no longer ships, so apps that keep their passwords through
  libsecret could not open their own keyring. Lucciola now points it at
  oo7's portal (`/etc/xdg-desktop-portal/niri-portals.conf`); the build
  fails if that portal is missing. The passwords were never lost: they come
  back by themselves after the update.
- **"ld.so: object ... cannot be preloaded" in every terminal after moving
  from Margine.** Wayland Scroll Factor, which Margine ships, enables itself
  with an `LD_PRELOAD` line in `~/.config/environment.d`; Lucciola does not
  ship the library, so every program printed the error. A user environment
  generator now drops `LD_PRELOAD` entries whose file is missing before the
  session starts (from the next login).

### Changed (login screen, 2026-10-19)
- **The fingerprint reader listens as soon as the login screen is up.**
  The greeter used to start the login only on Enter, so the reader waited
  for an Enter first, and a password typed before it waited for the reader
  to give up. Now
  the login starts when a user is selected: touch the reader and you are
  in (the keyring opens too). Without a reader or an enrolled finger the
  password works as before; a password typed while the reader waits is
  kept and used when the reader gives up (30 s); after a wrong password
  the reader listens again. A Noctalia Greeter patch,
  `[auth] start_on_select` in `greeter.toml`.
- **A minimal login screen, like the website.** A plain `#121212`
  background and no boxes: the card, the password field and the session
  menu take the background's colour, so only the text shows, in
  JetBrains Mono and the site's ivory. The firefly is the account picture,
  in place of the generic person icon: every account without a picture gets
  it at boot (`lucciola-default-avatar.service`), and a picture you choose
  in the settings replaces it. The logo at the bottom is gone, and the
  password field's cursor is no longer yellow but the text's colour (a
  Noctalia Greeter patch). The blurred login wallpaper of the previous look
  is no longer in the image.
- **No more "Password:" under the password field.** The field already says
  "Type password", so PAM's plain password prompt is no longer repeated on
  the line below. Other questions, like a verification code, and the
  fingerprint's messages still show there. A Noctalia Greeter patch.

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
    still layers the VS Code RPM). An install that had them lost them at
    the next boot until the 2026-10-20 fix ("Apps that left the default set
    were uninstalled"); from that fix on, an install that has them keeps
    them.
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
    (an install that has them keeps them, reliably only since the
    2026-10-20 fix: before it, Flatpak uninstalled them wherever its
    preinstall record listed them);
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
