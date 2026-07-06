# What jellyfin-hdr changes in Jellyfin

**This fork modifies exactly 5 upstream Jellyfin source files. It adds no new files, and
deletes none.** Everything jellyfin-hdr does to the Jellyfin server is listed below — the
complete change surface, nothing hidden.

The changes ship as a series of small, single-purpose patches in [`patches/`](./patches/),
generated from the [`lidslabs/jellyfin`](https://github.com/lidslabs/jellyfin) fork and applied
in order onto the upstream tag pinned in [`UPSTREAM_VERSION`](./UPSTREAM_VERSION) at build time
(`git am patches/*.patch` — see the [`Dockerfile`](./Dockerfile)). One patch = one feature, so
a single file is touched by several patches as features accumulate; the count of patches is not
the count of files. For how the two-repo build fits together, see
[README → Source and provenance](./README.md#source-and-provenance).

Two views of the same work follow: **[the 5 files](#the-5-files)** (what changed, per file —
start here) and **[the patch index](#patch-index)** (the per-patch appendix, for provenance).

---

## The 5 files

Listed most-changed first. Each entry is the full footprint on that file; bracketed tags like
`[0001]` point to the [patch index](#patch-index) below.

### 1. `MediaBrowser.Controller/MediaEncoding/EncodingHelper.cs`
*Upstream: builds the ffmpeg transcode command line. This is where HDR is preserved instead of
tonemapped.*

- **HDR passthrough transcode** — keeps HDR10 / HDR10+ / HLG (and Dolby Vision with a usable
  HDR10/HLG base) through NVENC in 10-bit BT.2020/PQ instead of tonemapping to SDR; the whole
  behavior is gated behind the `LIDSLABS_ALLOW_HDR_TRANSCODE` env var (off by default). Includes
  the filter-graph routing that forces 10-bit pixel formats, plus a sw-decode widening for the
  DV Profile 7 + subtitle burn-in path. [0001]
- **AC3 audio-compatibility redirect** — substitutes an AC3 sidecar track when a source's audio
  can't play, on both HLS and Progressive transcodes. [0003]
- **Env-var namespace** — the gate/feature env vars were renamed into the `LIDSLABS_` namespace. [0004]
- **Enhanced-NVDEC × HDR coexistence** — omits `-hwaccel_flags +unsafe_output` when the enhanced
  native NVDEC decoder feeds an HDR-passthrough graph, fixing a `CUDA_ERROR_MAP_FAILED` crash;
  fires only for that exact failing combination. [0006]
- **HEVC Level 5.1 advertisement** for 2160p HLS transcode. [0010]
- **Force-SDR lever (encode side)** — supports forcing HDR→SDR tonemap output for clients that
  can't ingest HDR-over-HLS (paired with the PlaybackInfo-side lever in file 2). [0011]
- **Container-validation regex cap 40 → 80** — widens `ContainerValidationRegexStr` so the
  server's own generated `master.m3u8` codec list stops failing model validation with a 400
  (the Moonfin black-screen fix). One-line const change, same charset. [0012]

### 2. `Jellyfin.Api/Controllers/MediaInfoController.cs`
*Upstream: answers the client's `PlaybackInfo` request (what to direct-play vs. transcode, and
how). This is where per-client codec/range decisions are steered.*

- **Forced-HEVC override** — for listed HDR-capable clients, prepends `hevc` to the transcoding
  profile so HEVC is chosen over a client-listed H.264. [0002] Later made source-independent
  (fires regardless of the HDR toggle, so SDR sources transcode too) [0008] and extended to the
  Neptune AV Player (forced HEVC + fMP4). [0009]
- **Eligibility diagnostic log** — the gate-decision breadcrumb was moved to `Debug` level. [0005]
- **Env-var namespace** — `LIDSLABS_` rename touch. [0004]
- **Swiftfin (Apple TV) profile corrections** — three targeted fixes to the profile Swiftfin
  over-claims: strip the TrueHD family so it can't direct-play to silence, inject an HEVC
  CodecProfile that fails DV Profile 7 (clean HDR10 copy, no re-encode), and force fMP4/CMAF HLS
  segments so Apple AVPlayer can decode HEVC. Always-on, self-deactivating, no env var. [0007]
- **Force-SDR lever (PlaybackInfo side)** — for `LIDSLABS_FORCE_SDR_CLIENTS`, prepends an
  `hevc` CodecProfile with `VideoRangeType=SDR`, making HDR a direct-play disqualifier so the
  title transcodes with an HDR→SDR tonemap. [0011]
- **Delivered-range rewrite** — rewrites the returned video stream of a transcoded source to
  describe the *delivered* stream (e.g. HDR10 or SDR), not the source's DV descriptors, so
  clients don't re-engage Dolby Vision over a stream that isn't DV. [0013]
- **Client map** — adds the Moonfin arm so it can be listed for the force-SDR lever. [0014]

### 3. `MediaBrowser.Controller/MediaEncoding/EncodingJobInfo.cs`
*Upstream: carries the state of an in-flight transcode job.*

- **`IsHdrTranscoding` convenience property** — a pure delegate to `IsHdrPassthroughMode` in
  file 1 (no separate logic); plus the `LIDSLABS_` env rename touch. [0001] [0004]

### 4. `Jellyfin.Api/Helpers/DynamicHlsHelper.cs`
*Upstream: assembles the HLS playlist (`master.m3u8`).*

- **HLS manifest colorspace tagging** — emits `VIDEO-RANGE=PQ / HLG / SDR` to match the actual
  output bitstream (stock Jellyfin declares SDR while the bitstream carries BT.2020/PQ, breaking
  some players), plus Dolby Vision HLS codec-string handling. [0001]

### 5. `Jellyfin.Api/Controllers/DynamicHlsController.cs`
*Upstream: serves the HLS playlist and segment requests.*

- **Manifest-tagging plumbing** — the controller-side support for the `VIDEO-RANGE` tagging
  above, including AC3 / E-AC3 codec-string emission. Treated as a unit with file 4. [0001]

---

## Patch index

The per-patch (per-fork-commit) appendix — provenance for the file view above. Each patch is a
single, revertible feature; `Details` links to the public rationale in
[`DECISIONS.md`](./DECISIONS.md) or [`CHANGELOG.md`](./CHANGELOG.md).

| Patch | Feature | File(s) | Since | Details |
|-------|---------|---------|-------|---------|
| [0001](./patches/0001-lidslabs-HDR-transcode-patches.patch) | HDR10/HDR10+/HLG passthrough transcode core + HLS `VIDEO-RANGE` manifest tagging | EncodingHelper, EncodingJobInfo, DynamicHlsHelper, DynamicHlsController | v0.1.0 | [README](./README.md#hdr-transcoding) |
| [0002](./patches/0002-lidslabs-v0.3-force-HEVC-transcode-for-HDR-capable-c.patch) | Forced-HEVC override for HDR-capable clients | MediaInfoController | v0.3.0 | [DECISIONS](./DECISIONS.md#v030--forced-hevc-override-for-hdr-capable-apple-tv-clients) |
| [0003](./patches/0003-lidslabs-v0.3-widen-audio-compat-redirect-to-HLS-or-.patch) | AC3 audio-compat redirect widened to HLS + Progressive | EncodingHelper | v0.3.0 | [DECISIONS](./DECISIONS.md#v030--audio-compatibility-redirect-widened-to-progressive) |
| [0004](./patches/0004-lidslabs-v0.3-rename-env-vars-to-LIDSLABS_-namespace.patch) | Rename env vars to `LIDSLABS_` namespace | EncodingHelper, EncodingJobInfo, MediaInfoController | v0.3.0 | [CHANGELOG](./CHANGELOG.md) |
| [0005](./patches/0005-lidslabs-v0.3-gate-decision-diagnostic-log-Debug-for.patch) | Gate the eligibility diagnostic log to Debug | MediaInfoController | v0.3.0 | [DECISIONS](./DECISIONS.md#v030--forced-hevc-override-for-hdr-capable-apple-tv-clients) |
| [0006](./patches/0006-lidslabs-v0.3.2-drop-enhanced-NVDEC-unsafe_output-fo.patch) | Drop enhanced-NVDEC `+unsafe_output` under HDR (CUDA_ERROR_MAP_FAILED fix) | EncodingHelper | v0.3.2 | [DECISIONS](./DECISIONS.md#enhanced-nvdec-coexistence--keep-hdr-working-with-the-decoder-default-on) |
| [0007](./patches/0007-lidslabs-v0.3.2-correct-Swiftfin-s-over-claimed-Appl.patch) | Correct Swiftfin's over-claimed Apple profile (TrueHD strip, DV7 strip, fMP4) | MediaInfoController | v0.3.2 | [DECISIONS](./DECISIONS.md#swiftfin-apple-tv--correct-the-deviceprofile-it-over-claims) |
| [0008](./patches/0008-lidslabs-v0.3.2-forced-HEVC-source-independent-decou.patch) | Make forced-HEVC source-independent (decouple from HDR toggle) | MediaInfoController | v0.3.2 | [DECISIONS](./DECISIONS.md#forced-hevc-is-a-codec-preference-lever-independent-of-the-hdr-path) |
| [0009](./patches/0009-lidslabs-v0.3.2-enable-forced-HEVC-for-Neptune-AV-Pl.patch) | Enable forced HEVC + fMP4 for Neptune AV Player | MediaInfoController | v0.3.2 | [DECISIONS](./DECISIONS.md#neptune-av-player--supported-via-forced-hevc--fmp4--forced-sdr) |
| [0010](./patches/0010-lidslabs-v0.3.2-advertise-HEVC-Level-5.1-for-2160p-H.patch) | Advertise HEVC Level 5.1 for 2160p transcode | EncodingHelper | v0.3.2 | [CHANGELOG](./CHANGELOG.md) |
| [0011](./patches/0011-lidslabs-v0.3.2-force-listed-clients-back-to-SDR-LID.patch) | Force-SDR lever for AVPlayer-family clients | EncodingHelper, MediaInfoController | v0.3.2 | [DECISIONS](./DECISIONS.md#avplayer-family-clients-cant-ingest-hdr-over-hls--force-them-to-sdr) |
| [0012](./patches/0012-lidslabs-v0.3.2-widen-ContainerValidationRegexStr-40.patch) | Widen `ContainerValidationRegexStr` 40→80 (Moonfin master.m3u8 400 fix) | EncodingHelper | v0.3.2 | [DECISIONS](./DECISIONS.md#moonfin--supported-sdr-and-a-self-generated-manifest-url-that-400d) |
| [0013](./patches/0013-lidslabs-v0.3.2-report-the-delivered-range-not-the-s.patch) | Report delivered range, not source, in transcoded PlaybackInfo | MediaInfoController | v0.3.2 | [DECISIONS](./DECISIONS.md#transcoded-playbackinfo-describes-the-delivered-stream-not-the-source) |
| [0014](./patches/0014-lidslabs-v0.3.2-map-Moonfin-client-for-the-force-SDR.patch) | Map Moonfin client into the force-SDR lever | MediaInfoController | v0.3.2 | [DECISIONS](./DECISIONS.md#moonfin--supported-sdr-and-a-self-generated-manifest-url-that-400d) |

> Patch numbers are assigned by fork-commit order and can renumber when the series is
> regenerated. This index is kept in sync at release time; see the release workflow.
