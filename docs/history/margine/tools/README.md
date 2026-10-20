# Margine's ISO and benchmark tooling (archived)

Moved here on 2026-10-20 from `live-env/`, `tools/iso-builder/` and
`tools/bench/`. They are Margine's developer tools, kept for reference:

- [`../live-env/`](../live-env/): the Titanoboa live image Margine's ISO was
  built from (Anaconda profile and kickstarts, the Flatpak bake, the GRUB
  menu), with `build-iso-local.sh` for local builds. It builds from
  `ghcr.io/daniel-g-carrasco/margine:stable`, not from Lucciola.
- [`iso-builder/`](iso-builder/): the GTK window that drove those local
  builds and dispatched `build-disk.yml`, a workflow this repository does
  not have.
- [`bench/`](bench/): the kernel, gaming and HiDPI benchmark scripts written
  for Margine on Bluefin DX.

Lucciola has no ISO: installs move to it with a rebase first, and an ISO
comes later. Until then nothing here is run, linted or updated, and the
`just build-iso`, `build-iso-fast`, `test-install-vm`, `iso-gui` and
`install-desktop` recipes are gone. When the ISO comes, start from
`live-env/` and port it (names, image reference, branding) rather than
running it as it is.

Still in use, and not part of this archive: `installer/flatpaks-base`, the
Flatpak list the image build reads (`Containerfile`, `build_files/20-flatpaks`).
The ISO bake kept a copy of it in `live-env/src/flatpaks`; the two are no
longer checked against each other.
