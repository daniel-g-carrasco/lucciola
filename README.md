<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="lucciola/assets/lucciola-wordmark.svg">
    <source media="(prefers-color-scheme: light)" srcset="lucciola/assets/lucciola-wordmark-light.svg">
    <img src="lucciola/assets/lucciola-wordmark-light.svg" alt="Lucciola" width="320">
  </picture>
</p>

<p align="center">A rock-solid, ready-to-use PC operating system built on Fedora Atomic.</p>

Lucciola builds on Fedora Silverblue and adds a desktop made of niri and Noctalia, the speed-tuned CachyOS kernel and a set of everyday and creative apps. Lucciola is Italian for firefly.

- **Your workspace.** niri places windows in columns on a strip wider than the screen. Noctalia draws the bar, the launcher, notifications and the lock screen. GNOME ships too, as a backup session on the login screen.
- **Updates.** The whole system ships as one signed image. Updates download in the background and apply at your next restart; if one goes wrong, choose the previous version in the boot menu.
- **Foundations.** The CachyOS kernel is signed with Lucciola's own key, so Secure Boot keeps working. The TPM can unlock the encrypted disk at boot, and your device checks every update's signature before installing it.
- **Day one.** Zen Browser, Thunderbird, LibreOffice, GIMP, Inkscape, darktable and OBS Studio come installed, and Bazaar installs more from Flathub.

Lucciola is experimental, and I maintain it alone.

## Install

You need a 64-bit x86 processor with x86-64-v3 support (most made since about 2015) and AMD or Intel graphics. There is no installer image yet: you switch to Lucciola from a Fedora Atomic system such as Silverblue, Kinoite or Bluefin.

If Secure Boot is on, turn it off first (`systemctl reboot --firmware-setup`). Then run:

```sh
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/daniel-g-carrasco/lucciola:stable
systemctl reboot
```

This first download is unverified because a stock Fedora system has no signature policy for Lucciola yet. The policy comes with the image, and at the first boot Lucciola moves itself to the signed transport, so every update after that is checked.

The guide in [`site/`](site/index.html) walks through every step, including how to register Lucciola's key and turn Secure Boot back on.

No x86-64-v3, or a CachyOS kernel update misbehaving on your PC? `ghcr.io/daniel-g-carrasco/lucciola:fedora-kernel` is the same system with Fedora's own kernel, and `ujust lucciola-kernel fedora` switches an installed system to it.

## More

- [`lucciola/README.md`](lucciola/README.md): how the desktop layer is put together, and how to build the image.
- [`SECURITY.md`](SECURITY.md): reporting a vulnerability, and verifying the image signature.
- [`CHANGELOG.md`](CHANGELOG.md): what changed.

Lucciola grew out of Margine OS, my earlier GNOME image. Its documents are kept in [`docs/history/margine/`](docs/history/margine/README.md).

With thanks to [Fedora](https://fedoraproject.org/), [Universal Blue](https://universal-blue.org/), [niri](https://github.com/YaLTeR/niri), [Noctalia](https://github.com/noctalia-dev/noctalia), [Noctalia Greeter](https://github.com/noctalia-dev/noctalia-greeter), [greetd](https://git.sr.ht/~kennylevinsen/greetd) and [CachyOS](https://cachyos.org/); to [Bluefin](https://projectbluefin.io/), Margine's first base and the source of many ideas; to [Origami Linux](https://gitlab.com/origami-linux/images) for the kernel signing script, [MorrOS](https://github.com/morrolinux/morros) for CI patterns, and [coreos/chunkah](https://github.com/coreos/chunkah) for content-based image layers.

Apache-2.0.
