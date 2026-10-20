# Margine OS documents

These documents describe Margine OS, the GNOME image Lucciola grew out of.
I keep them for the reasoning behind decisions Lucciola inherits: the
CachyOS kernel and its signing, Secure Boot and the TPM, the base image,
the update and promotion model, the incidents that shaped the checks.

They are not maintained. Paths, names, packages and plans in them are
Margine's and may no longer match this repository. For what Lucciola does
today, read the [README](../../../README.md), [`lucciola/README.md`](../../../lucciola/README.md)
and [`docs/BRANDING.md`](../../BRANDING.md).

- [`CHANGELOG.md`](CHANGELOG.md): Margine's changelog, up to the move to Lucciola.
- [`spec/`](spec/README.md): the handbook, the ADRs, audits and lessons learned.
- [`notes/`](notes/): incident and engineering notes.
- [`live-env/`](live-env/) and [`tools/`](tools/README.md): Margine's live ISO
  image, the window that built it locally, and its benchmark scripts.
- [`iso-titanoboa-migration-plan.md`](iso-titanoboa-migration-plan.md),
  [`plan-b-bluefin-dx-deprecation.md`](plan-b-bluefin-dx-deprecation.md),
  [`build-sh-decomposition.md`](build-sh-decomposition.md),
  [`sbom-revisit-plan.md`](sbom-revisit-plan.md): plans written for Margine.
