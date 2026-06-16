# jellyfin-hdr

Custom Jellyfin Docker image with HDR10 / HDR10+ / HLG transcode passthrough
and Dolby Vision Profile 7 + subtitle burn-in support via CUDA / NVENC on
Nvidia GPUs (RTX 30-series and later recommended).

Built on top of [`jellyfin/jellyfin`](https://github.com/jellyfin/jellyfin).
Patches are maintained in the [`lidslabs/jellyfin`](https://github.com/lidslabs/jellyfin)
fork on `lidslabs/hdr-X.Y.x` branches; this repo packages them into immutable
images published to ghcr.io.

## Pull

```sh
docker pull ghcr.io/lidslabs/jellyfin-hdr:latest
```

Specific version (recommended for production):

```sh
docker pull ghcr.io/lidslabs/jellyfin-hdr:v0.1.0_jellyfin-10.11.10
```

Note the underscore: git tags use `+` (semver build metadata), Docker image
tags substitute `_` because `+` is not a valid Docker tag character.

## Enable HDR transcoding

Set in container environment:
JELLYFIN_ALLOW_HDR_TRANSCODE=1

Default is `0` (stock Jellyfin tonemap-to-SDR behavior). When enabled, HDR10
/ HDR10+ / HLG sources transcoded to HEVC or AV1 retain their HDR metadata
end-to-end. Dolby Vision Profile 7 sources are converted to HDR10 on the fly
(the Dolby Vision RPU/EL is dropped; the BL is genuine HDR10).

## Source and provenance

- Patches (build input): [`patches/`](./patches/) - regenerated from the fork at release time
- Fork branch (dev workflow): [`lidslabs/jellyfin@lidslabs/hdr-10.11.x`](https://github.com/lidslabs/jellyfin/tree/lidslabs/hdr-10.11.x)
- Pinned upstream version: see [`UPSTREAM_VERSION`](./UPSTREAM_VERSION)
- Pinned fork commit SHA: see [`JELLYFIN_REF`](./JELLYFIN_REF)
- Lidslabs patch layer version: see [`VERSION`](./VERSION)

Each built image embeds a `/BUILD_INFO` file:

```sh
docker run --rm ghcr.io/lidslabs/jellyfin-hdr:latest cat /BUILD_INFO
```

## Build

CI builds and publishes to ghcr.io on every `v*` tag push. See
[`.github/workflows/build-and-push.yml`](.github/workflows/build-and-push.yml).

To cut a release locally: edit `VERSION` (and `UPSTREAM_VERSION` / `JELLYFIN_REF`
if upstream changed), commit, then run `./scripts/release.sh`.

## License

Patches and Dockerfile: same license as upstream Jellyfin (GPL-2.0). See
[upstream LICENSE](https://github.com/jellyfin/jellyfin/blob/master/LICENSE).
