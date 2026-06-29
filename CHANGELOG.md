# Changelog
## [Unreleased]

### Added
- **`LIDSLABS_FORCE_HLS_CLIENTS` (forced-HLS transport).** Comma-separated
  friendly client names (same mapping as `LIDSLABS_FORCE_HEVC_CLIENTS`) whose
  progressive (`http`) video transcoding profiles are flipped to HLS (container
  normalized to `ts`) in `MediaInfoController.GetPostedPlaybackInfo`. Targets
  clients that only advertise HEVC on a progressive profile (e.g. Neptune
  Trident), whose progressive playback buffers ~10 s before starting vs ~5 s on
  HLS. Unset by default; runs after the forced-HEVC rewrite so a flipped profile
  still carries HEVC. **Note:** forces HLS+HEVC on clients that didn't advertise
  it, so it requires per-client on-device validation. See `README.md`.

## [0.3.0+jellyfin-10.11.11] - 2026-06-24

Forced HEVC override for HDR-capable Apple TV clients (Neptune Trident,
Streamyfin) that advertise HEVC + HDR10 capability but request h264 + SDR
transcodes. Audio compatibility-track redirect widened from HLS-only to
HLS or Progressive transcode outputs. Project-owned env vars unified
under the `LIDSLABS_*` prefix.

### Highlights
- **Native-4K HDR10 on HDR-capable Apple TV clients.** Neptune Trident and
  Streamyfin now receive HEVC HDR10 instead of h264 SDR — Trident goes from
  1440p SDR to native 4K HDR10 at the same bitrate cap (HEVC's efficiency
  brings the resolution win along with the HDR win).
- **Audio compat redirect now covers Progressive output, not just HLS** —
  Neptune Trident's MKV-over-HTTP path gets full-surround AC3 stream-copy
  instead of lossy AAC downmix.
- **⚠️ Breaking:** `JELLYFIN_ALLOW_HDR_TRANSCODE` is renamed to
  `LIDSLABS_ALLOW_HDR_TRANSCODE`. **Update your compose env var before pulling
  this image** — the old name is silently ignored and the HDR gate defaults off.
- New `LIDSLABS_FORCE_HEVC_CLIENTS` env var selects which clients get the
  override (friendly names: `neptune`, `streamyfin`).

### Added
- **Forced HEVC override on PlaybackInfo.** New hook in
  `MediaInfoController.GetPostedPlaybackInfo` rewrites
  `TranscodingProfile.VideoCodec` to prepend `"hevc"` before StreamBuilder
  processes the request. Gated on four conditions: master toggle
  `LIDSLABS_ALLOW_HDR_TRANSCODE=1`, client matches an entry in
  `LIDSLABS_FORCE_HEVC_CLIENTS` (via friendly-name → profile-substring
  mapping), source is HDR, and the client's DeviceProfile declares HEVC
  capability.
- **Friendly-name → profile-substring mapping.** `LIDSLABS_FORCE_HEVC_CLIENTS`
  accepts ergonomic names (`neptune`, `streamyfin`) which map internally to
  `DeviceProfile.Name` substrings (`Trident`, `1. MPV`). Adding a new client
  requires a code change with a reviewable mapping entry. See `README.md`
  for the procedure.
- **Audio compat redirect on Progressive transcodes.** The AC3-sidecar
  substitution in `EncodingHelper.cs` was widened from `Hls`-only to
  `Hls || Progressive`. Neptune Trident's MKV-over-HTTP path now receives
  the AC3 sidecar substitution that v0.2 only delivered on HLS.
- **Gate-decision diagnostic logging.** The forced-HEVC hook logs its gate
  inputs and eligibility result at the evaluation point, at `Debug` level —
  dormant in a default (Information-level) build, so it emits nothing in
  production. Raise the log level to Debug to diagnose a "doesn't fire"
  report in one cycle instead of a rebuild.

### Changed
- **Env var rename:** `JELLYFIN_ALLOW_HDR_TRANSCODE` is now
  `LIDSLABS_ALLOW_HDR_TRANSCODE`. v0.2.0 users must update their compose
  file before pulling this image — the old name is silently ignored and
  the HDR gate will default to off. The lidslabs custom env vars are now
  consistently `LIDSLABS_*`-prefixed; see `DECISIONS.md` for rationale.
- **Dockerfile `ENV` default** updated to `LIDSLABS_ALLOW_HDR_TRANSCODE=0`
  to match.

### Fixed
- **Pre-release:** removed an over-strict candidate filter
  (`videoRequest.AudioCodec.Contains`) from the audio compat redirect that
  silently blocked Streamyfin's AC3 substitution on HLS segment requests.
  Root cause: `videoRequest.AudioCodec` on segment URLs contains
  StreamBuilder's narrowed transcode-target list (typically just `aac`),
  not the client's full DeviceProfile capability. Restored v0.2
  substitution semantics for HLS while keeping the Progressive widening.
  See `DECISIONS.md` for the full rationale, including the rule that
  client capability signals at `MediaInfoController` scope vs
  `EncodingHelper` scope are not interchangeable.

### Compatibility
- **Verified end-to-end:** Neptune Trident (HEVC HDR10 main 10 at native
  4K + AC3 5.1), Streamyfin (server-side correct; client-side audio
  routing bug remains and is out of scope).
- **Excluded by design:** Neptune AV Player. The friendly-name mapping
  intentionally excludes AV Player because the client declares HEVC HDR10
  capability but its player module cannot render the resulting HLS HEVC
  HDR10 stream (black screen). AV Player falls through to the baseline
  h264 SDR transcode and still receives the audio compat redirect
  benefit on its Progressive path.
- **No change from v0.2.0:** Moonfin (client never requests segments;
  pre-existing client-side abort), Swiftfin, Jellyfin Web, Jellyfin
  Mobile, Wholphin, Android clients (no friendly-name entry).

### Performance
- Apple HEVC clients target a quality metric and use 60-75% of the
  configured `MaxStreamingBitrate` cap on transcoded HEVC output
  (measured at 20 Mbps and 40 Mbps caps). Apple h264 paths and non-Apple
  HEVC paths use the full declared cap. To deliver N Mbps to an Apple
  HEVC client, set the server cap to roughly N × 1.4. See `DECISIONS.md`
  for the full measurement table and remote-user config pattern.
- Neptune Trident under the forced HEVC path now transcodes at native
  4K (3840×2160) at 20 Mbps where v0.2.0 produced h264 SDR at 1440p —
  HEVC's compression efficiency fits 4K within the same bitrate cap.

### Documentation
- `README.md`: documented `LIDSLABS_FORCE_HEVC_CLIENTS` and the
  friendly-name → profile-substring mapping, with the procedure for
  adding a new client.
- `DECISIONS.md`: added the v0.3.0 entries covering the forced HEVC
  override, audio compat widening, env var namespace consolidation,
  bitrate calibration, and the principle on client capability signals
  across `MediaInfoController` vs `EncodingHelper` scope.

### Pinned to
- Jellyfin upstream tag: `v10.11.11` (unchanged from v0.2.0)
- Runtime base image: `jellyfin/jellyfin:10.11.11`
- Fork commit: see `JELLYFIN_REF`

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
