Compatibility matrix at v0.3.0 release

Verified end-to-end:
- Neptune tvOS (Trident): HEVC HDR10 main10 video + AC3 sidecar audio.
  Native 4K output (HEVC efficiency lets the 20Mbps cap accommodate
  3840x2160 where h264 had to downscale to 2560x1440 SDR).

Server-side correct, client-side bugs prevent playback verification:
- Neptune tvOS (AV Player): server produces HEVC HDR10 HLS. AV Player
  declares HEVC + main10 + HDR10 + DOVI in its profile but its player
  cannot render the HLS-delivered stream. Black screen; client reports
  DirectPlay status to the session API even though the server is
  transcoding. Capability declaration appears to be aspirational; player
  module hasn't caught up. Use Trident for HDR until AV Player fixes its
  decoder path.
- Moonfin: server is ready to produce HEVC HDR10 HLS + AC3 sidecar. Same
  baseline behavior as before the patch - Moonfin's player fetches
  PlaybackInfo and master.m3u8 then bails before requesting any segment,
  so ffmpeg is never invoked. Their client-side abort predates this work
  and is unaffected by it.
- Streamyfin: server produces HEVC HDR10 HLS + AC3 sidecar (post-audio-
  widening, also works pre-widening on the HLS path). Video plays; audio
  output fails even with manual 5.1 track selection. Streamyfin player-
  side audio routing bug, pre-existing.

Patch does not fire (out of scope for v0.3.0):
- Swiftfin, Jellyfin Web, Jellyfin Mobile: UA doesn't match the
  Neptune/Streamyfin substring list. Behavior unchanged from baseline.
  Swiftfin already gets HEVC via its own profile and v0.2 handles it.
