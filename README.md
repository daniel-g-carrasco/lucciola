# Lucciola

A rock-solid, ready-to-use PC operating system built on Fedora Atomic.

Lucciola builds on Fedora Silverblue and Universal Blue, and adds a desktop made of niri and Noctalia, the CachyOS kernel and a set of everyday and creative apps. You install it as your system; the whole system ships as one signed image and updates as a whole.

> Lucciola is experimental, and I maintain it alone. This repository is its new home, and its first image is not published yet. Until it is, Lucciola ships from the Margine repository as `ghcr.io/daniel-g-carrasco/margine:lucciola`; installs that follow it will move to the new image by themselves.

## What you get

- niri places windows in columns on a strip wider than the screen; Noctalia draws the bar, the dock, the launcher, notifications and the lock screen. The login screen is Noctalia Greeter, with the same look, and GNOME stays there as a backup session.
- The CachyOS kernel, signed with the project's own key, so Secure Boot stays on. The TPM can unlock the encrypted disk at boot.
- Updates download in the background and apply at the next restart. The previous version stays in the boot menu, and your device checks every image's signature before installing it.
- Zen Browser, Thunderbird, LibreOffice, GIMP, Inkscape, darktable and OBS Studio, with Bazaar to install more from Flathub. Common audio and video formats play out of the box. Distrobox and Toolbox run developer tools without changing the system.
- What only some people need comes with one command instead of sitting in every install: Steam and the other game launchers (`ujust lucciola-gaming`, or `ujust lucciola-gaming-native` for the native Steam), virtual machines with virt-manager (`ujust lucciola-vm`), and for developers VS Code, a C compiler and Homebrew (`ujust lucciola-devmode`).

## Requirements

A 64-bit x86 processor with x86-64-v3 support, which most made since about 2015 have. To check yours:

```sh
/lib64/ld-linux-x86-64.so.2 --help | grep x86-64-v3
```

A line that says "supported" means you are ready; no output means Lucciola will not start on that PC. AMD and Intel graphics work out of the box; there is no build with NVIDIA's own driver.

## Install

Lucciola has no installer image yet: you switch to it from a Fedora Atomic system such as Silverblue, Kinoite or Bluefin. On an empty disk, install Fedora Silverblue first.

1. If Secure Boot is on, turn it off for now (`systemctl reboot --firmware-setup`). The kernel is signed with Lucciola's key, which your PC does not know yet.
2. Switch, then restart:
   ```sh
   sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/daniel-g-carrasco/lucciola:stable
   systemctl reboot
   ```
   The first download is unverified on purpose: a stock Fedora system has no signature policy for Lucciola, and rpm-ostree refuses the signed transport under its default policy. The policy comes with the image, and at the first boot Lucciola moves itself to the signed transport, so every update after that is checked.
3. The login screen opens on Lucciola: enter your password. GNOME is in the session list too.
4. Restart once more. A blue screen asks you to register the key: press a key within 10 seconds, then choose Enroll MOK, Continue and Yes, type `margine` and choose Reboot. `ujust lucciola-secureboot enroll` makes that screen wait for you.
5. Turn Secure Boot back on when `ujust lucciola-secureboot` says the key is in place.

The commands begin with `lucciola-`: `ujust lucciola-update`, `ujust lucciola-status`, and `ujust --list` for the rest. Their old `margine-` names, from Margine OS, the project Lucciola grew from, still work.

## Verify the image signature

Every image is signed with [cosign](https://github.com/sigstore/cosign) by digest:

```sh
cosign verify \
  --key https://raw.githubusercontent.com/daniel-g-carrasco/lucciola/main/secrets/cosign.pub \
  ghcr.io/daniel-g-carrasco/lucciola:stable
```

A valid signature prints the verified payload and exits 0. The public key is [`secrets/cosign.pub`](secrets/cosign.pub); the private half only exists in CI.

## This repository

- `Containerfile` and `build_files/`: the build, as numbered steps on top of `ghcr.io/ublue-os/silverblue-main:45`.
- `lucciola/`: the desktop, with niri's and Noctalia's defaults and the session; `lucciola/assets/` holds the logo, the wallpaper and the boot splash ([`docs/BRANDING.md`](docs/BRANDING.md) maps where each appears).
- `.github/workflows/`: every change builds a candidate image, boots it in a virtual machine with Secure Boot and a TPM, and only then promotes it to `:stable`; another test updates a machine from the previous image to the new one.

To build locally you need a MOK key and certificate to sign the kernel with (an image signed with your own key starts with Secure Boot on only after you enroll that key):

```sh
podman build \
  --secret id=mok-key,src=MOK.key \
  --secret id=mok-cert,src=MOK.pem \
  -t localhost/lucciola .
```

Lucciola grew out of Margine OS, and this repository keeps Margine's history. Margine's changelog is in [`docs/margine/CHANGELOG.md`](docs/margine/CHANGELOG.md).

## Credits

- [Fedora](https://fedoraproject.org/), for Silverblue and the official niri and Noctalia packages.
- [Universal Blue](https://universal-blue.org/), for the `silverblue-main` base image, `uupd` and the automation patterns.
- [niri](https://github.com/YaLTeR/niri) and [Noctalia](https://github.com/noctalia-dev/noctalia), the desktop; [Noctalia Greeter](https://github.com/noctalia-dev/noctalia-greeter) and [greetd](https://git.sr.ht/~kennylevinsen/greetd), the login screen.
- [CachyOS](https://cachyos.org/), for the kernel.
- [Bluefin](https://projectbluefin.io/), Margine's base for its first months and the source of many ideas.
- [Origami Linux](https://gitlab.com/origami-linux/images), the reference for the kernel signing script; [MorrOS](https://github.com/morrolinux/morros), for CI patterns; [coreos/chunkah](https://github.com/coreos/chunkah), for content-based image layers.

## License

Apache-2.0.
