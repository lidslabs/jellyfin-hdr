# jellyfin-hdr

Custom Jellyfin Docker image with HDR10 / HDR10+ / HLG transcode passthrough
and Dolby Vision Profile 7 + subtitle burn-in support via CUDA / NVENC on
Nvidia GPUs (RTX 30-series and later recommended).

Built on top of [`jellyfin/jellyfin`](https://github.com/jellyfin/jellyfin).
Patches are maintained in the [`lidslabs/jellyfin`](https://github.com/lidslabs/jellyfin)
fork on the `lidslabs/<upstream-minor>.x` integration branch (currently
`lidslabs/10.11.x`); each release's exact source commit is pinned in
[`JELLYFIN_REF`](./JELLYFIN_REF) and tagged `jellyfin-hdr/vX.Y.Z` in the fork.
This repo packages those patches into immutable images published to ghcr.io.

## Pull

```sh
docker pull ghcr.io/lidslabs/jellyfin-hdr:latest
```

Specific version (recommended for production):

```sh
docker pull ghcr.io/lidslabs/jellyfin-hdr:v0.3.0-jellyfin-10.11.11
```

Note the dash separator: git tags use `+` (semver build metadata), Docker image
tags substitute `-` because `+` is not a valid Docker tag character.

## Configuration

> [!IMPORTANT]
> Every custom feature in this image is **off by default** — out of the box it
> behaves exactly like stock Jellyfin. You must set environment variables to turn
> the lidslabs behavior on. At minimum, set **`LIDSLABS_ALLOW_HDR_TRANSCODE=1`**;
> without it, none of the HDR or forced-HEVC features engage.

| Variable | Default | Enables | Notes |
| --- | --- | --- | --- |
| `LIDSLABS_ALLOW_HDR_TRANSCODE` | `0` | **HDR passthrough master toggle** | Accepts `1` or `true` (case-insensitive). Turns on HDR10 / HDR10+ / HLG passthrough during transcode. Governs the HDR path only — the forced-HEVC and forced-SDR client levers below are independent of it. |
| `LIDSLABS_FORCE_HEVC_CLIENTS` | _(unset)_ | Forced-HEVC override | Comma-separated friendly client names to force onto an HEVC transcode (e.g. `neptune,streamyfin,neptune_av`). Fires for **any** source, SDR or HDR — an H264 SDR remux becomes HEVC SDR. Independent of the master toggle; only ever forces a codec the client already advertises. See [Forced HEVC for HDR-capable clients](#forced-hevc-for-hdr-capable-clients). |
| `LIDSLABS_FORCE_SDR_CLIENTS` | _(unset)_ | Forced HDR→SDR tonemap | Comma-separated friendly client names whose HDR titles are tonemapped to SDR (codec stays HEVC) instead of HDR passthrough. For AVPlayer-family Apple TV clients that reject `VIDEO-RANGE=PQ` and black-screen on HDR-over-HLS (e.g. `neptune_av`). Only meaningful when the master toggle is on. See [AVPlayer clients and HDR](#avplayer-clients-and-hdr). |

These two variables are the only *feature toggles* this image adds. The image
also sets `CUDA_CACHE_PATH=/config/.cudacache` so the GPU's CUDA JIT cache
persists (see [Faster transcode start](#faster-transcode-start)); everything else
is stock Jellyfin plus the standard NVIDIA runtime variables. NVENC/CUDA requires the
[NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
on the host, and HEVC hardware encoding enabled in
**Dashboard → Playback → Transcoding** (Hardware acceleration → NVENC).

### Sample `docker-compose.yml`

A copyable version lives at [`docker-compose.example.yml`](./docker-compose.example.yml).

```yaml
services:
  jellyfin:
    image: ghcr.io/lidslabs/jellyfin-hdr:v0.3.0-jellyfin-10.11.11
    container_name: jellyfin
    restart: unless-stopped
    # GPU via the NVIDIA Container Toolkit (Compose device reservation):
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ["0"]     # pin a GPU; or use `count: all`
              capabilities: [gpu]
    environment:
      # --- lidslabs custom (see the table above) ---
      LIDSLABS_ALLOW_HDR_TRANSCODE: "1"                    # HDR passthrough master toggle
      LIDSLABS_FORCE_HEVC_CLIENTS: "neptune,streamyfin,neptune_av" # optional; forced-HEVC override
      LIDSLABS_FORCE_SDR_CLIENTS: "neptune_av"             # optional; HDR->SDR for AVPlayer clients
      # --- NVENC capabilities exposed to the container ---
      NVIDIA_DRIVER_CAPABILITIES: "compute,video,utility"
      TZ: America/New_York
    ports:
      - "8096:8096"
    volumes:
      - ./config:/config
      - ./cache:/cache
      - /path/to/media:/media        # rw: Jellyfin writes posters / NFO / trickplay alongside media
```

> **Pin a specific version tag** (as above) rather than `:latest`. This image
> ships breaking changes between minor versions — e.g. v0.3.0 renamed
> `JELLYFIN_ALLOW_HDR_TRANSCODE`, which silently disables HDR if your compose
> still uses the old name. `:latest` exists and auto-updates on `compose pull`,
> but only use it if you watch the [release notes](https://github.com/lidslabs/jellyfin-hdr/releases)
> and update env vars before upgrading. The image tag uses `-` where the git tag
> uses `+` (Docker doesn't allow `+` in tags).

### Forced HEVC for HDR-capable clients

Some HDR-capable clients (notably Apple TV apps) advertise HEVC support but
request an h264 transcode, so HEVC's efficiency — and, on HDR sources, HDR
itself — never reaches the screen. When `LIDSLABS_FORCE_HEVC_CLIENTS` lists a
client, this image rewrites the request to HEVC. It fires for **any** source:
an HDR title engages the HDR passthrough path, and an SDR remux is simply
re-encoded to HEVC SDR (e.g. a 40 Mbps H264 remux → ~20 Mbps HEVC) rather than
back to H264. It only ever forces a codec the client's own profile already
advertises, and it's independent of the HDR master toggle.

Clients are matched by **friendly name → `DeviceProfile.Name`** mapping, not by
User-Agent (one app can expose several player modes under the same UA):

| Friendly name | Matches client mode |
| --- | --- |
| `neptune` | Neptune (Trident player) |
| `streamyfin` | Streamyfin (MPV player) |
| `neptune_av` | Neptune (AV Player) — pair with `LIDSLABS_FORCE_SDR_CLIENTS`, see below |

Names not in the table are silently ignored. Adding a new client is a code change
(a reviewable mapping entry), not just an env var edit — by design, so only
verified-working client modes get the override.

This list is a workaround, not a permanent feature, and is expected to **shrink
over time**: a client only belongs here while it mis-declares its codec
preference. Once it requests HEVC HDR by default (as Swiftfin and Wholphin
already do), it should be removed — the standard HDR passthrough then handles it
without the override.

### AVPlayer clients and HDR

Apple's **AVPlayer** engine — used by Neptune **AV Player** and by Swiftfin's
default (VLCKit/AVPlayer) path — **cannot ingest an HDR-over-HLS stream.** It
rejects the HLS master playlist's `VIDEO-RANGE=PQ` at parse time and never
requests a segment, so an HDR title transcoded with passthrough on shows a
**black screen** even though the client advertises HEVC HDR10.

`LIDSLABS_FORCE_SDR_CLIENTS` handles this: for a listed client, an HDR source is
**tonemapped to SDR** while the transcode stays HEVC (a colour-range downgrade,
not a codec change — efficiency is retained). The client then accepts the
playlist and renders. HDR→SDR is inherent to AVPlayer over HLS, not a limitation
this image can remove; SDR that plays beats HDR that black-screens.

- **Neptune AV Player** — supported: set `neptune_av` in **both**
  `LIDSLABS_FORCE_HEVC_CLIENTS` (it only ever requests h264) and
  `LIDSLABS_FORCE_SDR_CLIENTS`. 4K HDR titles render as clean HEVC SDR.
- **Swiftfin** — for HDR, use Swiftfin's **Native Player**; its default engine
  doesn't trigger the TV's HDR mode. Swiftfin isn't added to
  `LIDSLABS_FORCE_SDR_CLIENTS` because it posts an identical profile for both its
  players, so there's no way to target only the AVPlayer mode without also
  degrading the working Native-Player HDR path.

The list is inert on SDR sources (nothing to tonemap) and, like the forced-HEVC
list, should shrink as clients gain real HDR-over-HLS support.

## Faster transcode start

When a transcode begins, the client shows a black screen until the first frame
arrives. On newer GPUs that window can be ~6 s longer than it should be — and the
cause is a CUDA caching gap, not the transcode itself.

**Who hits this:** the slowdown needs a specific combination — an **Nvidia GPU
transcode** *and* a compose that runs **Jellyfin as a non-root user** (e.g.
`user: 1000:1000`, which is the recommended setup) *and* a **GPU newer than
jellyfin-ffmpeg's bundled kernels** (RTX 50-series / Blackwell today). If that's
you, you were doing everything right — the combination is what triggers it, and
**this image ships the fix.** Drop any one factor (older GPU, or running as root)
and you'd never have seen it.

jellyfin-ffmpeg's CUDA scaling kernel (`scale_cuda`, used on the HDR/NVENC path)
ships precompiled for a set of GPU architectures. On an architecture newer than
that set (e.g. Nvidia **Blackwell / RTX 50-series, sm_120**), the driver instead
JIT-compiles the kernel from PTX at launch — about 6 seconds. Normally that result
is cached in the driver's compute cache so it only happens once. But the base
image gives a non-root run user (`user: 1000:1000`) `HOME=/`, which isn't
writable, so the driver can't write its default `~/.nv/ComputeCache` — and the
~6 s recompile happens on **every** transcode start.

This image sets **`CUDA_CACHE_PATH=/config/.cudacache`**, pointing the JIT cache
at the persistent `/config` volume. The kernel is then compiled **once, ever**
(it survives restarts), and subsequent transcodes start ~6 s sooner. The cache is
~6 MB and write-once, so there's no meaningful disk wear. It's always on and
needs no configuration; operators with a read-only `/config` can override
`CUDA_CACHE_PATH` to another writable, persistent path. Older GPUs whose kernels
ship precompiled never hit the JIT and are unaffected either way.

## HDR transcoding

With the master toggle on, HDR10 / HDR10+ / HLG sources transcoded to HEVC or
AV1 retain their HDR metadata end-to-end (default-off behavior is stock
Jellyfin's tonemap-to-SDR). Dolby Vision Profile 7 sources are converted to
HDR10 on the fly (the Dolby Vision RPU/EL is dropped; the BL is genuine HDR10).

## Audio compatibility-track redirect

When Jellyfin would normally transcode a lossless audio track (TrueHD, DTS-HD MA,
FLAC, etc.) to AAC during a transcoded stream, this build first checks whether
the file contains a separate lossy surround track in the same language. If one
is found, the stream is redirected to that track and stream-copied untouched —
no audio re-encoding.

This applies **only during transcoding**. Direct play is untouched. Files
without an eligible candidate track transcode normally.

### Redirect criteria

The redirect fires only when *all* of these hold:

1. The audio track is being transcoded (not direct-played).
2. The requested track has a language tag (no guessing).
3. The file contains another audio track that:
   - Matches the requested track's language
   - Is AC3 or E-AC3
   - Has ≥6 channels
   - Passes Jellyfin's `CanStreamCopyAudio` check

If multiple tracks match, the one with the lowest stream index wins.

### Diagnostics

The redirect is silent — there is no log entry when it fires. To verify
behavior on a specific file, compare the requested `AudioStreamIndex`
(visible in Jellyfin's playback session log) against the `-map 0:N` audio
argument in the ffmpeg command. If they differ, the redirect fired and the
audio codec line should show `-codec:a:0 copy` rather than `libfdk_aac`.

### Rationale

4K UHD remuxes typically default to a lossless audio track. Most remote clients
can play AC3 or E-AC3 5.1 directly; transcoding the lossless track to 
AAC can throw away surround information unnecessarily when an existing 5.1
compatibility track is already in the file. Stream-copying that track
preserves the surround mix without re-encoding.

### Current status

The feature is always-on in this release. A future release is planned to add
a Jellyfin admin UI toggle (and an env var fallback like `LIDSLABS_ALLOW_HDR_TRANSCODE`)
so it can be opted out of per-server. 

## Source and provenance

- Patches (build input): [`patches/`](./patches/) - regenerated from the fork at release time
- Pinned fork commit SHA: see [`JELLYFIN_REF`](./JELLYFIN_REF) — the immutable source of this release's patches
- Fork pin tag: each release's source commit is tagged `jellyfin-hdr/vX.Y.Z` in the [`lidslabs/jellyfin`](https://github.com/lidslabs/jellyfin/tags) fork
- Integration branch (where the patches are maintained): `lidslabs/10.11.x` in the fork
- Pinned upstream version: see [`UPSTREAM_VERSION`](./UPSTREAM_VERSION)
- Lidslabs patch layer version: see [`VERSION`](./VERSION)

Each built image embeds a `/BUILD_INFO` file. The official Jellyfin base
image has an entrypoint, so override it to read the file:

```sh
docker run --rm --entrypoint cat ghcr.io/lidslabs/jellyfin-hdr:latest /BUILD_INFO
```

## Build

CI builds and publishes to ghcr.io on every `v*` tag push. See
[`.github/workflows/build-and-push.yml`](.github/workflows/build-and-push.yml).

To cut a release locally: edit `VERSION` (and `UPSTREAM_VERSION` / `JELLYFIN_REF`
if upstream changed), commit, then run `./scripts/release.sh`.

## Reporting issues

Bugs, regressions, and questions: open a GitHub issue. See [`SECURITY.md`](./SECURITY.md)
for security-specific reports.

## License

This repository (Dockerfile, build infrastructure, patches) is licensed under
GPL-2.0-only, matching upstream Jellyfin. Patches are derivative works of
Jellyfin's GPLv2 source and inherit that license accordingly.

- This repo: see [`LICENSE`](./LICENSE)
- Upstream Jellyfin: [LICENSE on jellyfin/jellyfin](https://github.com/jellyfin/jellyfin/blob/master/LICENSE)
