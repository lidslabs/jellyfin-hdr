# What jellyfin-hdr changes in Jellyfin

**This fork modifies exactly 7 upstream Jellyfin source files. It adds no new files, and
deletes none.** Everything jellyfin-hdr does to the Jellyfin server is listed below — the
complete change surface, nothing hidden.

The changes ship as a series of small, single-purpose patches in [`patches/`](./patches/),
generated from the [`lidslabs/jellyfin`](https://github.com/lidslabs/jellyfin) fork and applied
in order onto the upstream tag pinned in [`UPSTREAM_VERSION`](./UPSTREAM_VERSION) at build time
(`git am patches/*.patch` — see the [`Dockerfile`](./Dockerfile)). One patch = one feature, so
a single file is touched by several patches as features accumulate; the count of patches is not
the count of files. Because the series is cumulative, a later patch can also *remove* an earlier
feature — the change surface below describes the **current (shipped) state**, and the patch index
notes where a feature was added and later dropped. For how the two-repo build fits together, see
[README → Source and provenance](./README.md#source-and-provenance).

Two views of the same work follow: **[the 7 files](#the-7-files)** (what changed, per file —
start here) and **[the patch index](#patch-index)** (the per-patch appendix, for provenance).

---

## The 7 files

Listed most-changed first. Each entry is the full footprint on that file; bracketed tags like
`[0001]` point to the [patch index](#patch-index) below.

### 1. `MediaBrowser.Controller/MediaEncoding/EncodingHelper.cs`
*Upstream: builds the ffmpeg transcode command line. This is where HDR is preserved instead of
tonemapped.*

- **HDR passthrough transcode** — keeps HDR10 / HDR10+ / HLG (and Dolby Vision with a usable
  HDR10/HLG base) through NVENC in 10-bit BT.2020/PQ instead of tonemapping to SDR; gated behind
  the `LIDSLABS_ALLOW_HDR_TRANSCODE` env var (off by default). Includes the filter-graph routing
  that forces 10-bit pixel formats, plus a sw-decode widening for the DV Profile 7 + subtitle
  burn-in path. [0001]
- **AC3 audio-compatibility redirect** — substitutes an AC3 sidecar track when a source's audio
  can't play, on both HLS and Progressive transcodes. [0003]
- **Env-var namespace** — the gate/feature env vars were renamed into the `LIDSLABS_` namespace. [0004]
- **Enhanced-NVDEC × HDR coexistence** — omits `-hwaccel_flags +unsafe_output` when the enhanced
  native NVDEC decoder feeds an HDR-passthrough graph, fixing a `CUDA_ERROR_MAP_FAILED` crash;
  fires only for that exact failing combination. [0006]
- **HEVC Level 5.1 advertisement** for 2160p HLS transcode. [0010]
- **HEVC Main-tier / level pin (HDR passthrough)** — pins `-tier:v main -level:v` so the NVENC
  output matches the advertised HLS CODECS string; AVPlayer refuses a tier/level mismatch. [0016]
- **HDR seek/resume timestamp fix** — the HDR path no longer uses `-avoid_negative_ts make_zero`
  (a stale MPEG-TS assumption that reset an fMP4 seek segment's timeline); it uses stock
  `disabled`. Also keeps the honor-explicit-SDR-request gate that now backs the SDR ladder. [0017] [0019]
- **Container-validation regex cap 40 → 80** — widens `ContainerValidationRegexStr` so the
  server's own generated `master.m3u8` codec list stops failing model validation with a 400. [0012]

### 2. `Jellyfin.Api/Controllers/MediaInfoController.cs`
*Upstream: answers the client's `PlaybackInfo` request (what to direct-play vs. transcode, and
how). This is where per-client codec/range decisions are steered.*

- **Forced-HEVC override** — for listed HDR-capable clients, prepends `hevc` to the transcoding
  profile so HEVC is chosen over a client-listed H.264. [0002] Later made source-independent
  (fires regardless of the HDR toggle) [0008] and extended to the Neptune AV Player. [0009]
  Swiftfin is an opt-in member of this lever (`swiftfin`). [0015]
- **Eligibility diagnostic log** — the gate-decision breadcrumb moved to `Debug`. [0005]
- **Env-var namespace** — `LIDSLABS_` rename touch. [0004]
- **Swiftfin (Apple TV) handling** — the client-name gate is pinned to `"Swiftfin tvOS"` (the
  v1.5 App Store rename) and Swiftfin gets stock range handling; the earlier TrueHD/DV7-strip and
  forced-transcode corrections were dropped after on-device testing. [0007] [0015]
- **SDR-ladder eligibility marker** — for the Apple AVPlayer allowlist
  (`LIDSLABS_SDR_LADDER_CLIENTS`), tags the transcode's `TranscodingUrl` so the HLS master adds an
  SDR companion rung (see file 4). Decided here because the client name and `DeviceProfile.Name`
  are both reliable at PlaybackInfo. [0020]
- **Delivered-range rewrite** — rewrites a transcoded source's returned video stream to describe
  the *delivered* stream (HDR10/HLG), not the source's DV descriptors, so clients don't re-engage
  Dolby Vision over a stream that isn't DV. [0013]
- *(Removed in v0.3.3)* The **force-SDR lever** (`LIDSLABS_FORCE_SDR_CLIENTS`, a per-client
  HDR→SDR tonemap) and its Moonfin client-map arm were added in v0.3.2 [0011] [0014] and removed
  once the SDR ladder superseded them. [0019]

### 3. `Jellyfin.Api/Helpers/DynamicHlsHelper.cs`
*Upstream: assembles the HLS playlist (`master.m3u8`).*

- **HLS manifest colorspace tagging** — emits `VIDEO-RANGE=PQ / HLG / SDR` to match the actual
  output bitstream, plus Dolby Vision HLS codec-string handling. [0001]
- **H.264 SDR companion rung** — on an HDR-passthrough master, adds a tonemapped-SDR variant so
  Apple AVPlayer clients will commit to the master and select the HDR variant. Fires only for the
  allowlist marked upstream in file 2. [0020]

### 4. `Jellyfin.Api/Controllers/DynamicHlsController.cs`
*Upstream: serves the HLS playlist and segment requests.*

- **Manifest-tagging plumbing** — controller-side support for the `VIDEO-RANGE` tagging above,
  including AC3 / E-AC3 codec-string emission. Treated as a unit with file 3. [0001]
- **Seek/resume timestamp fix** — pairs with the EncodingHelper change [0017] on the segment path
  so strict fMP4 players (AVPlayer, mpv) don't stall on seek/resume. [0017]

### 5. `Jellyfin.Api/Helpers/StreamingHelpers.cs`
*Upstream: builds streaming state, including the transcode output file path.*

- **Codec-keyed transcode output path** — folds the output video/audio codec into the output-path
  hash so a session advertising both an HDR (hevc) and an SDR-companion (h264) variant no longer
  hashes both to the same files (which clobbered each other's fMP4 init segment and broke AVPlayer
  seeks). [0018]

### 6. `Jellyfin.Api/Helpers/HlsCodecStringHelpers.cs`
*Upstream: builds RFC 6381 HLS codec strings.*

- **HEVC Main-tier codec string** — emits the Main-tier (`L`) token to match the pinned encoder
  tier (file 1, [0016]), so the advertised `hvc1.2.4.L1xx.B0` agrees with the bitstream. [0016]

### 7. `MediaBrowser.Controller/MediaEncoding/EncodingJobInfo.cs`
*Upstream: carries the state of an in-flight transcode job.*

- **`IsHdrTranscoding` convenience property** — a pure delegate to `IsHdrPassthroughMode` in
  file 1 (no separate logic); plus the `LIDSLABS_` env rename touch. [0001] [0004]

---

## Patch index

The per-patch (per-fork-commit) appendix — provenance for the file view above. Each patch is a
single, revertible feature; `Details` links to the public rationale in
[`DECISIONS.md`](./DECISIONS.md) or [`CHANGELOG.md`](./CHANGELOG.md).

| Patch | Feature | File(s) | Since | Details |
|-------|---------|---------|-------|---------|
| [0001](./patches/0001-lidslabs-HDR-transcode-patches.patch) | HDR10/HDR10+/HLG passthrough transcode core + HLS `VIDEO-RANGE` manifest tagging | EncodingHelper, EncodingJobInfo, DynamicHlsHelper, DynamicHlsController | v0.1.0 | [README](./README.md#hdr-transcoding) |
| [0002](./patches/0002-lidslabs-v0.3-force-HEVC-transcode-for-HDR-capable-c.patch) | Forced-HEVC override for HDR-capable clients | MediaInfoController | v0.3.0 | [DECISIONS](./DECISIONS.md) |
| [0003](./patches/0003-lidslabs-v0.3-widen-audio-compat-redirect-to-HLS-or-.patch) | AC3 audio-compat redirect widened to HLS + Progressive | EncodingHelper | v0.3.0 | [DECISIONS](./DECISIONS.md) |
| [0004](./patches/0004-lidslabs-v0.3-rename-env-vars-to-LIDSLABS_-namespace.patch) | Rename env vars to `LIDSLABS_` namespace | EncodingHelper, EncodingJobInfo, MediaInfoController | v0.3.0 | [CHANGELOG](./CHANGELOG.md) |
| [0005](./patches/0005-lidslabs-v0.3-gate-decision-diagnostic-log-Debug-for.patch) | Gate the eligibility diagnostic log to Debug | MediaInfoController | v0.3.0 | [DECISIONS](./DECISIONS.md) |
| [0006](./patches/0006-lidslabs-v0.3.2-drop-enhanced-NVDEC-unsafe_output-fo.patch) | Drop enhanced-NVDEC `+unsafe_output` under HDR (CUDA_ERROR_MAP_FAILED fix) | EncodingHelper | v0.3.2 | [DECISIONS](./DECISIONS.md#enhanced-nvdec-coexistence--keep-hdr-working-with-the-decoder-default-on) |
| [0007](./patches/0007-lidslabs-v0.3.2-correct-Swiftfin-s-over-claimed-Appl.patch) | Correct Swiftfin's over-claimed Apple profile | MediaInfoController | v0.3.2 | [CHANGELOG](./CHANGELOG.md) |
| [0008](./patches/0008-lidslabs-v0.3.2-forced-HEVC-source-independent-decou.patch) | Make forced-HEVC source-independent (decouple from HDR toggle) | MediaInfoController | v0.3.2 | [CHANGELOG](./CHANGELOG.md) |
| [0009](./patches/0009-lidslabs-v0.3.2-enable-forced-HEVC-for-Neptune-AV-Pl.patch) | Enable forced HEVC + fMP4 for Neptune AV Player | MediaInfoController | v0.3.2 | [CHANGELOG](./CHANGELOG.md) |
| [0010](./patches/0010-lidslabs-v0.3.2-advertise-HEVC-Level-5.1-for-2160p-H.patch) | Advertise HEVC Level 5.1 for 2160p transcode | EncodingHelper | v0.3.2 | [CHANGELOG](./CHANGELOG.md) |
| [0011](./patches/0011-lidslabs-v0.3.2-force-listed-clients-back-to-SDR-LID.patch) | Force-SDR lever for AVPlayer-family clients *(removed in 0019)* | EncodingHelper, MediaInfoController | v0.3.2 | [CHANGELOG](./CHANGELOG.md) |
| [0012](./patches/0012-lidslabs-v0.3.2-widen-ContainerValidationRegexStr-40.patch) | Widen `ContainerValidationRegexStr` 40→80 (Moonfin master.m3u8 400 fix) | EncodingHelper | v0.3.2 | [CHANGELOG](./CHANGELOG.md) |
| [0013](./patches/0013-lidslabs-v0.3.2-report-the-delivered-range-not-the-s.patch) | Report delivered range, not source, in transcoded PlaybackInfo | MediaInfoController | v0.3.2 | [CHANGELOG](./CHANGELOG.md) |
| [0014](./patches/0014-lidslabs-v0.3.2-map-Moonfin-client-for-the-force-SDR.patch) | Map Moonfin client into the force-SDR lever *(removed in 0019)* | MediaInfoController | v0.3.2 | [CHANGELOG](./CHANGELOG.md) |
| [0015](./patches/0015-lidslabs-v0.3.3-Swiftfin-tvOS-v1.5-two-engine-handli.patch) | Swiftfin tvOS v1.5 handling: client-name fix, stock ranges, opt-in force-HEVC | MediaInfoController | v0.3.3 | [CHANGELOG](./CHANGELOG.md) |
| [0016](./patches/0016-lidslabs-v0.3.3-pin-HEVC-HDR-passthrough-to-Main-tie.patch) | Pin HEVC HDR passthrough to Main tier + matching codec string | EncodingHelper, HlsCodecStringHelpers | v0.3.3 | [DECISIONS](./DECISIONS.md#sdr-companion-rung--an-hdr-ladder-for-avplayer-not-a-forced-tonemap) |
| [0017](./patches/0017-lidslabs-v0.3.3-fix-HLS-seek-resume-for-HDR-passthro.patch) | Fix HLS seek/resume for HDR passthrough (`make_zero` → `disabled`) | EncodingHelper, DynamicHlsController | v0.3.3 | [CHANGELOG](./CHANGELOG.md) |
| [0018](./patches/0018-lidslabs-v0.3.3-key-transcode-output-path-on-codec-f.patch) | Key the transcode output path on codec (fix AVPlayer seek init collision) | StreamingHelpers | v0.3.3 | [CHANGELOG](./CHANGELOG.md) |
| [0019](./patches/0019-lidslabs-v0.3.3-remove-the-force-SDR-clients-lever.patch) | Remove the force-SDR lever (superseded by the SDR ladder) | EncodingHelper, MediaInfoController | v0.3.3 | [DECISIONS](./DECISIONS.md#sdr-companion-rung--an-hdr-ladder-for-avplayer-not-a-forced-tonemap) |
| [0020](./patches/0020-lidslabs-v0.3.3-add-H.264-SDR-companion-rung-for-AVP.patch) | Add H.264 SDR companion rung for AVPlayer clients | DynamicHlsHelper, MediaInfoController | v0.3.3 | [DECISIONS](./DECISIONS.md#sdr-companion-rung--an-hdr-ladder-for-avplayer-not-a-forced-tonemap) |

> Patch numbers are assigned by fork-commit order and can renumber when the series is
> regenerated. This index is kept in sync at release time; see the release workflow.
