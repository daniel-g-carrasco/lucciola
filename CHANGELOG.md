# Changelog

All notable changes to the Lucciola bootc image build are recorded here.
Image tags follow `stable`, `stable.YYYYMMDD`, `YYYYMMDD`.
Semantic versioning (`v0.X.Y`) will start once the first user-facing
stable release is cut.

## [Unreleased]

### Fixed (2026-10-18)
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
