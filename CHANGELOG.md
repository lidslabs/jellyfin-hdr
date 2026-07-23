# Changelog
## [0.3.3+jellyfin-10.11.11] - 2026-07-23

Bug-fix bundle that makes **HDR play correctly on Apple AVPlayer clients** —
including seek and resume — and retires the HDR→SDR tonemap workaround it replaces.
The v0.3.2 approach forced AVPlayer-family clients to SDR because they black-screen
on an HDR-over-HLS master; the real cause was the master advertising a *single* HDR
variant, which AVPlayer refuses to enter. Adding an SDR companion variant lets
AVPlayer commit and select HDR on its own. Same upstream Jellyfin (`v10.11.11`);
patch series grows from 14 to 20.

### Highlights
- **Swiftfin (Apple TV) now plays HDR** — on initial start, seek, and resume. The
  HDR-passthrough master gains an H.264 SDR companion rung so AVPlayer commits to
  it and selects the HDR (PQ) variant.
- **Neptune AV Player plays without the SDR-tonemap lever.** It commits via the
  ladder and selects the SDR rung (a client-side ceiling in its current build), so
  no forced tonemap is needed — SDR that plays instead of a black screen.
- **Moonfin plays HDR** (its mpv render path was fixed upstream) and its seek/resume
  now start reliably.
- **Seek and resume no longer stall** on strict fMP4 players. The HDR path used a
  stale MPEG-TS timestamp hack (`-avoid_negative_ts make_zero`) that reset a seek
  segment's timeline; it now uses stock behavior.
- **`LIDSLABS_FORCE_SDR_CLIENTS` is removed** — the SDR ladder supersedes it.
- **New `LIDSLABS_SDR_LADDER_CLIENTS`** (default `swiftfin,neptune_av`) scopes the
  SDR companion rung to Apple AVPlayer clients; everyone else gets the clean
  HDR-only master.

### Added
- **H.264 SDR companion rung for AVPlayer clients (patch 0020).** On an
  HDR-passthrough master, adds a tonemapped-SDR variant alongside the HDR one so
  AVPlayer will start playback. Scoped by `LIDSLABS_SDR_LADDER_CLIENTS`, decided at
  PlaybackInfo (where the client name and `DeviceProfile.Name` are both reliable —
  Trident is correctly excluded) and carried to the master.m3u8 request as a
  `TranscodingUrl` marker, since that request's `?ApiKey=` auth makes client
  identity unreliable there.
- **Optional forced HEVC for Swiftfin (patch 0015).** `swiftfin` may be listed in
  `LIDSLABS_FORCE_HEVC_CLIENTS` to force a DV P7 title to clean HEVC HDR10 instead
  of an h264 SDR tonemap.

### Changed
- **HEVC HDR passthrough is pinned to Main tier at the correct level (patch 0016).**
  `-tier:v main -level:v` (5.1 for 2160p, else 5) so the NVENC output matches the
  advertised `hvc1.2.4.L1xx.B0` CODECS string; AVPlayer refuses a tier/level
  mismatch.
- **Swiftfin gets stock handling by default (patch 0015).** The client-name gate is
  re-pointed from the stale `"Jellyfin tvOS"` to `"Swiftfin tvOS"` (the v1.5 App
  Store rename), and the DV P7 EL-strip / forced-transcode path is dropped —
  on-device testing showed forcing a transcode was the wrong direction.

### Removed
- **`LIDSLABS_FORCE_SDR_CLIENTS` and its HDR→SDR tonemap path (patch 0019).**
  Superseded by the SDR ladder: no client needs a forced tonemap now, and Moonfin's
  washout (its original reason) was fixed upstream. The shared client matcher and
  the honor-explicit-SDR-request gate are retained (the latter now backs the ladder
  rung).

### Fixed
- **AVPlayer seek loses video / audio-only playback (patch 0018).** A play session
  advertising both an HDR (hevc) and an SDR-companion (h264) variant hashed both to
  the same transcode output path (codec absent from the hash), so their fMP4 init
  segments clobbered each other — on seek, AVPlayer got an `avcC` init in front of
  `hvcC` segments: frozen video, audio kept playing. The output path now includes
  the video/audio codec.
- **Seek/resume stall on fMP4 clients (patch 0017).** The HDR path used
  `-avoid_negative_ts make_zero`, which reset a seek segment's `tfdt` to ~0 while
  the playlist positioned it at N×seglen — strict players (AVPlayer, mpv) stalled.
  Now uses stock `-avoid_negative_ts disabled`, preserving the seek offset.

## [0.3.2+jellyfin-10.11.11] - 2026-07-06

Bug-fix bundle focused on **HDR that works whatever the client and decoder
setting are**. Four classes of fix: (1) HDR passthrough now works with
Jellyfin's **"Enhanced NVDEC decoder"** left on (its upstream default), instead
of hard-failing to a black screen; (2) **AVPlayer-family Apple TV clients**
(Swiftfin, Neptune AV Player, Moonfin) — which reject HDR-over-HLS and previously
went black or silent — now render, via a mix of container/codec corrections and a
per-client HDR→SDR tonemap lever; (3) the **forced-HEVC** override is decoupled
from the HDR path so it also upgrades SDR remuxes; (4) **transcoded `PlaybackInfo`
now describes the delivered stream**, not the source — so a client keys its
display mode (DV / HDR10 / SDR) off what it actually receives. Same upstream
Jellyfin (`v10.11.11`); patch series grows from 5 to 14.

### Highlights
- **HDR transcodes work with "Enhanced NVDEC decoder" ON (the upstream
  default).** Previously HDR passthrough black-screened unless you knew to turn
  that dashboard setting off. Now always works, either way — no configuration.
- **Swiftfin (Apple TV) plays HDR titles cleanly.** Fixes silent TrueHD
  direct-play, Dolby Vision Profile 7 static, and HEVC-in-MPEG-TS breakage (now
  delivered as fMP4/CMAF, the Apple-native path). *Client note: for HDR to engage
  the TV's HDR mode, use Swiftfin's **Native Player** — its default VLCKit engine
  doesn't tone-map or trigger tvOS HDR switching.*
- **Neptune AV Player is now supported** (forced HEVC + fMP4 + HDR→SDR tonemap).
  AVPlayer cannot ingest an HDR-over-HLS stream, so its HDR titles are tonemapped
  to SDR (HEVC preserved) rather than left black.
- **New `LIDSLABS_FORCE_SDR_CLIENTS`** env var — force named clients' HDR titles
  onto an HDR→SDR tonemap (codec unchanged) for AVPlayer-family clients that
  can't parse `VIDEO-RANGE=PQ`. Runtime-tunable, no rebuild.
- **`LIDSLABS_FORCE_HEVC_CLIENTS` now also upgrades SDR sources** and fires
  independently of `LIDSLABS_ALLOW_HDR_TRANSCODE`. A 40 Mbps H264 SDR remux to a
  forced client now becomes ~20 Mbps HEVC SDR instead of re-encoding to H264.
- **Native-4K forced HEVC no longer capped below 2160p** — the profile now
  advertises HEVC Level 5.1 so a forced 2160p transcode isn't downscaled.
- **Moonfin (Apple TV) is now supported.** Fixes its black screen (the server was
  rejecting its own manifest URL) and its Dolby Vision display-mode misfire (the
  TV engaged DV over an SDR/HDR10 transcode). Moonfin's HDR titles are tonemapped
  to SDR (HEVC preserved), the correct outcome for its transcode path.
- **Transcoded playback info now reports the delivered stream.** A client that
  reads `VideoRangeType` to pick its display mode (DV vs HDR10 vs SDR) now sees
  what it actually receives, not the source — no more DV engaged over an HDR10 or
  SDR transcode.

### Added
- **`LIDSLABS_FORCE_SDR_CLIENTS` (patch 0011).** Comma-separated friendly client
  names whose HDR titles are forced onto an HDR→SDR tonemap while keeping the
  HEVC codec. Decided at PlaybackInfo by `DeviceProfile.Name` (collision-safe:
  distinguishes `"Neptune tvOS"` from `"Neptune tvOS (Trident)"`), carried on the
  transcode request as `VideoRangeType=SDR`, and honored at the HDR-passthrough
  gate in `EncodingHelper.IsHdrPassthroughMode`. Fixes the AVPlayer-family black
  screen: those clients reject the HLS master playlist's `VIDEO-RANGE=PQ` and
  never request a segment. Inert on SDR sources and idempotent. Default `neptune_av`.
- **Neptune AV Player support (patch 0009).** New collision-safe `neptune_av`
  friendly name in `LIDSLABS_FORCE_HEVC_CLIENTS` (matches `"Neptune tvOS"` but not
  Trident), paired with an fMP4 HLS transport force so forced HEVC is delivered as
  CMAF, not MPEG-TS. Combined with `LIDSLABS_FORCE_SDR_CLIENTS=neptune_av`, AV
  Player renders 4K HDR content as clean HEVC SDR.
- **fMP4 HLS transport force for Swiftfin (patch 0007).** Rewrites the video HLS
  `TranscodingProfile` container `ts→mp4` so a forced/remuxed HEVC stream is
  delivered as fMP4 — Apple AVPlayer cannot decode HEVC-in-MPEG-TS (it showed
  digital static).

### Changed
- **Forced-HEVC override is now source-independent (patch 0008).** The rewrite
  that prepends `hevc` to `TranscodingProfile.VideoCodec` no longer requires an
  HDR source and is no longer gated on `LIDSLABS_ALLOW_HDR_TRANSCODE`. Base
  eligibility is now *client-in-list + client advertises HEVC*, so a forced client
  gets HEVC on **SDR** sources too (an H264 SDR remux becomes HEVC SDR instead of
  re-encoding to H264). The HDR master toggle still solely governs HDR passthrough
  itself; the two levers are independent. The safeguard is unchanged — the
  override never forces a codec the client didn't advertise.

### Fixed
- **HDR passthrough works with "Enhanced NVDEC decoder" enabled (patch 0006).**
  Jellyfin's `EncodingOptions.EnableEnhancedNvdecDecoder` **defaults to ON
  upstream**; with it on, HDR passthrough on Nvidia hard-failed with
  `CUDA_ERROR_MAP_FAILED` (`cuvidMapVideoFrame`) — a black screen / first-frame
  freeze, not a wrong-colors bug. Root cause: the enhanced decoder emits
  `-hwaccel_flags +unsafe_output`, handing NVENC the decoder's un-copied CUDA
  surfaces; the HDR path's no-op `scale_cuda=p010` passthrough then pins and
  exhausts the finite decoder surface pool. Fix: omit **only** `+unsafe_output` on
  the HDR-passthrough path — the enhanced decoder is kept, not replaced with
  `*_cuvid`. Always on; every non-HDR / non-Nvidia command is byte-identical to
  upstream. Reproduced and verified on HDR10 and Dolby Vision Profile 7. See
  `DECISIONS.md`.
- **Swiftfin (Apple TV) capability corrections (patch 0007).** Three always-on
  fixes under one `User.GetClient() == "Jellyfin tvOS"` gate: (a) strip the TrueHD
  family (`truehd`/`mlp`) from Swiftfin's audio direct-play profiles — it
  advertises lossless direct-play it can't decode, producing **silence**; DTS-HD
  MA is left intact (AVPlayer decodes its DTS core); (b) inject an `hevc`
  `VideoRangeType` allow-list excluding only the DV enhancement-layer types so
  Dolby Vision Profile 7 stream-copies with `dovi_rpu=strip` to clean HDR10 (no
  re-encode) instead of blind-copying the dual-layer stream as **static**; (c) the
  fMP4 transport force above. **Known residual (Swiftfin client bug, out of
  scope):** on its default VLCKit engine the Apple TV stays in SDR display mode on
  the transcode path — use Swiftfin's Native Player for HDR.
- **Forced HEVC no longer capped below native 4K (patch 0010).** The forced-HEVC
  profile now advertises HEVC Level 5.1, so a forced 2160p transcode is delivered
  at native resolution instead of being downscaled to fit a lower level's limits.
- **Moonfin black screen — `master.m3u8` HTTP 400 (patch 0012).** Moonfin posts a
  9-codec HLS-fMP4 profile, so the server's own StreamBuilder emitted a 42-char
  `AudioCodec=` query value that overflowed the stock 40-char validation regex on
  the manifest endpoint — ASP.NET model validation then 400'd the server's own
  generated URL before playback could start. Widened the cap 40 → 80; the regex
  shape is otherwise unchanged. Self-inflicted, not a Moonfin bug (clients with
  shorter codec lists were unaffected).
- **Transcoded `PlaybackInfo` describes the delivered stream, not the source
  (patch 0013).** On a transcode, the returned video stream is rewritten
  to report the range that is actually delivered: a Dolby Vision source delivered
  as an HDR10/HLG passthrough now reports HDR10/HLG (DV descriptors cleared), and
  a source forced to an HDR→SDR tonemap (see `LIDSLABS_FORCE_SDR_CLIENTS`) now
  reports SDR (`bt709`). Fixes clients (e.g. Moonfin) that read `VideoRangeType`
  to drive tvOS display-mode switching and were engaging Dolby Vision over a
  non-DV transcode → washed-out or wrong-gamut image. Response-only (the file's
  own metadata is untouched); the source still transcodes (direct play unaffected).
- **Moonfin mapped for the force-SDR lever (patch 0014).** Added the `moonfin`
  friendly name to the client map so it can be listed in `LIDSLABS_FORCE_SDR_CLIENTS`.
  Moonfin's mpv render path cannot correctly display an HDR transcode (an upstream
  client limitation), so tonemapping its HDR titles to SDR (HEVC preserved) is the
  correct outcome; combined with patch 0013 the client is told the stream is SDR,
  so it stays out of Dolby Vision / HDR display mode.

### Compatibility
- **Verified end-to-end (2026-07-02/03, on device):**
  - **Neptune Trident** — HEVC HDR10 / DV passthrough unchanged (not force-SDR'd;
    plays HDR on its own path).
  - **Neptune AV Player** — 4K HDR title → clean HEVC **SDR** (forced HEVC + fMP4 +
    `LIDSLABS_FORCE_SDR_CLIENTS=neptune_av`); H264 SDR → HEVC SDR. Screen lights up
    where it previously went black. HDR→SDR is inherent to AVPlayer over HLS.
  - **Swiftfin** — Native Player: HDR direct-plays (HEVC HDR / DV P7 → clean
    HDR10). Default (VLCKit) player: video/audio correct but TV stays SDR (client
    bug; use Native Player).
  - **Moonfin (2026-07-03/04)** — playback restored (was black: server was 400'ing
    its own manifest) and no longer misfires into Dolby Vision: with
    `LIDSLABS_FORCE_SDR_CLIENTS=moonfin`, HDR/DV titles tonemap to clean HEVC **SDR**
    and the client is told the stream is SDR (no DV banner, no HDR pop). HDR→SDR is
    the correct outcome — Moonfin's mpv path can't render an HDR transcode (upstream
    client bug). Recommended for external/bandwidth-limited (always-transcoding) use.
- **Excluded by design:**
  - **Streamyfin** — forced HEVC + HDR→SDR tonemap succeed server-side (correct
    video + AC3 audio encoded) but playback is silent; a client-side audio bug.
    `LIDSLABS_FORCE_SDR_CLIENTS` does not fix it — recheck after the next Streamyfin
    app release.
  - **Swiftfin AV Player mode** — cannot be force-SDR'd: Swiftfin posts an
    identical DeviceProfile (`Name=null`, `client="Jellyfin tvOS"`) for both its
    AVPlayer and Native players, so there is no server-side signal to target only
    the AVPlayer mode. Use Native Player for HDR.

### Documentation
- `README.md`: documented `LIDSLABS_FORCE_SDR_CLIENTS`; updated the
  `LIDSLABS_FORCE_HEVC_CLIENTS` description for source-independent forcing; added
  `neptune_av` to the client mapping and a client-compatibility note (Swiftfin
  Native Player for HDR; AVPlayer-family HDR→SDR).
- `DECISIONS.md`: added the v0.3.2 entries — Enhanced NVDEC coexistence, Swiftfin
  capability corrections, forced-HEVC source-independence, the AVPlayer-family
  HDR-over-HLS / force-SDR rationale, and the Moonfin fixes (self-generated-URL
  400 regex-cap; transcoded `PlaybackInfo` describing the delivered stream).
- `README.md`: noted Moonfin as a supported (SDR) AVPlayer-family client.
- `README.md`: added a **Client compatibility** matrix (per player: HDR result,
  delivered codec, required config) and gave the friendly-name mapping table a
  Lever(s) column so it's clear which names feed forced-HEVC vs forced-SDR.
- `PATCHES.md` (new): the complete change surface — the 5 upstream files touched
  and the per-patch index (0001–0014).

### Pinned to
- Jellyfin upstream tag: `v10.11.11` (unchanged from v0.3.1)
- Runtime base image: `jellyfin/jellyfin:10.11.11`
- Fork commit: see `JELLYFIN_REF`

## [0.3.1+jellyfin-10.11.11] - 2026-06-29

Bug-fix release: eliminates a ~6 s black-screen warmup at the start of
**every** NVENC transcode on Nvidia GPUs newer than jellyfin-ffmpeg's bundled
`scale_cuda` kernels (Blackwell / RTX 50-series, sm_120). **This is a general
Jellyfin-on-Nvidia behavior, not a bug introduced by the lidslabs patches** —
stock `jellyfin/jellyfin` exhibits the same warmup on a new-enough GPU, because
its non-root run user has a non-writable `HOME=/` and the NVIDIA driver can't
persist its CUDA JIT compile, so it redoes the ~6 s compile on every launch.
This image fixes it by pointing the cache at the persistent `/config` volume so
the kernel compiles once, ever. No patch-layer change — same Jellyfin fork
commit as v0.3.0; Dockerfile-only, always on, no configuration required.

### Highlights
- **~6 s faster transcode start on newer Nvidia GPUs (RTX 50-series /
  Blackwell).** First HLS segment measured 9.46 s → 3.52 s on an RTX 5080.
- **One-time cost.** The `scale_cuda` kernel is JIT-compiled once and the
  result persists on the `/config` volume across container restarts.
- **No configuration needed** — the fix is baked into the image and always
  on. Operators with a read-only `/config` can override `CUDA_CACHE_PATH`.
- **Older GPUs unaffected** (their kernels are precompiled; no JIT step).
- **Not a lidslabs bug** — the warmup is inherent to Jellyfin + a non-root user
  + a GPU newer than jellyfin-ffmpeg's bundled kernels; stock Jellyfin hits it
  too. This image just ships the fix. See `README.md` "Faster transcode start".
- **No patch-layer change** — same fork commit and 5-patch series as v0.3.0;
  this is a Dockerfile `ENV` addition only.

### Fixed
- **Faster transcode start on newer GPUs (CUDA JIT cache).** The image now sets
  `CUDA_CACHE_PATH=/config/.cudacache` so the NVIDIA driver's CUDA JIT cache
  persists. This addresses a general Jellyfin-on-Nvidia behavior rather than
  anything specific to the lidslabs patches: on GPU architectures newer than
  jellyfin-ffmpeg's bundled cubins (e.g. Blackwell / RTX 50-series, sm_120), the
  `scale_cuda` kernel is JIT-compiled from PTX (~6 s) at ffmpeg launch; because
  the base `jellyfin/jellyfin` image gives a non-root run user a non-writable
  `HOME=/`, the driver couldn't persist that compile and re-ran it on **every**
  transcode, adding ~6 s of black-screen warmup each time (stock Jellyfin on such
  a GPU sees the same thing). Pointing the cache at the persistent `/config`
  volume makes the compile a one-time cost (survives restarts). Dockerfile-only;
  no patch-layer change. Older GPUs (precompiled kernels, no JIT) are unaffected.
  See `README.md` and `DECISIONS.md`.

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
