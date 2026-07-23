# jellyfin-hdr

Custom Jellyfin Docker image: **HDR10 / HDR10+ / HLG transcode passthrough** and
**Dolby Vision Profile 7 → HDR10** conversion (with subtitle burn-in) via CUDA /
NVENC on Nvidia GPUs (RTX 30-series or later recommended). Every feature is **off
by default** — unset, the image behaves exactly like stock Jellyfin.

Built on [`jellyfin/jellyfin`](https://github.com/jellyfin/jellyfin). The C#
changes live as patches in the [`lidslabs/jellyfin`](https://github.com/lidslabs/jellyfin)
fork (integration branch `lidslabs/10.11.x`); each release pins its exact source
commit in [`JELLYFIN_REF`](./JELLYFIN_REF) and tags it `jellyfin-hdr/vX.Y.Z`. This
repo bakes those patches into immutable images on ghcr.io.

## Pull

```sh
docker pull ghcr.io/lidslabs/jellyfin-hdr:v0.3.3-jellyfin-10.11.11   # pin a version (recommended)
docker pull ghcr.io/lidslabs/jellyfin-hdr:latest
```

Note the dash: git tags use `+` (semver build metadata); Docker tags substitute
`-` because `+` is not a valid Docker tag character.

## Configuration

> [!IMPORTANT]
> At minimum set **`LIDSLABS_ALLOW_HDR_TRANSCODE=1`**. Without it, none of the HDR
> or forced-HEVC behavior engages and the image runs as stock Jellyfin.

| Variable | Default | Purpose |
| --- | --- | --- |
| `LIDSLABS_ALLOW_HDR_TRANSCODE` | `0` | **Master toggle.** `1`/`true` turns on HDR10 / HDR10+ / HLG passthrough (and DV P7 → HDR10) during transcode. The levers below are independent of it. |
| `LIDSLABS_FORCE_HEVC_CLIENTS` | _(unset)_ | Comma-separated [friendly client names](#forced-hevc-for-hdr-capable-clients) to force onto an HEVC transcode (e.g. `neptune,streamyfin,neptune_av`). Fires for any source, SDR or HDR; only ever forces a codec the client already advertises. |
| `LIDSLABS_SDR_LADDER_CLIENTS` | `swiftfin,neptune_av` | Apple AVPlayer clients that receive an [SDR companion rung](#apple-avplayer-clients) on the HDR master so they'll start HDR playback. Sensible default; override only to add/remove a client. |

The image also sets `CUDA_CACHE_PATH=/config/.cudacache` so the GPU's CUDA JIT
cache persists (see [Faster transcode start](#faster-transcode-start)). NVENC/CUDA
requires the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
on the host and HEVC hardware encoding enabled in **Dashboard → Playback →
Transcoding** (Hardware acceleration → NVENC).

### Sample `docker-compose.yml`

A copyable version lives at [`docker-compose.example.yml`](./docker-compose.example.yml).

```yaml
services:
  jellyfin:
    image: ghcr.io/lidslabs/jellyfin-hdr:v0.3.3-jellyfin-10.11.11
    container_name: jellyfin
    restart: unless-stopped
    deploy:                      # GPU via the NVIDIA Container Toolkit
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ["0"]  # pin a GPU; or use `count: all`
              capabilities: [gpu]
    environment:
      LIDSLABS_ALLOW_HDR_TRANSCODE: "1"                            # master toggle
      LIDSLABS_FORCE_HEVC_CLIENTS: "neptune,streamyfin,neptune_av" # optional
      # LIDSLABS_SDR_LADDER_CLIENTS defaults to swiftfin,neptune_av — omit unless tuning
      NVIDIA_DRIVER_CAPABILITIES: "compute,video,utility"
      TZ: America/New_York
    ports:
      - "8096:8096"
    volumes:
      - ./config:/config
      - ./cache:/cache
      - /path/to/media:/media    # rw: Jellyfin writes posters / NFO / trickplay alongside media
```

> **Pin a version tag**, not `:latest`. This image ships breaking env-var changes
> between minor versions (e.g. v0.3.0 renamed `JELLYFIN_ALLOW_HDR_TRANSCODE`,
> which silently disables HDR if a stale name lingers). Watch the
> [release notes](https://github.com/lidslabs/jellyfin-hdr/releases) before upgrading.

### Forced HEVC for HDR-capable clients

Some HDR-capable clients (notably Apple TV apps) advertise HEVC but request an
h264 transcode, so HEVC's efficiency — and, on HDR sources, HDR itself — never
reaches the screen. Listing a client in `LIDSLABS_FORCE_HEVC_CLIENTS` rewrites the
request to HEVC. It fires for any source (an HDR title takes the passthrough path;
an SDR remux is re-encoded to HEVC SDR rather than back to H264), only ever forces
a codec the client's own profile already advertises, and is independent of the
master toggle.

Clients are matched by **friendly name → `DeviceProfile.Name`**, not User-Agent
(one app can expose several player modes under one UA):

| Friendly name | Client mode |
| --- | --- |
| `neptune` | Neptune — Trident player |
| `neptune_av` | Neptune — AV Player |
| `streamyfin` | Streamyfin (mpv) |
| `swiftfin` | Swiftfin tvOS (opt-in; see notes below) |

Names not in the table are silently ignored; adding one is a reviewable code
change, by design. This list is a workaround expected to **shrink over time** — a
client only belongs here while it mis-declares its codec preference.

### Apple AVPlayer clients

Apple's **AVPlayer** engine (Swiftfin, Neptune AV Player) refuses to start an HLS
master that advertises **only** an HDR (`VIDEO-RANGE=PQ`) variant — it fetches the
playlist, never requests a segment, and shows a black screen. The fix is
structural: for the clients in `LIDSLABS_SDR_LADDER_CLIENTS`, the HDR-passthrough
master carries an **H.264 SDR companion rung** alongside the HDR one. AVPlayer then
commits to the master and, on an HDR-capable build, selects the HDR variant.

- **Swiftfin** plays HDR from start, seek, and resume — no per-client config
  beyond the default ladder. (Optionally add `swiftfin` to
  `LIDSLABS_FORCE_HEVC_CLIENTS` to force HEVC on a DV P7 title it would otherwise
  send as h264.)
- **Neptune AV Player** commits and plays, but its current build selects the SDR
  rung rather than HDR — a client-side ceiling, not a server limit. SDR that plays
  beats a black screen; it should pick up HDR on its own once a future build
  selects the PQ variant.

No HDR→SDR *tonemap* lever is needed anymore (the v0.3.2 `LIDSLABS_FORCE_SDR_CLIENTS`
env var was **removed in v0.3.3** — the SDR ladder supersedes it).

## Client compatibility

Behavior is player-specific — one app can expose several engines that handle HDR
differently, so this matrix goes down to the player. **HDR result** is either
*HDR10 passthrough* (HDR metadata reaches the screen) or *SDR (client ceiling)*
(the server offers HDR but the client's player selects/renders SDR). All of it
requires `LIDSLABS_ALLOW_HDR_TRANSCODE=1`.

| Client — player | HDR result | Config | Notes |
| --- | --- | --- | --- |
| **Neptune — Trident** | HDR10 passthrough | `neptune` → HEVC | Default player; native 4K HEVC HDR10, AC3 5.1 |
| **Neptune — AV Player** | SDR (client ceiling) | `neptune_av` → HEVC + SDR ladder | Commits via the ladder, selects the SDR rung |
| **Swiftfin** | HDR10 passthrough | SDR ladder (default) | HDR on start / seek / resume |
| **Moonfin** | HDR10 passthrough | none | mpv HDR render fixed upstream |
| **Streamyfin** | HDR10 passthrough | `streamyfin` → HEVC | Recheck silent-audio after next app release |
| **Wholphin** (Android TV) | HDR10 passthrough | none | Requests HEVC HDR by default |
| **Jellyfin** (Android TV) | HDR10 passthrough | none | Stock HEVC HDR path |
| **Jellyfin Web / Mobile** | stock upstream | none | No lidslabs targeting; unchanged |

Verified on-device on Nvidia NVENC (RTX-class). The forced-HEVC list is a
workaround expected to shrink as clients fix their codec/HDR handling.

## Faster transcode start

On a **Blackwell / RTX 50-series** (sm_120) GPU, jellyfin-ffmpeg's `scale_cuda`
kernel isn't precompiled for the architecture, so the driver JIT-compiles it from
PTX (~6 s) on **every** transcode start — because the base image gives a non-root
run user (`user: 1000:1000`) `HOME=/`, where the driver can't write its default
`~/.nv/ComputeCache`. This image points the cache at the persistent `/config`
volume via **`CUDA_CACHE_PATH=/config/.cudacache`**, so the kernel compiles once
ever (survives restarts) and later transcodes start ~6 s sooner. Always on, ~6 MB,
write-once. Operators with a read-only `/config` can override `CUDA_CACHE_PATH` to
another writable, persistent path. Older GPUs ship precompiled kernels and never
hit this.

## HDR transcoding

With the master toggle on, HDR10 / HDR10+ / HLG sources transcoded to HEVC or AV1
retain their HDR metadata end-to-end (default-off behavior is stock Jellyfin's
tonemap-to-SDR). Dolby Vision Profile 7 sources are converted to HDR10 on the fly
(the DV RPU/EL is dropped; the base layer is genuine HDR10).

## Audio compatibility-track redirect

When Jellyfin would transcode a lossless audio track (TrueHD, DTS-HD MA, FLAC…)
during a transcoded stream, this build first checks the file for a separate lossy
surround track in the same language and, if found, stream-copies **that** track
instead — no audio re-encoding. Applies **only during transcoding**; direct play
is untouched, and files without a candidate transcode normally.

The redirect fires only when all hold: the audio track is being transcoded; the
requested track has a language tag; and the file has another track that matches
that language, is AC3 or E-AC3, has ≥6 channels, and passes Jellyfin's
`CanStreamCopyAudio` check. If several match, the lowest stream index wins. It's
silent — to confirm on a file, compare the requested `AudioStreamIndex` against
the ffmpeg `-map 0:N` audio arg; if they differ, the redirect fired (audio line
shows `-codec:a:0 copy`). Always-on this release; a future admin-UI/env opt-out is
planned.

## Source and provenance

- **What we change:** [`PATCHES.md`](./PATCHES.md) — the complete change surface, by file and by patch
- **Patches (build input):** [`patches/`](./patches/) — regenerated from the fork at release time
- **Pinned fork commit:** [`JELLYFIN_REF`](./JELLYFIN_REF); each release is also tagged `jellyfin-hdr/vX.Y.Z` in the [fork](https://github.com/lidslabs/jellyfin/tags)
- **Integration branch:** `lidslabs/10.11.x` in the fork
- **Pinned upstream / patch-layer versions:** [`UPSTREAM_VERSION`](./UPSTREAM_VERSION) / [`VERSION`](./VERSION)

Each image embeds `/BUILD_INFO` (the base image has an entrypoint, so override it):

```sh
docker run --rm --entrypoint cat ghcr.io/lidslabs/jellyfin-hdr:latest /BUILD_INFO
```

## Build

CI builds and publishes to ghcr.io on every `v*` tag push
([`build-and-push.yml`](.github/workflows/build-and-push.yml)). To cut a release:
edit `VERSION` (and `UPSTREAM_VERSION` / `JELLYFIN_REF` if upstream changed),
commit, then run `./scripts/release.sh`.

## Reporting issues

Open a GitHub issue; see [`SECURITY.md`](./SECURITY.md) for security reports.

## License

GPL-2.0-only, matching upstream Jellyfin. Patches are derivative works of
Jellyfin's GPLv2 source. See [`LICENSE`](./LICENSE) and
[upstream](https://github.com/jellyfin/jellyfin/blob/master/LICENSE).
