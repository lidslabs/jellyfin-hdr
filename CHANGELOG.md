# Changelog
## [0.2.0+jellyfin-10.11.11] - 2026-06-15

Upstream patch release pickup. No changes to lidslabs patch layer.

### Changed
- Pinned to upstream Jellyfin v10.11.11 (was v10.11.10)
- Pinned to runtime base image `jellyfin/jellyfin:10.11.11`
- Patches rebased cleanly onto v10.11.11 with no conflicts (upstream changeset
  was unrelated to encoding pipeline; touched only `UserManager` lock guarding)

### Documentation
- README: added full description of audio compatibility-track redirect
  (feature shipped in v0.1.0 but was previously undocumented in README;
  only mentioned in CHANGELOG)

All notable changes to lidslabs/jellyfin-hdr.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: semver on the lidslabs patch layer, with upstream Jellyfin
pinned per release via the `+jellyfin-X.Y.Z` build metadata suffix on git tags.

## [0.1.0+jellyfin-10.11.10] - 2026-06-15

First tagged release. Migrated from manual file-overlay Dockerfile to a
fork-branch + format-patch + git-am workflow with patches committed under
`patches/` and immutable images published to ghcr.io.

### Added
- HDR10 / HDR10+ / HLG passthrough for HEVC and AV1 encode targets, gated by `JELLYFIN_ALLOW_HDR_TRANSCODE=1`
- Dolby Vision Profile 7 conditional software decode when a subtitle is engaged for delivery
- `mainEndsInCudaMemory` widening in `GetNvidiaVidFiltersPrefered` to fix DV7 + PGS burn-in filter graph routing
- Audio compatibility-track redirect for DD 5.1 preference during transcode
- HLS manifest tagging: `VIDEO-RANGE=PQ` / `HLG`, `hvc1.2.4.*` codec string for Main10

### Pinned to
- Jellyfin upstream tag: `v10.11.10`
- Runtime base image: `jellyfin/jellyfin:10.11.10`
- Fork commit: see `JELLYFIN_REF`
