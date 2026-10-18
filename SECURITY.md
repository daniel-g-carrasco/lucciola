# Security policy

Lucciola is an experimental operating system, and I maintain it alone. I
take its security seriously: every image is signed with
[cosign](https://github.com/sigstore/cosign) by digest, and devices check
that signature before they install an update. The CachyOS kernel and every
kernel module are signed for Secure Boot. GitHub Actions are pinned by SHA,
workflow tokens get only the permissions they need, SBOMs are generated and
signed, and Renovate keeps dependencies current. Triage and fixes are
still best effort, by one person.

## What is promised, and what proves it

[`docs/SECURITY-CLAIMS.md`](docs/SECURITY-CLAIMS.md) lists every security
promise Lucciola makes, the attack it defends against, the automated check
that proves it, and the known limitations. I review it every month.

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately through GitHub:
<https://github.com/daniel-g-carrasco/lucciola/security/advisories/new>

If you cannot use GitHub Security Advisories, email **ai@danielgrasso.com**
with `[lucciola-security]` in the subject (PGP available on request).

Where you can, include the affected component and the image version or
digest, a description, steps to reproduce or a proof of concept, and the
impact you expect.

## What to expect

- **Acknowledgement:** usually within 14 days.
- **Fix:** triaged by severity; a fix or mitigation ships in a new image as
  soon as practical. Lucciola checks for updates every day and applies
  them at the next restart, so an accepted fix reaches users with no
  manual steps.
- **Disclosure:** coordinated; I credit reporters who want it.

## Scope

**In scope:** the build pipeline, the published image
(`ghcr.io/daniel-g-carrasco/lucciola`), the kernel signing and MOK
enrollment, the login screen setup (greetd with Noctalia Greeter), and the
helpers and configuration this repository ships.

**Out of scope, or not a vulnerability:**

- **The MOK enrollment password `margine` is public by design.** It only
  confirms, at a reboot with someone at the keyboard, that the
  already-built signing key should be enrolled on that machine. It is not
  a secret and grants nothing remotely. The key and the password still
  carry the name of Margine OS, the project Lucciola grew from, which
  signs with the same key: that is why MOK Manager shows "Margine MOK
  Signing Key".
- Problems in upstream components shipped unchanged (Fedora, Universal
  Blue, the CachyOS kernel, niri, Noctalia, greetd, Flatpak apps): please
  report them upstream. Lucciola picks up their fixes on the next build.

## Verify the image signature

```sh
cosign verify \
  --key https://raw.githubusercontent.com/daniel-g-carrasco/lucciola/main/secrets/cosign.pub \
  ghcr.io/daniel-g-carrasco/lucciola:stable
```

A valid signature prints the verified payload and exits 0. The public key
is [`secrets/cosign.pub`](secrets/cosign.pub); the private half exists only
in CI.
