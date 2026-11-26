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
  Blue, the CachyOS kernel, Umbriel, Noctalia, greetd, Flatpak apps): please
  report them upstream. Lucciola picks up their fixes on the next build.

## Verify the image signature and inventory

Resolve the channel to a digest once, then use that digest for every check.

```sh
image=ghcr.io/daniel-g-carrasco/lucciola
digest=$(oras resolve "$image:stable") || exit
ref="$image@$digest"
cosign verify --key secrets/cosign.pub --new-bundle-format=false "$ref"
oras discover --artifact-type application/vnd.spdx+json --depth 1 "$ref"
```

Use the public key from a trusted checkout. The classic signature is the
format devices check. The SPDX inventory is an OCI referrer whose manifest
names the image digest as its subject. Verify the inventory referrer's own
signature with `cosign verify --key secrets/cosign.pub IMAGE@SBOM_DIGEST`.
Use the referrer's digest for `oras pull`.

Main image builds also record GitHub build provenance by digest.
Verify it with `gh attestation verify "oci://$ref" --repo daniel-g-carrasco/lucciola --signer-workflow daniel-g-carrasco/lucciola/.github/workflows/build.yml`.
Existing digests predate this attestation. The Fedora-kernel reserve records
its source revision, base and parent stable digest in signed image metadata.

## Advisories for published images

The daily **Advisories for published Lucciola images** workflow refreshes
Grype's database and scans the signed SBOMs for stable, the Fedora-kernel
reserve and the two newest dated tags in each channel. It scans aliases
sharing a digest once and supports a manual scan of any retained Lucciola
digest. High and Critical matches or incomplete coverage surface in the run
summary and make the run fail. Scheduled failures also use ntfy when
configured. The report covers packages present in the image inventory.
