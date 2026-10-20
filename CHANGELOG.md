# Changelog

All notable changes to the Lucciola bootc image build are recorded here.
Image tags follow `stable`, `stable.YYYYMMDD`, `YYYYMMDD`.
Semantic versioning (`v0.X.Y`) will start once the first user-facing
stable release is cut.

## [Unreleased]

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
