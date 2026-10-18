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
| C1 | Shim, GRUB, the CachyOS kernel and every module form a signed chain; Secure Boot can enforce it | booting a tampered kernel or module | build: `sbverify` on vmlinuz, `sign-file` on modules, a check that the pushed image's kernel carries the MOK signature; smoke-boot boots with Secure Boot enforcing and the key in MokList (security probe `secure-boot`, `mok-key`) | verified |
| C2 | Any install can enable Secure Boot later: the key is enrolled whether Secure Boot is on or off | an install that can never turn Secure Boot on | `mok-enroll` every boot (margine-image #443), `tests/mok-enroll.test.sh`, validator A.4.mok, smoke `mok-key`/`mok-helper` | verified |
| C3 | Every published image is signed, in the format devices read | an unsigned or wrongly signed image reaching users | sign job (classic + bundle), job-condition lint, ntfy UNSIGNED alarm, every pushed tag checked against the signed digest, smoke-boot refuses to promote without a valid classic signature | verified |
| C4 | Devices verify that signature before deploying an update | a compromised registry or account pushing an image | policy scopes for `ghcr.io/daniel-g-carrasco/lucciola` and `.../margine` with the key and `registries.d` (`16-image-trust`), migration of unverified installs (`margine-signed-origin`, `tests/signed-origin.test.sh`), validator A.4.trust, smoke `trust-policy` + `image-signature` through the device stack | verified |
| C5 | The image carries no secret and no per-machine identity: every install generates its own keys | one leaked image = keys of every install (a root adb key shipped until 2026-10-04) | image scan, secrets fatal on every event | verified |
| C6 | Security-relevant files, privileged binaries, enabled units and build residue only change through a reviewed diff | silent changes from our build or from the base image | image scan against `.github/security-baseline/`: fails PRs, opens a drift issue on main | verified |
| C7 | SELinux labels user homes correctly | a home relabeled to `default_t` (sshd cannot read keys; confined apps break) | build fix + validator A.4.selinux-home (margine-image #439), smoke `selinux-*` | verified |
| C8 | A fresh install exposes no network service beyond the reviewed set | an unexpected listener reachable from any network | smoke `listener` check against `.github/smoke/listeners-allow.txt`; today's set: LLMNR 5355 (D3), mDNS 5353 | verified |
| C9 | The firewall blocks unsolicited inbound traffic | services the user starts being reachable from the LAN | none: Fedora's `FedoraWorkstation` zone (inherited) allows all TCP/UDP ports above 1024 | limitation, decision D2 |
| C10 | The disk is encrypted | data read from a stolen disk | none: Lucciola is installed over Fedora Silverblue, whose installer offers LUKS without enforcing it, and no CI install checks it | unverified |
| C11 | TPM auto-unlock does not weaken disk encryption | someone with the laptop in hand | `lucciola-tpm-unlock` keeps the passphrase slot; the GRUB menu lock closes kernel command-line editing (margine-image #444, VM-tested, and #456 for a read-only `/boot`; validator A.4.grub-lock, `tests/grub-lock.test.sh`); the initramfs on `/boot` is neither signed nor measured into PCR 7, so it can be replaced by someone who can boot other media | limitation, decision D1 |
| C12 | The build supply chain is pinned and least-privilege | a moved tag or an over-privileged token | SHA-pinned actions, per-job permissions (Scorecard), Renovate; workflow job-condition lint | partial |
| C13 | Two builds of the same tree publish the same layers | content changing without a source change | measured on margine-image #442 (127/127 layers equal); not re-checked automatically | partial, item E4 |
| C14 | SELinux denies nothing a Lucciola component needs | a service silently broken in enforcing mode | smoke reports denials logged in its permissive VM; not gating yet | partial, item E2 |

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
