# Changelog

All notable changes to the Lucciola bootc image build are recorded here.
Image tags follow `stable`, `stable.YYYYMMDD`, `YYYYMMDD`.
Semantic versioning (`v0.X.Y`) will start once the first user-facing
stable release is cut.

## [Unreleased]

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
