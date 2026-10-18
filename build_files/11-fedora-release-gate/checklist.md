# Fedora release checklist

The base image tag floats, so a new Fedora arrives on its own. The build
step `11-fedora-release-gate` refuses to build until `expected-release`
matches the base; go through this list first, then bump the number.

## Secrets and login (Fedora 45: gnome-keyring is replaced by oo7)

- Fedora 45 makes **oo7** the Secret Service (`oo7-daemon`, `pam_oo7`,
  `oo7-portal`). GDM's PAM files moved to `/usr/lib/pam.d` and carry
  `pam_oo7`: a password login unlocks the Login keyring.
- oo7 ships no D-Bus activation file; only GNOME's
  `gnome-session-services.target` starts it. Margine ships
  `org.freedesktop.secrets.service` and Lucciola starts it with niri
  (`niri.service.d/50-lucciola-secrets.conf`). Without them a niri session
  has no Secret Service at all.
- oo7 migrates gnome-keyring's encrypted keyring with the login password,
  but not the plaintext one `lucciola-keyring blank` left on Fedora 44: with
  the password at hand oo7-daemon exits on it ("File header doesn't
  match"), without it oo7 starts an empty Login keyring.
  `keyring-legacy-aside` (ExecStartPre of oo7-daemon) renames the file,
  `keyring-import-legacy` moves its items over (at login, or
  `ujust lucciola-keyring import`). Only for oo7 0.7.0~beta: upstream
  migrates the plaintext format itself since #579 (2026-09-26), so the
  aside step stands down on any other version. Rehearsed in a `silverblue-main:45`
  container with a real oo7-daemon: text, network and binary items, lookup
  by attribute and by schema, persistence across a daemon restart.
- `lucciola-keyring` no longer blanks the keyring (oo7 refuses an empty
  password): `tpm` stores the keyring password as a user credential that
  oo7-daemon imports at start (`ImportCredential=oo7.keyring-encryption-password`).
  To test in a VM with a TPM: fingerprint-like login (autologin) opens the
  keyring; a wrong credential shows in `status`.
- **tpm-keyring-unlock** (development laptop since 2026-10) rewrote
  `/etc/pam.d/gdm-{password,fingerprint,autologin,switchable-auth}`. Those
  copies keep shadowing GDM's new `/usr/lib/pam.d` files after the update:
  run `tpm-keyring-unlock-deconfigure` before rebasing, then
  `ujust lucciola-keyring tpm`.
- Back up `~/.local/share/keyrings` before testing: oo7's migration of a
  legacy login keyring has failed in reports (linux-credentials/oo7#577).

## Release-pinned names in this tree

- `Containerfile`: `NOCTALIA_VR` carries no Fedora tag (lucciola/build.sh
  adds the base's); check that the new release ships the same
  version-release and test-boot Lucciola. On 2026-10-17 the pin is 5.3.0-1,
  and Fedora 45, still a pre-release, had 5.2.1-1 in its release
  repository and 5.3.0-1 only in updates-testing (FEDORA-2026-04f44a27d9).
  A pre-release enables updates-testing by default, a released Fedora does
  not: once 45 is out, the pin resolves there only after that update is
  stable.
- Login screen (greetd + Noctalia Greeter, lucciola/build.sh step 5): the
  greeter RPM is built from `NOCTALIA_GREETER_VERSION` against the new
  release's libraries; it needs `wlroots-0.20` (a release that moves to
  another wlroots needs a greeter tag that supports it). Compare the new
  `/usr/lib/pam.d/greetd` and `/usr/lib/pam.d/gdm-password` (build.sh 5c
  fails on a changed layout), and boot to the greeter: password login,
  GNOME from the session list, autologin.
- `build_files/40-spec-scripts/scripts/validate-baseline-packages`:
  `quay.io/fedora/fedora:44`.
- `build_files/40-spec-scripts/declarations/margine-atomic.yaml`: the
  toolbox image `fedora-toolbox:44` and the "validated against fedora:44"
  notes.

## Kernel, drivers, repositories

- CachyOS kernel COPRs for the new release (custom-kernel/install.sh), the
  `scx-scheds` addons COPR, and the MOK-signed kernel build.
- Fedora 45 on 2026-10-16: kernel-cachyos 7.2.11, scx-scheds,
  ublue-os/packages, Docker CE, negativo17 multimedia and RPM Fusion all
  have fc45 builds.
- RPM Fusion, Docker CE, VS Code, Tailscale repositories: release-specific
  URLs resolve.
- ROCm: `rocm-opencl` still builds darktable's kernels
  (`ujust lucciola-darktable-opencl status`), and whether Mesa's rusticl works
  again (then the ROCm shim could go).

## Desktop and apps

- GNOME major version: GNOME is Lucciola's stock fallback session, with
  no extension, Shell default or keybinding of Margine's to port (they
  left the image on 2026-10-18). Check that the zz1 override in
  30-gnome-defaults still compiles against the new schemas
  (glib-compile-schemas in the build log) and that GNOME starts from the
  session list.
- Flatpak: the GL runtime branch the preinstalled apps use, and the
  `org.gnome.Platform` versions.
- `validate-margine-system`, smoke-boot and the install gate pass on the
  new release; `ujust lucciola-update` from the previous release works
  (gaming layer included, see the update-path gate).

## Last

- Site and docs version strings, CHANGELOG entry.
- Set `build_files/11-fedora-release-gate/expected-release`.
