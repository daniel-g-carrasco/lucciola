# Security claims register

What Lucciola promises about security, what each promise defends against,
and **what proves it**. A promise without an automated proof is listed as
such: the point of this file is that nothing is assumed to work because
the code for it exists.

I started it on 2026-10-07 for Margine OS, the image Lucciola grew from,
after a week in which six real holes were found by accident (see "Why
this file exists" at the end). Lucciola inherits every check, so the
register carries over. Numbers like margine-image #452 are pull requests
in Margine's repository, where those checks were written. Reviewed every
month by the "Security review due" issue
(`.github/workflows/security-review.yml`), which also flags overdue items
in the tables below.

Status values: **verified** (a CI gate fails when the promise breaks),
**partial** (some of it is gated, the rest is not), **unverified**
(nothing automated checks it), **limitation** (known not to hold, accepted
for now, with the reason).

## Claims

| ID | Promise | Defends against | Proof | Status |
|---|---|---|---|---|
| C1 | Shim, GRUB, the CachyOS kernel and every module form a signed chain; Secure Boot can enforce it | booting a tampered kernel or module | build: `sbverify` on vmlinuz, `sign-file` on modules (`build_files/custom-kernel/install.sh`), and the pushed image's kernel checked for the MOK signature (`build.yml` step "Verify the shipped kernel is still MOK-signed"); smoke-boot boots with Secure Boot enforcing and the key in MokList (`.github/smoke/security-probe.sh`: `secure-boot`, `mok-key`) | verified |
| C2 | Any install can enable Secure Boot later: the key is enrolled whether Secure Boot is on or off | an install that can never turn Secure Boot on | `mok-enroll` every boot (margine-image #443), `tests/mok-enroll.test.sh`, validator A.4.mok, smoke `mok-key`/`mok-helper` | verified |
| C3 | Every published image is signed, in the format devices read | an unsigned or wrongly signed image reaching users | sign job (`build.yml` step "Sign image by digest", classic + bundle), job-condition lint (`.github/scripts/check-job-conditions.py`, mutant `tests/mutants/sign-job-implicit-condition.toml`), ntfy UNSIGNED alarm ("ntfy notification"), every pushed tag checked against the signed digest ("Push rechunked image to GHCR"), smoke-boot refuses to promote without a valid classic signature ("Image must be signed with the Margine key") | verified |
| C4 | Devices verify that signature before deploying an update | a compromised registry or account pushing an image | policy scopes for `ghcr.io/daniel-g-carrasco/lucciola` and `.../margine` with the key and `registries.d` (`build_files/16-image-trust/install.sh`), migration of unverified installs (`margine-signed-origin`, `tests/signed-origin.test.sh`, mutant `tests/mutants/signed-origin-any-owner-image.toml`), validator A.4.trust, smoke `trust-policy` + `image-signature` through the device stack (`.github/smoke/security-probe.sh`) | verified |
| C5 | The image carries no secret and no per-machine identity: every install generates its own keys | one leaked image = keys of every install (a root adb key shipped until 2026-10-04) | image scan (`.github/scripts/scan-image-security.py`, `tests/scan-image-security.test.sh`, mutant `tests/mutants/scanner-prints-token.toml`), secrets fatal on every event (`build.yml` step "Security scan of the image (secrets, privileges, units, configs)") | verified |
| C6 | Security-relevant files, privileged binaries, enabled units and build residue only change through a reviewed diff | silent changes from our build or from the base image | image scan against `.github/security-baseline/` (`tests/scan-image-security.test.sh`): fails PRs, opens a drift issue on main (job "Security baseline drift report") | verified |
| C7 | SELinux labels user homes correctly | a home relabeled to `default_t` (sshd cannot read keys; confined apps break) | build fix + validator A.4.selinux-home (`build_files/40-spec-scripts/scripts/validate-margine-system`, margine-image #439), smoke `selinux-*` (`.github/smoke/security-probe.sh`) | verified |
| C8 | A fresh install exposes no network service beyond the reviewed set | an unexpected listener reachable from any network | smoke `listener` check against `.github/smoke/listeners-allow.txt`; today's set: LLMNR 5355 (D3), mDNS 5353 | verified |
| C9 | The firewall blocks unsolicited inbound traffic | services the user starts being reachable from the LAN | none: Fedora's `FedoraWorkstation` zone (inherited) allows all TCP/UDP ports above 1024 | limitation, decision D2 |
| C10 | The disk is encrypted | data read from a stolen disk | none: Lucciola is installed over Fedora Silverblue, whose installer offers LUKS without enforcing it, and no CI install checks it | unverified |
| C11 | TPM auto-unlock does not weaken disk encryption | someone with the laptop in hand | `lucciola-tpm-unlock` keeps the passphrase slot; the GRUB menu lock closes kernel command-line editing (margine-image #444, VM-tested, and #456 for a read-only `/boot`; validator A.4.grub-lock, `tests/grub-lock.test.sh`); the initramfs on `/boot` is neither signed nor measured into PCR 7, so it can be replaced by someone who can boot other media | limitation, decision D1 |
| C12 | The build supply chain is pinned and least-privilege | a moved tag or an over-privileged token | SHA-pinned actions, per-job permissions (Scorecard, `scorecard.yml`), Renovate; workflow job-condition lint (`.github/scripts/check-job-conditions.py`); the signing secrets only in the listed stage and jobs, staged right before the build and wiped right after (`tests/policy/secret-stages.txt`, `tests/policy/secret-jobs.txt`, `.github/scripts/check-secret-scope.py`) | partial |
| C13 | Two builds of the same tree publish the same layers | content changing without a source change | measured once on margine-image #442 (127/127 layers equal); nothing re-checks it | unverified, item E4 |
| C14 | SELinux denies nothing a Lucciola component needs | a service silently broken in enforcing mode | smoke reports the denials logged in its permissive VM (`.github/smoke/security-probe.sh`, the AVC report); not gating yet | partial, item E2 |
| C15 | Every guard has a test that fails when the guard is broken | a check that cannot fail (three such guards in the second review's mutation table) | one mutant per guard in `tests/mutants/`, run by `.github/scripts/mutation-check.py` (weekly `mutation.yml`, `just mutate`); lint applies every mutant on every pull request | partial: the guards the two reviews looked at; a new guard gets its mutant with its test |
| C16 | What the image is built from is built and boot-tested before it merges | a Containerfile or build_files change merged unbuilt | lint job `build-inputs-need-vm-test` (`.github/scripts/build-inputs-need-vm-test.py`, `tests/vm-test-gate.test.sh`): no `vm-test` label, no merge; `build.yml` builds `:pr-N` on the label | partial: not a required check yet (`tools/repo-guard.sh` holds the protection as code; `apply` not run) |
| C18 | main cannot be pushed to or merged into without the always-running checks, a pull request and resolved conversations | a direct push, a merge around a red check, a protection turned off in silence | `tools/repo-guard.sh` (check and apply, the policy as data), `tests/repo-guard.test.sh`; weekly `repo-guard.yml` reads the public `protected` field and notifies when main is unprotected | unverified: the protection is prepared, not applied (main is unprotected today) |
| C17 | The register itself names a real proof for every verified claim, and every test is run | a proof that is a sentence (this file until 2026-10-20: C1, C3, C5, C7 named no test), a test nobody wires into CI | `.github/scripts/check-claims.py` in lint's `policy` job, `tests/check-claims.test.sh` | verified |

## Decisions pending

Owner: the maintainer. A decision stays here until it is taken, and the
monthly review lists it until then.

| ID | Question | Options | Due |
|---|---|---|---|
| D1 | TPM unlock against an attacker with the laptop in hand | TPM + PIN (`--tpm2-with-pin`), passphrase only, or a signed UKI with a PCR 11 policy (ADR-0007) | 2026-10-31 |
| D2 | Default firewall zone | keep `FedoraWorkstation` (high ports open, Fedora default) or ship a stricter Lucciola zone | 2026-10-31 |
| D3 | LLMNR (systemd-resolved, port 5355 on all interfaces) | keep the Fedora default or turn it off | 2026-11-30 |
| D4 | `tailscaled` is enabled by default (inherited from Bluefin) and opens a UDP port on all interfaces | decided 2026-10-10: not shipped; `ujust lucciola-tailscale` layers and enables it on request | done |
| D5 | GSConnect (KDE Connect protocol) listens on port 1716 TCP/UDP on every interface by default, paired phone or not, and the default firewall zone lets the LAN reach it | moot since 2026-10-18: GSConnect left the image with the other GNOME Shell extensions (the Lucciola layer had removed it at build time since 2026-10-11) | done |

## Engineering items

| ID | Item | Due | Status |
|---|---|---|---|
| E1 | Make the in-image validator gating in smoke-boot once its first runs there are clean | 2026-10-31 | open |
| E2 | Make SELinux denials gating in smoke-boot (C14), after a reviewed baseline | 2026-11-30 | open |
| E3 | Boot the smoke VM enforcing: label the injected test files instead of `enforcing=0` | 2026-11-30 | open |
| E4 | Periodic double build to keep C13 verified | 2026-11-30 | open |
| E5 | CI install with LUKS and TPM unlock, to verify C10 and C11 end to end (needs an installer image, which Lucciola does not have yet) | 2026-12-31 | open |
| E6 | Attack-surface review of the setuid/capability set the base ships (`.github/security-baseline/privileged.txt`): e.g. `ksu`, `fusermount-glusterfs`, `vmware-user-suid-wrapper`, `suexec` serve few desktops; drop what Lucciola does not need | 2026-11-30 | open |

## Review findings (2026-10-20)

The two outside reviews of 20 October 2026 (R1-R10 the first, N1-N9 the
second). One row per finding: what was wrong, what fixes it, and the test
that fails if it comes back. "Pending merge" names the pull request that
carries the fix and its test; the monthly review lists those rows until
they are verified, and `check-claims.py` judges the proof of every row
marked verified or partial.

| ID | Finding | Fix | Proof | Status |
|---|---|---|---|---|
| R1 | The secret scanner printed the token it found, in the log and in a 30-day artifact | the report names path and category only; nothing is copied to the artifact when a secret is found | `tests/scan-image-security.test.sh`, mutant `tests/mutants/scanner-prints-token.toml` | verified |
| R2 | Downloaded RPM trust was not confined to the pinned key; `gpgcheck=0` in a downloaded repository file survived | `rpm-trust`: exactly one primary key, `gpgcheck=1` and the local key in every section, shared by the build and `layer-repo` | `tests/rpm-trust.test.sh`, mutant `tests/mutants/rpm-trust-gpgcheck-off.toml` | verified |
| R3 | The scanner resolved the image's PAM symlinks on the runner | links resolved inside the image root, hop-bounded | `tests/scan-image-security.test.sh`, mutant `tests/mutants/scanner-host-symlinks.toml` | verified |
| R4 | Apps that left the default set were uninstalled by `flatpak preinstall` | `flatpak-preinstall-keep` takes them off the record before each preinstall | `tests/flatpak-preinstall-keep.test.sh` (the real `flatpak preinstall`, lint job `flatpak-preinstall`), mutant `tests/mutants/flatpak-preinstall-keep-noop.toml` | verified |
| R5 | Every boot relabelled and repaired the Flatpak installation, holding the graphical target | repair only after a failed run or on a broken repository, once per boot, outside the target's ordering | `tests/flatpak-repo-repair.test.sh` | verified |
| R6 | A command piped into `tail`, in a shell without pipefail, reported tail's success | the command's own status is kept; a missing gaming list fails | `tests/pipeline-status.test.sh`, mutants `tests/mutants/validate-baseline-tail-status.toml` and `tests/mutants/upgrade-smoke-tail-status.toml` | verified |
| R7 | The user staleness timer exited quietly on root-only `bootc status` | read-only `rpm-ostree status --booted`, the booted entry, the followed tag | `tests/staleness.test.sh`, mutant `tests/mutants/staleness-bootc-status.toml` | verified |
| R8 | The install instructions named `:stable` and `:fedora-kernel`, held back until Fedora 45's release | a note beside each command; `ujust lucciola-kernel` names an unpublished image among the causes | none automated: text, read by a person | unverified (text) |
| R9 | The base digest label was looked up apart from the base the build pulled | the base is resolved once; the build is FROM that digest and the labels record it | `tests/resolve-base.test.sh`, mutant `tests/mutants/resolve-base-ignores-failure.toml` | verified |
| R10 | Active developer entry points still offered Margine's ISO tooling | archived under `docs/history/margine/`, entry points removed | `tests/retired-iso-tooling.test.sh` | verified |
| N1 | The MOK private key was mounted on the RUN that runs every build step and package scriptlet | a `mok-sign` stage FROM the clean base, no network, the signer alone; `refuse_signing_key` in every build step | `tests/mok-secret-scope.test.sh`, `tests/mok-sign.test.sh` (pull request #30); the stage policy `tests/policy/secret-stages.txt` with `.github/scripts/check-secret-scope.py`, red until then | pending merge (#30) |
| N2 | The scrcpy checksum was derived from the same download Renovate then automerged | the pin must match upstream's signed `SHA256SUMS.txt` (key pinned under `.github/keys/`), checked on the Renovate branch with the base's verifier | `tests/scrcpy-signed-sha.test.sh`, the `pins` job step "The scrcpy pin is what upstream signed" (pull request #30) | pending merge (#30) |
| N3 | The security scan and the SBOM read the image before chunking, not the artifact pushed and signed | both read the chunked image, whose config digest the push checks | `tests/scan-what-ships.test.sh` (pull request #30) | pending merge (#30) |
| N4 | `lucciola-autologin on` could enable greetd's autologin and then fail on GDM's mirror, leaving the two apart | both files rendered first, then committed with atomic renames, the first rolled back when the second cannot commit | `tests/lucciola-autologin.test.sh`, the partial-failure cases (pull request #29) | pending merge (#29) |
| N5 | The content editor served its mutation token to any local client that set `Host: localhost` | the key travels only in the fragment of the address the editor opens, is never served, and every API request must carry it | `tests/content-editor-server.test.py`, a second local client against a running server (pull request #29) | pending merge (#29) |
| N6 | Handing the greeter's conversation to another output lost the typed password | the password moves with the conversation (patch 0005) | `tests/greeter-look.test.sh` checks the patch is applied; the C++ state machine itself has no test | pending merge (#29), partial after |
| N7 | A Kinoite install that selected SDDM kept a dangling `display-manager.service` link after the rebase | a link to a unit this image does not have is switched to greetd; one that exists stays | `tests/login-migrate.test.sh`, the missing-unit cases (pull request #29); the weekly upgrade matrix boots from Kinoite (`upgrade-smoke.yml`) | pending merge (#29) |
| N8 | The guide had one return path (Silverblue 44) and no fingerprint or welcome-window step | per-start return refs, fingerprint enrollment, what survives a rollback | none automated: text, read by a person (pull request #29) | unverified (text) |
| N9 | scrcpy, installed from a tarball, had no package identity in the SBOM | components installed outside RPM are recorded in the image and merged into the SBOM, checked against the files | `tests/sbom-components.test.sh` (pull request #30) | pending merge (#30) |

## Why this file exists

In the first week of October 2026 six holes were found in Margine, none by
a check designed to find them: the signing key never enrolled on installs made with
Secure Boot off; devices never verifying image signatures (no policy scope,
and signatures in a format the device stack cannot read); TPM unlock
bypassable from the GRUB menu; an SELinux home mapping inherited reversed
from the base image; a root adb private key baked into every image; and
image signing silently skipped by a workflow change. The 2026-06-05 audit
had already named device-side signature verification as the load-bearing
check and deferred it "until a running install is available". It stayed
deferred for four months. This register, its due dates and the monthly
review are there so that does not happen again.
