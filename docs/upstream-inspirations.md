# Upstream Inspirations and Code Derivations

> I wrote this file for Margine OS, the image Lucciola grew from, and it
> still applies: Lucciola inherits the same upstreams, the same kernel
> signing script and the same build pattern. Where it says Margine, read
> Lucciola. It stays maintained because `check-upstreams.yml` reads the
> "Last reviewed" dates in its table every month. Older design documents
> are in [`history/margine/`](history/margine/README.md).

Margine is not built from scratch. It builds on top of several upstream
projects, in different ways. This document distinguishes those ways
honestly — there's a difference between *being inspired by an architectural
pattern* and *copying a script wholesale* — and records both for
attribution and for the practical purpose of knowing **what to re-check
when upstream changes**.

It also defines a review cadence (with a script) so this doc doesn't
go stale silently.

## Summary table

| Upstream | Role for Margine | Derivation level | Files / patterns of ours | Last reviewed |
| --- | --- | --- | --- | --- |
| [Universal Blue main](https://github.com/ublue-os/main) (`silverblue-main`) | The `FROM` base of every Margine image since 2026-10-11 ([Bluefin DX](https://github.com/ublue-os/bluefin) from May to October 2026); we ship as their image + our delta | **Infrastructure** (we build on top, not from) | the entire image stack inherits; `zz1-margine.gschema.override` is a layered companion to their `zz0-bluefin-modifications.gschema.override` | 2026-11-10 |
| [Origami Linux](https://gitlab.com/origami-linux/images) | Custom-kernel signing pipeline (CachyOS via COPR + MOK signing + first-boot enrollment) | **Direct code derivation** | `margine-image/build_files/custom-kernel/install.sh` | 2026-11-10 |
| [MorrOS](https://github.com/morrolinux/morros) (by Morrolinux) | The "personal distro = fork the Universal Blue image-template + small delta" pattern; pragmatic Italian-community example | **Architectural inspiration** | overall repo shape (margine-image fork of `ublue-os/image-template`, `build_files/build.sh` as the single delta script) | 2026-11-10 |
| [Universal Blue image-template](https://github.com/ublue-os/image-template) | The starting scaffold for `margine-image` (Containerfile + GH Actions structure) | **Initial fork** | `margine-image/Containerfile`, `margine-image/.github/workflows/build.yml` (heavily modified since) | 2026-11-10 |
| [hhd-dev/rechunk](https://github.com/hhd-dev/rechunk) | Post-build re-commit of the OCI image into ostree-canonical form; the GH Action we used until the chunker switch (rpm-ostree, then chunkah on 2026-08-31). Declared end of life and archived on 2026-10-13; its README now points everyone else to chunkah | **Former GH Action consumer** (off the watch list since 2026-11-10: an archived repository cannot move) | none since 2026-08; history in the "Chunker" note below | 2026-11-10 |
| [Bazzite](https://github.com/ublue-os/bazzite) | Reference for the *opt-in* gaming layer (their package set + tool choices), not a base | **Reference only** (no code copied) | `60-custom.just` recipe `margine-gaming` (curated subset of Bazzite's bake) | 2026-11-10 |
| [coreos/chunkah](https://github.com/coreos/chunkah) | The chunker behind every `:stable` and `:lts` image since 2026-08-31: content-based layers planned from the rpmdb, no `--previous-build` needed | **Tool consumer** (pinned by tag and digest: v0.6.0, v0.7.0 from #441, v0.7.1 since 2026-10) | step `Chunk the image` in `build.yml` / `build-lts.yml`; `99-cleanup.sh` mtime normalisation (works around chunkah#160) | 2026-11-10 |
| [RakuOS](https://gitlab.com/rakuos) (canonical on GitLab; the GitHub org is a stale mirror) | Closest cousin: Fedora bootc minimal (was `base-atomic` until 2026-09-13; on Fedora 45 since 2026-11-03) + CachyOS kernel + MOK-signed modules + chunkah at build time + persistent dnf overlay ("hybrid atomic"); GNOME/KDE/COSMIC/Niri editions, x86-64-v3/v4 builds | **Reference only** (no code copied) | none; watched for how they handle Secure Boot, the v3/v4 split (our #382) and the overlay model | 2026-11-10 |

---

## RakuOS — reference only

[RakuOS](https://rakuos.org/) is a "hybrid atomic" Fedora distribution
built on `quay.io/bootc-devel/fedora-bootc-<version>-minimal` (until
2026-09-13 on `quay.io/fedora-ostree-desktops/base-atomic`; rpm-ostree is
no longer in their images since that switch), with the CachyOS
kernel, DKMS modules signed at build time with a MOK key passed as a
build secret (`build_files/drivers.sh`), chunkah run inside the
Containerfile (`FROM quay.io/coreos/chunkah AS chunkah`, then
`FROM oci-archive:out.ociarchive`), and a persistent overlay that lets
users `dnf install` on top of the image and keeps those packages across
updates (`rakuos-overlay-sync.service`, `rakuos reset-overlay`). Four
desktop editions (GNOME, KDE, COSMIC, Niri), a Gamescope image, and
separate x86-64-v3 / v4 Containerfiles. Sources live on GitLab under
`rakuos/images/*` and `rakuos/packages/*` (Apache-2.0); the GitHub org
`RakuOS/*` is a mirror that stopped in 2026-07.

Why we watch it (added 2026-09-01): it makes the same
three choices Margine made (CachyOS kernel, MOK signing, chunkah) in a
different order and with a different philosophy on mutability. Things to
learn from their commit log: how they ship the v3/v4 split (our #382
went the other way, an `:lts` variant), whether the build-time chunkah
flow keeps `containers.bootc=1` and the ostree labels straight, and how
the dnf overlay survives `bootc upgrade`. Nothing copied; no derivation.

## Origami Linux — direct code derivation

**License:** GPLv3 (Origami's repo). Our `custom-kernel/install.sh` is
released under Apache-2.0 per Margine's overall license; the GPLv3
content was adapted and re-licensed under fair-use derivation (this
note exists in case someone audits — if there's a license conflict it
should be flagged).

### Files

- **Source**: [`modules/custom-kernel/custom-kernel.sh`](https://gitlab.com/origami-linux/images/-/blob/main/modules/custom-kernel/custom-kernel.sh)
  in `origami-linux/images`
- **Mirror** (sometimes more up-to-date): [`john-holt4/Origami-Linux` modules/custom-kernel](https://github.com/john-holt4/Origami-Linux/blob/main/modules/custom-kernel/custom-kernel.sh)
- **Ours**: [`build_files/custom-kernel/install.sh`](https://github.com/daniel-g-carrasco/margine-image/blob/main/build_files/custom-kernel/install.sh)

### What we kept

- CachyOS kernel install pattern: enable `bieszczaders/kernel-cachyos`
  COPR, remove stock Fedora kernel packages, install
  `kernel-cachyos`/`-core`/`-modules`/`-devel-matched`
- MOK signing flow:
  - `sbsign` (sbsigntools) for vmlinuz
  - `sign-file` (kernel build helper) for each `.ko`/`.ko.xz`/
    `.ko.zst`/`.ko.gz` under `/usr/lib/modules/<KVER>`
  - DER export of the cert to `/usr/share/cert/MOK.der`
  - First-boot `mok-enroll.service` (oneshot) that pipes the MOK
    password twice into `mokutil --import`, marked done via
    `/var/.mok-enrolled`
- Disable/restore of `/usr/lib/kernel/install.d/05-rpmostree.install`
  and `50-dracut.install` hooks during the kernel transition
- akmodsbuild patching to allow akmods (e.g. v4l2loopback) inside
  BuildKit container builds

### What we changed (Margine-specific)

- **Single kernel variant only.** Origami supports kernel-cachyos
  mainline / LTS / RT / LTO via a `KERNEL_VARIANT` env. We dropped all
  but mainline.
- **No NVIDIA codepath.** Origami has substantial NVIDIA detection +
  driver signing logic. Margine targets Framework 13 AMD 7640U +
  Intel-iGPU laptops; we deleted the NVIDIA branches.
- **v4l2loopback as best-effort, not blocking.** Origami fails the
  build if v4l2loopback can't build. We mark it `V4L2_OK=0` and
  continue, logging the failure — the akmodsbuild patch is unreliable
  in some BuildKit cache configurations and we'd rather ship an image
  without `vboxvideo` than not ship at all.
- **Stronger preflight validation.** We `openssl pkey ... -pubout` +
  `openssl x509 ... -pubkey -noout` and `cmp -s` to ensure the MOK
  private key and certificate actually match before doing anything.
- **`dracut --no-hostonly --no-hostonly-cmdline --regenerate-all`** —
  see [lessons-learned/2026-05-28-initramfs-and-bootc-labels.md](history/margine/spec/lessons-learned/2026-05-28-initramfs-and-bootc-labels.md).

The header comment of our `install.sh` credits Origami inline.

---

## MorrOS — architectural inspiration

**License:** N/A (we copy no code). [Morrolinux](https://www.morrolinux.it/)
is a long-running figure in the Italian Linux community (educational
YouTube channel `morrolinux`, books, articles). His project
[MorrOS](https://github.com/morrolinux/morros) is one of the cleanest
demonstrations that a single person can fork
`ublue-os/image-template`, add their own desktop opinions (KDE
flavour, branding, package set, services), and end up with a
fully-functional personal Universal-Blue-style image without taking
on the maintenance burden of a full distro.

We follow the same recipe in `margine-image`:

| MorrOS pattern | Margine implementation |
| --- | --- |
| `Containerfile` based on `FROM ghcr.io/ublue-os/<base>:<tag>` + `RUN /ctx/build.sh` | Identical structure, with `silverblue-main:44` as the base (`bluefin-dx:stable` until 2026-10-11) |
| Single `build_files/build.sh` script doing all delta work (preinstall flatpaks, gschema overrides, configure user-state helpers) | Same pattern; our `build.sh` is structured into numbered sections (`0. OS identity`, `1. Flatpaks`, `2. GNOME defaults`, `3. configure-* helpers`, `4. visual branding`, `5. ujust recipes`) |
| GH Actions workflow forked from the image-template, customised for cosign signing + nightly + PR builds | Same shape; we added Layer A image-internals inspection and (now) rechunk |
| Honest scope (personal distro, not a "Linux for everyone" project) | Margine is explicitly a personal Fedora Atomic workstation — see `docs/00-goals.md` |

We did **not** copy MorrOS code. The architectural inspiration is
acknowledged because it's intellectually honest and because his
example was what convinced us this approach is viable for a single
maintainer.

---

## Universal Blue image-template — initial fork

**License:** Apache-2.0.

[`ublue-os/image-template`](https://github.com/ublue-os/image-template)
is the reference starting scaffold every Universal Blue downstream
forks. We forked it in May 2026 and customised heavily. The original
files have been replaced/extended substantially, but the bones are
theirs:

- `Containerfile` — multi-stage with BuildKit secret mounts for MOK
  signing
- `.github/workflows/build.yml` — buildah-build + cosign sign + push
  to GHCR

---

## The base: Universal Blue main, and Bluefin DX before it

**License:** Apache-2.0. **Role:** Margine is not just inspired by
Universal Blue, Margine IS one of their images + our delta: `silverblue-main`
since 2026-10-11 (ADR 0010), Bluefin DX from May to October 2026 (ADR 0005).
Every Margine boot runs the base's package set + our additions/swaps; what
Bluefin DX added on top of main is now either a `ujust` recipe or a Margine
build step. The patterns below came from Bluefin and still apply.

Specific patterns we follow:

- `zz0-bluefin-modifications.gschema.override` is Bluefin's gschema
  baseline. Our `zz1-margine.gschema.override` loads after (glib reads
  override files in lexical order) so we can change only the keys we
  want and inherit the rest.
- `/etc/ublue-os/system-flatpaks.list` — Bluefin's mechanism for
  reconciling system-wide Flatpak installs at first boot. We append
  our Margine defaults to it instead of inventing a new system.
- `/usr/share/ublue-os/just/*.just` — Bluefin's mechanism for
  contributing `ujust` recipes. Our `60-custom.just` is dropped
  there.
- `uupd.timer`, Universal Blue's update orchestrator. Margine runs it
  unchanged, installing uupd from the `ublue-os/packages` COPR when the
  base lacks it (we explicitly do NOT ship our own, see ADR 0005 and the
  superseded `scripts/update-all` in margine-fedora-atomic).

Universal Blue rebuilds main daily. Each base update is a potential
behaviour shift for us, see the review cadence below.

---

## hhd-dev/rechunk — post-build OCI re-commit

> Archived upstream on 2026-10-13 (deprecated, folded into
> `anatase-org/ludos`). We left it for chunkah on 2026-08-31; this section
> is history.

**License:** Apache-2.0. **Role:** action invoked as the second-to-last
step of our `.github/workflows/build.yml`. Without it, our image's
labels (ostree.linux, ostree.commit, ostree.bootable) are stale from
Bluefin's commit, and composefs isn't set up correctly for our
modifications. See `docs/history/margine/spec/lessons-learned/2026-05-28-initramfs-and-bootc-labels.md`
for the full story.

Bluefin uses rechunk via a custom `just rechunk` recipe (3 separate
podman invocations); we use the simpler `hhd-dev/rechunk@v1.2.4` GH
Action wrapper.

---

## Bazzite — gaming layer reference

**License:** Apache-2.0. **Role:** comparison target only. Margine's
opt-in `ujust margine-gaming` ships a **curated subset** of what
Bazzite bakes into their image (Steam + Lutris + Heroic + Bottles +
Protontricks + ProtonPlus as Flatpaks; gamescope + mangohud +
vkBasalt + gamemode + goverlay + steam-devices as rpm-ostree layers).

We chose a subset because:
- We have the CachyOS kernel, so `scx-scheds` (Bazzite's scheduler) is
  redundant
- `umu-launcher` has complex packaging; Lutris/Protontricks cover most
  of the same ground
- We don't ship Deck/KDE-specific Bazzite bits — Margine is GNOME

Bazzite REMOVES `gamemode` in their image (`dnf5 -y remove gamemode`
in their Containerfile). We KEEP gamemode because without
`scx-scheds`, GameMode is the actual CPU-governor mechanism that helps.

---

## Review cadence and `check-upstreams` script

Each upstream listed above is expected to be re-reviewed when:

1. **3 months pass without a check**, OR
2. **a Margine build starts failing in a way that smells like an
   upstream behaviour change** (e.g. dracut output path moved, OCI
   label semantics changed, rechunk arguments deprecated), OR
3. **a Fedora release bump of the base occurs** (currently Fedora 45; the
   next will be Fedora 46).

To check whether any upstream has new commits since the last
recorded review date, run this script. It updates the *Last reviewed*
column in this file with today's date for projects that have moved.

```sh
#!/usr/bin/env bash
# scripts/check-upstreams.sh — print upstream activity since each repo's
# "Last reviewed" date in docs/upstream-inspirations.md.
#
# Requires: gh CLI authenticated, jq.

set -euo pipefail
DOC="docs/upstream-inspirations.md"

declare -A repos=(
  [main]="ublue-os/main"
  [bluefin]="ublue-os/bluefin"
  [origami]="john-holt4/Origami-Linux"   # mirror; original is on GitLab
  [morros]="morrolinux/morros"
  [image-template]="ublue-os/image-template"
  [bazzite]="ublue-os/bazzite"
)

# Only the table's last column counts: any other date in this file is
# history, not a review.
LAST_REVIEWED=$(grep -oE '\| 202[0-9]-[0-9]{2}-[0-9]{2} \|$' "$DOC" | grep -oE '202[0-9]-[0-9]{2}-[0-9]{2}' | sort -u | tail -1)
echo "Most recent 'Last reviewed' in $DOC: $LAST_REVIEWED"
echo

for name in "${!repos[@]}"; do
  repo="${repos[$name]}"
  commits=$(gh api -X GET "/repos/${repo}/commits" \
                   -f since="${LAST_REVIEWED}T00:00:00Z" \
                   --jq 'length' 2>/dev/null || echo "?")
  echo "  $name ($repo): $commits new commit(s) since $LAST_REVIEWED"
done

echo
echo "If any are non-zero, open the corresponding repo and skim the"
echo "commit log. If anything affects what's listed in"
echo "$DOC, update the 'Last reviewed' date in that table row."
```

The script above is the first sketch. The one that runs is
`build_files/40-spec-scripts/scripts/check-upstreams.sh`, with a longer
watch list (the kernels, chunkah, the sealed-images test repo, RakuOS on
GitLab); `check-upstreams.yml` runs it on the first of every month and
opens an issue when something moved.

---

## Review log

### 2026-11-10 (issue #70)

Window: 2026-10-03 to 2026-11-10. Everything moved except Origami (last
commit 2026-06-02 on GitLab, none on the mirror). Each point below was
checked against the repository or the reference laptop
(`lucciola.20261110`, kernel 7.3.3-1.cachyos1) where it says so. In order
of how much it matters to us:

- **The base (ublue-os/main, 135 commits, 9 that are not digest bumps).**
  - `ublue-os-udev-rules` left the Fedora 45 base on 2026-10-26 (#3032,
    #3033): controllers, Framework input modules, the Realtek dock
    network rule, U2F keys. Nothing changes for us:
    `15-devstack/install.sh` installs the package from the COPR when the
    base lacks it and checks that it landed (0.10-1 on the laptop).
  - Two units run at every boot since #3029: `bootc-update-ca-trust.service`
    and `bootc-update-crypto-policies.service`. They exist because the
    three-way merge of `/etc` can keep a stale trust store after a CA is
    withdrawn. They are the two units of our baseline drift issue #59.
    Cost on the laptop: 1.3 s and 0.2 s. Upstream is already discussing
    removing them again (#3076), so the baseline should accept them
    without depending on their names.
  - `latest` is Fedora 45 since 2026-11-08, `gts` is 44. We pin `:45`.
  - The `*-nvidia` images are retired (#3075). An NVIDIA variant, if it
    ever comes, starts from the akmods image, whose kernel is not ours.
  - Not merged yet: the 2023 kernel signing certificate is being retired
    (#3085), which does not touch our MOK; and SELinux still denies
    `ssh -L` forwarding on some images (#2845). The second is to try
    through Remote Login.
- **Fedora 45 traps, as the cousins met them.** RakuOS moved to Fedora 45
  on 2026-11-03, MorrOS and Bazzite in October.
  - oo7 has no D-Bus activation, so its service must be enabled for every
    user: RakuOS and MorrOS found it independently, we have it since the
    migration.
  - **`pam_oo7` is missing where a password is changed from a terminal.**
    Fedora's `/etc/pam.d/passwd` and `chpasswd` name only
    `pam_gnome_keyring`, which the image does not ship; greetd's stack,
    which is ours, has `pam_oo7`. So after `passwd` the Login keyring
    stays on the old password and no longer opens at login (RakuOS
    15944ef8). Read on the laptop, not yet reproduced. Follow-up 1.
  - `ca-certificates` no longer ships `/etc/pki/tls/certs/ca-bundle.crt`
    or `/etc/pki/tls/cert.pem`. Nothing in this repository names them.
  - The distro `.repo` files are in `/usr/share/dnf5/repos.d`; our
    scripts already look there.
  - `bootupd`'s `EFI.json` describes the shim and GRUB of the base, and
    goes stale if a build updates them. Ours matches what is installed
    (grub2 2.12-83, shim 16.1-7).
  - Consoles on tty2 to tty6 are `kmsconvt@` now; `autovt@` is its alias.
- **Kernel: 7.2 to 7.3** (7.3.3 in the COPR since 2026-11-08).
  - The RPM release changed form on 2026-10-23 (`7.3.0-4.cachyos1`
    instead of `7.3.0-cachyos2`). The package removal guard stopped main
    that day and was taught the new form.
  - 7.3 carries AMD's "PerfOpt" patches, which let an integrated GPU skip
    the IOMMU's address translation. On the laptop it is armed
    (`AMD-Vi: PerfOpt armed on IOMMU0`), with the GPU and the NPU in the
    identity domain and the other 36 groups in translated ones. Mainline
    already puts devices of that kind in the identity domain
    (`amd_iommu_def_domain_type()` in 7.2, untrusted devices excepted), so
    what an external device can reach does not change; the switch, should
    it ever be needed, is `amdgpu.iommu_perfopt=0`.
  - 7.3.3 changes the xHCI handoff for every controller. One suspend and
    resume on the laptop since, no USB error.
  - BORE went to 7.0.0 with no commit in the spec to mark it, and
    scx-scheds to 1.1.4. Nothing in the config touches module signing,
    lockdown, hibernation or sched_ext.
- **Our image carries two RPM databases, one of them stale.** Bazzite
  links `/usr/lib/sysimage/rpm-ostree-base-db` to `/usr/share/rpm` at the
  end of its build (#6142). In our image the first is still the base's
  database: 78.8 MB, 1510 packages, no `kernel-cachyos`, no `niri`, next
  to the real one of 87.7 MB. Bazzite's commit says rpm-ostree then
  refuses to layer a package the image removed from its base, and that
  one database instead of two saves about 30 MiB per update. Follow-up 2,
  to be measured with `layer-delta.py`.
- **Our user units also start for the greeter.** Bazzite found its user
  services running inside the login screen's session (#6294). Same here:
  the journal shows `lucciola-app-colors-flatpak.service`,
  `margine-staged-update-notify.service` and the brew, Flatpak, staleness
  and Ollama timers started for greetd's user. Harmless today, but a
  machine left at the login screen runs a Flatpak update as that user.
  greetd's user is a static system user, so `ConditionUser=!@system` is
  enough. Follow-up 3.
- **Easy Anti-Cheat v2.** Bazzite added a readiness check (#6065). By its
  reading of Epic's requirements, the kernel must be signed by a
  "well-known" key (Fedora, Universal Blue, Microsoft, Canonical and a
  few more), with no other MOK enrolled. A CachyOS kernel signed with our
  MOK does not qualify. I read Bazzite's script, not Epic's policy. If it
  holds, it is the first concrete argument for the `:fedora-kernel` image
  beyond being a reserve.
- **chunkah**: nothing since v0.7.1, which we pin. coreos/chunkah#189
  (packages that carry only RPM 6's 64-bit size tags get size zero) does
  not touch us today: none of the laptop's 2283 packages lacks `SIZE`.
  Bazzite moved from rechunk to chunkah on 2026-10-14 and met the same
  mtime problems we did, in the same order. Two things of theirs are
  worth keeping in mind: they verify chunkah's own signature before
  running it, and they mark their own files with `user.component` and
  `user.update-interval` so they land in stable layers. **rechunk** was
  declared end of life and archived on 2026-10-13: off the watch list.
- **Already ours**: a reproducible initramfs (`00-common.sh`; `--zstd` is
  now the Fedora 45 default), `skip_if_unavailable=False` on our repo
  files, the SELinux `subs_dist` line (#439).
- **To measure, not to copy**: Bazzite's power-saver profile now forces
  the AMD GPU to its low level, around a tuned bug (#6214). Lucciola runs
  tuned too and the level stays `auto`. Worth one measurement on battery.
- **image-template**: documentation for the NVIDIA change and action
  bumps. **MorrOS**: oo7 as above, OpenSnitch checked against the release
  API's digest. **OGC kernel**: one commit (CEC for the Steam Machine).
  **Sealed images**: a runner bump.

The checker changed with this review. `ublue-os/main` was missing from
its list since the base switch, rechunk leaves it, and it counts 100
commits per upstream instead of 30. It also read the newest date anywhere
in this file as the last review: in November that was 2026-10-11, the day
of the base switch, named in a table cell. It now reads the table's last
column only.

No change was required in the derivations this document records. Three
follow-ups for the image: `pam_oo7` in the password stack of `passwd` and
`chpasswd`; one RPM database instead of two; our user units kept out of
the greeter's session.

### 2026-10-03 (issue #437)

Nine upstreams had new commits since 2026-09-01; Origami, rechunk and the
sealed-images repo had none. In order of how much it matters to us:

- **Inherited SELinux bug in bluefin-dx, fixed on our side (#439).** The
  dx package layer pulls a newer `selinux-policy-targeted`, whose RPM
  restores the stock `/var/home /home` line in `file_contexts.subs_dist`
  and undoes rpm-ostree's compose fix (ublue-os/bluefin#4976, upstream
  fix pending in #4979). Confirmed on our image: `matchpathcon ~/.ssh`
  returned `default_t`, so the first `restorecon` on a home breaks SSH
  key login. `99-cleanup.sh` now reapplies the rpm-ostree edit and the
  rootfs validator fails the build if the reversed line comes back.
- **chunkah v0.7.0 is out (2026-09-28); adopted after measuring (#441).** It
  contains coreos/chunkah#161, which clamps the ancestor directories of
  `bigfiles` and `xattr` layers: the problem the mtime normalisation in
  `99-cleanup.sh` works around. Our workaround stays correct with it. The
  release also changes the package stability scores (#143), which moves
  the layer plan, so the first build after the bump will share fewer
  layers with the previous one, so it was bumped on purpose and measured:
  an update from the v0.6.0 `:stable` to the v0.7.0 build of the same
  tree downloads 624 MiB, against 558 MiB for an ordinary v0.6.0 rebuild
  of the same tree (that baseline is its own problem, #442). A fix landed
  after the tag (d861f167,
  chunkah#176) matters only with `SOURCE_DATE_EPOCH`, which we do not
  pass. chunkah#160 is still open. Renovate did not see `CHUNKAH_REF`
  (a pinned env value in `build.yml` / `build-lts.yml`); #441 adds a
  regex manager for it, with automerge off.
- **Fedora 45 moves the distro `.repo` files** to `/usr/share/dnf5/repos.d`
  (ublue-os/bluefin#4962). Our scripts only create and delete our own
  repo files in `/etc/yum.repos.d`, which dnf5 still reads, so nothing
  changes for us; but Bluefin's dx build fails on F45 until that PR
  lands, which gates our own move to F45.
- **Bluefin** otherwise: digest bumps, the README now says "Bluefin
  Classic", and `bluefin-dx:stable` is still built (44.20260929).
  ublue-os/bluefin#4973 (`min-free-space-percent` on a 2 TB disk) is a
  98 % full disk, not the ostree accounting bug we fixed in #401.
- **RakuOS** moved from `base-atomic` to Fedora bootc minimal and dropped
  rpm-ostree from its images (their dnf shim replaces it), fixed
  `bootc container lint` findings (relative `/opt` and `/usr/local`
  symlinks, emptying `/run` and `/tmp` before the lint), and added an
  `org.rakuos.fedora.version` label so their software center can react
  to a Fedora major change. The base switch is the one to watch: it is
  the path a Margine without Bluefin would take.
- **OpenGamingCollective** builds USB storage, NVMe and VFAT into the
  kernel and enables the AMD XDNA driver. Our CachyOS kernel has all of
  them as modules, which is fine because the initramfs is built
  `--no-hostonly`; XDNA is loaded on the reference host (`/dev/accel0`).
- **Bazzite**: a `d3cold` rule for Intel AX200/AX210 (the reference
  hardware uses MediaTek MT7922), a hibernation helper for handhelds,
  `msedit` as default editor. Nothing for us.
- **image-template** moved `remove-unwanted-software` to the same commit
  we already pin (v10). **CachyOS** shipped 7.2.8 (what we run) and is at
  7.3-rc5. **MorrOS** added developer tools; the pattern we cite is
  unchanged.

No change was required in any of the derivations this document records.

### 2026-08-21 (issue #333)

Six upstreams had new commits since 2026-06-07; Origami and rechunk had
none. What the skim turned up, in order of how much it matters to us:

- **Chunker: chunkah is the default since 2026-08-31 (measured).** Same
  image, same base, two builds one day apart: `rpm-ostree compose
  build-chunked-oci` without `--previous-build` (blocked by
  bootc-dev/bootc#1885, two assertions reproduced on our image) shared
  84/128 layers, 4071 MiB of 6234 (65%); `coreos/chunkah` v0.6.0 shared
  106/127, 4764 MiB of 6377 (74%), about 600 MB less per daily update,
  and chunked in 3 min 14 s against 10 min 0 s. Price: 143 MiB larger
  image, and the first chunkah `:stable` shares nothing with the
  rpm-ostree ones (one full download, then the deltas). `rpm-ostree`
  stays one `workflow_dispatch` away (`chunker=rpm-ostree`), in
  `build.yml` and `build-lts.yml` alike, because `:lts` must be chunked
  like `:stable` or the two share no layers (#386).

- **The ecosystem is leaving `hhd-dev/rechunk` behind.** Bazzite now
  rechunks with `rpm-ostree compose build-chunked-oci`, passing labels
  as `--label` arguments (ublue-os/bazzite 625bebb, "fix(ci): Maintain
  labels through rootless rechunk"), and image-template moved to
  `chunkah`. We still consume the rechunk action at v1.2.4, whose own
  README describes itself as a stopgap until the ostree-rs-ext changes
  land upstream. Nothing is broken and there is no hurry, but the tool
  we depend on is now maintained for fewer and fewer consumers, and a
  migration should be a deliberate decision rather than a forced one.
- **Bazzite hit our label problem and solved it the same way.** Their
  commit above exists because rechunking drops labels, which is exactly
  the bug that left `base.digest` missing and the /status page unable to
  say whether Margine was built on the current Bluefin (our #358).
  Independent confirmation that re-stamping labels at the rechunk step
  is the right shape of fix, not a local hack.
- **OpenGamingCollective improved their kernel key import** ("fix:
  Improve kernel key import process"). Same domain as our MOK enrollment,
  which issue #353 has just shown to be the part users actually stumble
  on. Worth reading before the next change to `custom-kernel/install.sh`.
- **CachyOS has released 7.2**; we ship 7.1.8 through the
  `bieszczaders/kernel-cachyos` COPR, which tracks its own cadence.
  Nothing to do, noted so the gap is not a surprise later.
- **travier/fedora-atomic-desktops-sealed** spent the period on
  `image-builder` compatibility, Fedora's signed systemd-boot RPM, and
  `bootc install to-filesystem` with LUKS + cryptenroll + shim. Directly
  relevant to ADR-0007 (sealed bootable images) whenever that resumes.
- **Rootless CI** shows up in both Bazzite and image-template. We build
  with `sudo buildah`. Not a problem today, but if we ever revisit the
  build's privileges, that is the direction upstream has taken.
- **cosign**: image-template moved to v3; we were already there (v3.0.6,
  pinned for CVE-2026-39395). Nothing to do.
- **MorrOS** rebased off Bazzite instead of image-template. Their
  architectural pattern is what we cite, and that has not changed.

No change was required in any of the derivations this document records.

---

## License coexistence notes

- **Apache-2.0** is the Margine project license, applied to all
  Margine-originated code.
- **Origami's GPLv3** content was adapted in
  `custom-kernel/install.sh`. Per Apache-2.0 § 4(d), our distribution
  of derivative work bears notice of the original (this document +
  inline header comment in `install.sh`). If Origami's maintainers
  consider this insufficient attribution, please file an issue and we
  will adjust.
- Bluefin (Apache-2.0), Universal Blue (Apache-2.0), rechunk
  (Apache-2.0), Bazzite (Apache-2.0) are all license-compatible.
- MorrOS code is not redistributed; only the architectural pattern
  is acknowledged.
