## Enhanced NVDEC coexistence — keep HDR working with the decoder default-on

Status: Implemented on mainline; not yet released (ships in v0.3.2).

### Problem
- Jellyfin's **"Enable enhanced NVDEC decoder"** transcoding setting
  (`EncodingOptions.EnableEnhancedNvdecDecoder`) **defaults to ON upstream**. With it
  on, this image's HDR passthrough path hard-failed: a black screen / freeze on the
  first frame, with no decodable output — **not** a wrong-colors / tonemap bug. Because
  the toggle is on by default, this was the *default* experience for any HDR transcode
  on Nvidia unless the operator knew to turn the setting off.

### Root cause (captured, not assumed)
- The enhanced decoder emits ffmpeg's `-hwaccel_flags +unsafe_output`, which passes the
  encoder the decoder's **internal, un-copied** CUDA surfaces. The HDR passthrough path
  routes those surfaces through a no-op `scale_cuda=p010` step (a passthrough that
  allocates nothing) straight into NVENC, so the decoder's finite surface pool is pinned
  and exhausted — ffmpeg fails with `CUDA_ERROR_MAP_FAILED` (`cuvidMapVideoFrame`). SDR
  transcodes are unaffected because their `scale_cuda` step performs a real format
  conversion that reallocates and frees the surface. Reproduced on HDR10 and Dolby
  Vision Profile 7.

### Decision
- For the HDR passthrough path on Nvidia with the enhanced decoder on, **omit only the
  `+unsafe_output` flag**. The enhanced NVDEC decoder itself is **kept** — this is not a
  fallback to the older `*_cuvid` decoder. The result is HDR transcodes that work
  whether the operator leaves "Enable enhanced NVDEC decoder" on (the default) or off.
- **Always on, no configuration.** This is a correctness fix, not a preference — there is
  no coherent reason to expose a toggle that only lets a user re-break HDR. Every non-HDR
  and non-Nvidia transcode command is byte-identical to upstream; the change only ever
  removes the one flag for the exact HDR-passthrough case that needs it.

### Why this over forcing the older decoder
- The obvious alternative was to force the dedicated `*_cuvid` decoder on the HDR path
  and ignore the operator's toggle. That works but is heavier: it discards the enhanced
  decoder's decode-side advantages (ffmpeg's own bitstream parser handles some awkward
  streams, frame-accurate seeking) for HDR, and it is a broader override to maintain
  across upstream updates. Capturing the actual ffmpeg error showed the failure was a
  **single flag**, not a decoder incompatibility — so the surgical fix (drop the flag,
  keep the decoder) is both smaller and strictly better. No measurable user-facing
  difference in decode quality or throughput either way; the two decoders drive the same
  physical NVDEC block.

---

## AVPlayer-family clients can't ingest HDR-over-HLS — force them to SDR

Status: Implemented on mainline; ships in v0.3.2. Env var `LIDSLABS_FORCE_SDR_CLIENTS`.

### Problem
- With HDR passthrough on (`LIDSLABS_ALLOW_HDR_TRANSCODE=1`), the image tags an HLS
  transcode's master playlist `VIDEO-RANGE=PQ` and hands HDR to **every** client that
  transcodes, whether or not it asked for HDR. **AVPlayer-family tvOS clients** (Apple's
  `AVPlayer` — Neptune AV Player, and Swiftfin's default engine) **reject `VIDEO-RANGE=PQ`
  at master-playlist parse and never request a segment** → the screen stays black. They
  advertise HEVC HDR10 capability, so the source of the failure isn't obvious from the
  DeviceProfile; it only shows up on the HLS ingest path.

### Decision
- Add `LIDSLABS_FORCE_SDR_CLIENTS` — a per-client list whose HDR titles are forced onto an
  **HDR→SDR tonemap** while the transcode **stays HEVC**. It is a colour-range downgrade,
  not a codec change, so HEVC's efficiency is retained. Decided at PlaybackInfo by
  `DeviceProfile.Name` (the same collision-safe `LidslabsClientMatches` map as the
  forced-HEVC lever), carried on the transcode request as `VideoRangeType=SDR`, and honored
  at the single HDR-passthrough gate (`EncodingHelper.IsHdrPassthroughMode`), which flips
  the HLS master `VIDEO-RANGE` and the ffmpeg tonemap together. Inert on SDR sources
  (nothing to downgrade) and idempotent.

### Why decide at PlaybackInfo, not at transcode time
- At transcode time AV Player and Trident are **indistinguishable** — same Neptune app, same
  User-Agent. Only the posted `DeviceProfile.Name` delineates them (`"Neptune tvOS"` vs
  `"Neptune tvOS (Trident)"`), and that is only available at PlaybackInfo. Deciding there and
  carrying the decision on the request keeps one collision-safe source of truth and avoids a
  fragile UA match downstream. Trident is deliberately absent from the list — it plays HDR on
  its own path and must stay HDR.

### Why SDR is the right outcome for these clients (not a regression)
- HDR-over-HLS is a **hard AVPlayer limitation**, not something a server knob can satisfy —
  the client refuses the PQ manifest before any bytes flow. The realistic choice for an
  AVPlayer-family client is *SDR that renders* vs *HDR that black-screens*. A tonemapped SDR
  HEVC stream that plays is strictly better than a correct HDR stream the client won't fetch.
- **Not delineable everywhere.** Swiftfin posts an identical DeviceProfile
  (`Name=null`, `client="Jellyfin tvOS"`) for both its AVPlayer and Native players, so there
  is no server-side signal to force **only** its AVPlayer mode to SDR without also washing
  out its working Native-Player HDR path. Swiftfin is therefore **not** added to the list; its
  HDR answer is "use the Native Player" (see the Swiftfin entry). Force-SDR is applied only to
  clients that expose a distinct, matchable profile name for the AVPlayer mode (Neptune AV
  Player today).

---

## Neptune AV Player — supported via forced HEVC + fMP4 + forced SDR

Status: Implemented on mainline; ships in v0.3.2 (friendly name `neptune_av`).

### Problem
- Neptune's **AV Player** mode advertises HEVC HDR10 but historically rendered **black** on
  HDR titles. It is AVPlayer-on-tvOS (same renderer class as Swiftfin), and its only video
  `TranscodingProfile` is h264/HLS, so it never *requests* HEVC — it must be forced, and
  forcing HEVC alone still went black.

### Decision
- Support AV Player through three levers, all keyed on the collision-safe `neptune_av` match
  (`"Neptune tvOS"` and not Trident):
  1. **Forced HEVC** (`LIDSLABS_FORCE_HEVC_CLIENTS=…,neptune_av`) — inject HEVC as the
     transcode target, since AV Player only ever requests h264.
  2. **fMP4 HLS transport** — rewrite the video HLS container `ts→mp4`; AVPlayer cannot
     decode HEVC-in-MPEG-TS.
  3. **Forced SDR** (`LIDSLABS_FORCE_SDR_CLIENTS=…,neptune_av`) — tonemap HDR→SDR so the
     client accepts the master playlist (see the force-SDR entry above). This is the lever
     that actually cleared the black screen; the first two are necessary but not sufficient.
- On device (2026-07-02/03): a 4K HDR title renders as clean HEVC **SDR**, and an H264 SDR
  source is upgraded to HEVC SDR. Trident, which shares the app, is unaffected.

### Why AV Player is SDR-only
- The HDR limitation is AVPlayer's, not the server's (see the force-SDR entry). AV Player's
  supported outcome is a tonemapped SDR HEVC stream that plays, not HDR passthrough. Revisit
  if a future Neptune build changes AVPlayer's HLS HDR handling — Neptune is in TestFlight.

---

## Swiftfin (Apple TV) — correct the DeviceProfile it over-claims

Status: Implemented on mainline; ships in v0.3.2. Always on, code-scoped to Swiftfin.

### Problem
- Swiftfin (Apple TV, `User.GetClient() == "Jellyfin tvOS"`, `DeviceProfile.Name=null`)
  posts a DeviceProfile that over-claims what its Apple-AVPlayer engine can actually do,
  producing three distinct failures on HDR/lossless titles: **silent audio** (advertises
  TrueHD direct-play it can't decode), **digital static** (blind-copies a Dolby Vision
  Profile 7 dual-layer stream), and **static again** on any forced/remuxed HEVC (AVPlayer
  can't decode HEVC-in-MPEG-TS).

### Decision
- Three always-on corrections under the one client gate — targeting, not an operator toggle;
  correcting a client's false capability claim is a correctness fix, not a preference:
  1. **Strip TrueHD** (`truehd`/`mlp`) from Swiftfin's audio direct-play profiles so the
     track transcodes (or picks up the AC3 compat redirect) instead of playing silent.
     **DTS-HD MA is left intact** — AVPlayer decodes its DTS core and plays it.
  2. **Strip Dolby Vision Profile 7** to a clean HDR10 base via an `hevc` `VideoRangeType`
     allow-list excluding only the enhancement-layer types → stream-copy with
     `dovi_rpu=strip`, **no re-encode**. P5/P8/HDR10 still direct-play.
  3. **Force fMP4 HLS** transport (`ts→mp4`) so a remuxed HEVC stream is CMAF, which AVPlayer
     decodes natively.

### Known residual — a Swiftfin client bug, not our output
- After the fixes, video + audio are correct and the stream carries HDR10 (`VIDEO-RANGE=PQ`),
  but on Swiftfin's **default VLCKit engine** the Apple TV stays in **SDR display mode** —
  VLCKit doesn't tone-map or trigger tvOS HDR switching. **Workaround: use Swiftfin's Native
  Player**, which engages HDR. This is out of scope for the server; documented as a client
  compatibility note. Swiftfin's AVPlayer mode is not separately force-SDR'd because it shares
  a byte-identical DeviceProfile with the working Native Player (see the force-SDR entry).

### Self-deactivating
- All three corrections graduate out on their own if a future Swiftfin build stops
  over-claiming (reports TrueHD/DV-P7 honestly): the strips become no-ops. The fMP4 force
  stays needed regardless — no AVPlayer remux can use MPEG-TS. Re-test against the imminent
  Swiftfin revamp and shrink the list where possible.

---

## Forced HEVC is a codec-preference lever, independent of the HDR path

Status: Implemented on mainline; ships in v0.3.2. Supersedes the v0.3.0 forced-HEVC scoping.

### What changed
- The v0.3.0 forced-HEVC override only rewrote `TranscodingProfile.VideoCodec` to prepend
  `hevc` **when the source was HDR**, and it shared the `LIDSLABS_ALLOW_HDR_TRANSCODE` master
  toggle as an enable condition. Both couplings were truth-in-naming misses: a lever named
  **FORCE_HEVC** left an SDR remux on H264, and a codec preference has nothing to do with the
  HDR master toggle.

### Decision
- Drop the HDR-source condition and decouple the lever from `LIDSLABS_ALLOW_HDR_TRANSCODE`.
  Base eligibility is now **client-in-list + client advertises HEVC**, for **any** source. A
  forced client's 40 Mbps H264 SDR remux becomes ~20 Mbps HEVC SDR instead of re-encoding to
  20 Mbps H264. HDR passthrough remains governed **solely** by the master toggle inside
  `IsHdrPassthroughMode`; the two levers are fully independent and neither can enable or
  disable the other.
- The safeguard is unchanged: the override **never invents capability** — it only forces a
  codec the client's DeviceProfile already advertises (`LidslabsProfileClaimsHevc`), for
  clients explicitly listed. AVPlayer-family clients that can't render forced HEVC over HDR
  are handled by the paired fMP4 + force-SDR levers, not by widening this one.

---

## Faster transcode start — persist the CUDA JIT cache

Status: Implemented on `feature/fast-transcode-start`; not yet released.

### Problem
- On supported clients a transcode starts with a black screen until the first
  frame arrives. On a newer GPU (RTX 5080, Blackwell/sm_120) that window measured
  ~9–10 s on a 4K HDR→HEVC transcode, and it didn't move when storage was warm or
  when ffmpeg's input probe was reduced.

### The triggering combination
The slowdown only appears when **all three** hold together — which is why some
users see it and others never do:
1. **An Nvidia GPU transcode path** that uses a CUDA filter (`scale_cuda`, on the
   HDR/NVENC pipeline), **and**
2. **the container configured so Jellyfin does not run as root** — e.g.
   `user: 1000:1000` in compose (a recommended security practice), which leaves
   the run user with a non-writable `HOME=/`, **and**
3. **a GPU architecture newer than the cubins bundled in jellyfin-ffmpeg**
   (e.g. Blackwell / sm_120), so the kernel must be JIT-compiled from PTX.

Drop any one and the symptom disappears: an older GPU ships a precompiled kernel
(no JIT), running as root gives a writable `HOME` (cache persists), and a non-CUDA
path never invokes the kernel. The user did nothing wrong — running non-root is
encouraged; the combination is what bites.

### Root cause (measured, not assumed)
- Isolating the pipeline showed the cost was a fixed ~6 s that appeared only when
  the `scale_cuda` filter was in the graph, was independent of segment length and
  encode preset, and **repeated on every ffmpeg launch** (two back-to-back runs
  both paid it) — the signature of CUDA JIT with no persistent cache.
- The driver normally caches the JIT result in `~/.nv/ComputeCache`; with
  `HOME=/` non-writable it could not, forcing a recompile every transcode. Proof:
  setting a writable `CUDA_CACHE_PATH` cut the second run from ~6.5 s to ~0.8 s;
  the full Jellyfin HLS command went from 9.46 s to 3.52 s to first segment.

### Decision
- Set `ENV CUDA_CACHE_PATH=/config/.cudacache` in the image (Dockerfile only; no
  patch-layer change). `/config` is always a persistent Jellyfin volume, so the
  kernel is JIT-compiled once, ever (survives restarts). The driver auto-creates
  the directory; no writable-dir setup needed. This is the patch that addresses
  the triggering combination above.
- **Always on, not env-gated.** Unlike the HDR features (which change output and
  are opt-in), this only changes startup speed, never output. Gating it
  off-by-default would ship a known ~6 s regression by default. Operators with a
  read-only `/config` can override `CUDA_CACHE_PATH`.

### Why persistent disk, not RAM (`/dev/shm`)
- The cache is ~6 MB and write-once — there is no churn to wear an SSD. RAM
  would be wiped on restart, re-paying the ~6 s JIT once per restart; persistent
  disk pays it once, ever. Persistent strictly wins for this workload, so no
  disk-vs-RAM toggle is warranted.

### Scope note
- This was reached after rejecting an ffmpeg input-probe reduction
  (`probesize`/`analyzeduration`): measurement showed the probe is a ceiling that
  a well-muxed file satisfies early, so reducing it changed nothing for this
  content. The probe was not the bottleneck; the JIT cache was. The probe approach
  was dropped rather than shipped as dead weight.
- Secondary, separate lever (not part of this fix): NVENC `-preset p7`→`p4` shaved
  the residual ~3.5 s toward ~1.5 s at a small quality cost — a Jellyfin
  transcoding setting, tracked separately.

### Upstream angle
- The non-writable `HOME=/` for non-root users is a latent base-image gap that
  only surfaces on GPU archs requiring JIT. Worth an upstream report; until then
  this image carries the fix.

---

## v0.3.0 — Forced HEVC override for HDR-capable Apple TV clients

Status: Shipped.

### Problem
- v0.2.0 preserved HDR through the transcode pipeline but only when StreamBuilder
  selected an HEVC encode target. Several tvOS clients (Neptune in both Trident
  and AV Player modes, Streamyfin) advertise HEVC + HDR10 capability in their
  DeviceProfile but list h264 first in TranscodingProfile.VideoCodec, so
  StreamBuilder picked h264 + SDR tonemap and the v0.2 patches never engaged.
- Net effect: HDR sources reached HDR-capable Apple TV clients as SDR. The whole
  point of the project was being bypassed by client codec ordering.

### Decision
- Hook `MediaInfoController.GetPostedPlaybackInfo` to rewrite
  `TranscodingProfile.VideoCodec` and prepend `"hevc"` before StreamBuilder
  processes the request. One hook point, one rewrite, eligibility gated by four
  conditions evaluated in order:
  1. Master toggle `LIDSLABS_ALLOW_HDR_TRANSCODE=1` is set.
  2. The client's DeviceProfile name maps to a known entry in the
     friendly-name → profile-substring table.
  3. At least one MediaSource on the item is HDR (checked after
     `GetPlaybackInfo` populates MediaSources).
  4. The client's DeviceProfile declares HEVC capability anywhere in
     DirectPlay, Transcoding, or CodecProfile entries.
- Rewrite happens pre-loop over MediaSources, not inside the loop, to avoid
  polluting the shared profile object across iterations.

### Gate input: profile.Name over User-Agent
- Initial design gated on HTTP User-Agent substring matching. UA is the same
  for both Neptune client modes — Neptune the app sends one UA regardless of
  whether Trident or AV Player is the active player. UA cannot distinguish
  modes; the gate could not selectively enable Trident while excluding
  AV Player.
- Switched to `DeviceProfile.Name`, which does distinguish modes within an
  app. Added a friendly-name → profile-substring mapping inside the helper so
  `LIDSLABS_FORCE_HEVC_CLIENTS="neptune,streamyfin"` stays ergonomic while the
  internal match is on the precise field. Unmapped friendly names silently
  return false — adding a new client requires a code change with a reviewable
  mapping entry, not just an env var edit.
- Current mappings: `neptune` → profile name contains "Trident";
  `streamyfin` → "1. MPV".

### Diagnostic logging at the eligibility point
- First field deploy shipped with only the success-path `LogInformation`.
  When the override didn't fire, we couldn't distinguish "patch absent from
  build" from "gate failed" from any other failure mode without a second
  rebuild cycle.
- Iteration added one `LogInformation` at the eligibility evaluation point
  that dumps all four gate inputs plus the result. Next test round resolved
  in a single cycle.
- **Principle (new):** every env-gated lidslabs hook ships with a
  gate-decision log at the eligibility point, dumping all gate inputs and
  the result. Cost: one line. Benefit: every future "doesn't fire" debug
  session resolves in one cycle instead of two. Demote to Debug once the
  feature is validated; never delete. ("Demote to Debug" makes the line
  dormant in a default Information-level build — it is a diagnostic hook,
  not prod logging.)
- **As shipped in v0.3.0:** the forced-HEVC hook carries this log at Debug.
  An earlier dev iteration deleted it during a gate refactor; it was
  restored before release to honor the principle. The HDR-toggle hook does
  not have one yet (deferred).

### The forced-client list is temporary scaffolding
- `LIDSLABS_FORCE_HEVC_CLIENTS` and its friendly-name mapping exist only to work
  around clients that advertise HEVC + HDR10 capability but request an h264 + SDR
  transcode. Each entry is a patch over a specific client's wrong default codec
  ordering — not a permanent feature.
- **Exit criterion:** when a listed client starts requesting HEVC HDR by default —
  as Swiftfin and Wholphin already do — it no longer needs the override. Remove it
  from the mapping; the standard HDR passthrough path then carries HDR for it with
  no forcing.
- **Expectation:** this list should *shrink* over time as client apps fix their
  defaults, not grow. A steadily growing forced list is a smell worth questioning.
- **Cadence:** revisit the list when rebasing onto a new upstream Jellyfin tag and
  when a listed client ships a notable app update — re-test whether it still needs
  forcing, and graduate it out if not. Tracked as a recurring backlog item.

### What we explicitly did NOT do
- No DASH support in the audio redirect path. No test target, and the splash
  retrospective discipline says don't widen what we can't validate.
- No bitrate override. Resolution scaling and bitrate budget are left to
  Jellyfin's standard math — HEVC's compression efficiency does the resolution
  win for us (Neptune Trident now hits native 4K at 20 Mbps where h264 needed
  to downscale to 1440p).
- No exclusion list for "client declares X but actually can't render X"
  cases. The friendly-name mapping is the escape hatch — clients we can't
  validate stay out of the mapping. A separate exclusion model can come
  later if the mapping table stops being sufficient.

---

## v0.3.0 — Audio compatibility redirect widened to Progressive

Status: Shipped.

### Why
- v0.2.0's AC3-sidecar substitution in `EncodingHelper.cs` was gated on
  `state.TranscodingType == Hls`. Neptune Trident's progressive
  MKV-over-HTTP transcode bypassed that gate entirely — TrueHD source went
  to AAC 5.1 instead of being substituted with the AC3 sidecar.
- Streamyfin's HLS path fired correctly under the v0.2 logic, which gave us
  a working baseline to compare against.

### Decision
- Widen the outer gate to `Hls || Progressive`. DASH deliberately omitted
  (no test target).
- Initial widening added a candidate filter requiring `s.Codec` to appear
  in `videoRequest.AudioCodec` — intended as defense-in-depth against
  pushing AC3 onto a client that hadn't declared support. **Removed before
  release.** See pre-release regression below.

### Pre-release regression: the candidate filter that broke Streamyfin
- The `videoRequest.AudioCodec.Contains` filter regressed Streamyfin: FFmpeg
  went from `-map 0:2 -codec:a:0 copy` (AC3 sidecar substituted, the v0.2
  working behavior) to `-map 0:1 -codec:a:0 libfdk_aac -ac 6 -ab 640000`
  (TrueHD transcoded to AAC, the exact failure mode the v0.2 patch was
  meant to prevent).
- Root cause: `videoRequest.AudioCodec` on HLS segment requests contains
  StreamBuilder's narrowed transcode-target codec list (typically just
  `"aac"`), NOT the client's full DeviceProfile capability. For Streamyfin's
  segment URLs, `requestAudioCodecs` parsed to `["aac"]`, so the AC3
  candidate failed `Contains`, no substitution, fall through to
  TrueHD→AAC transcode.
- Fix: removed the filter. Comment block updated to document why we don't
  gate on `videoRequest.AudioCodec`, so future iterations have to argue
  past the comment rather than past silence.

### Principle: client capability signals live at different layers

There are at least three things one might call "what the client supports for
audio codecs", and they are NOT interchangeable:

1. **`DeviceProfile.TranscodingProfile.AudioCodec`** — the client's full
   advertised capability list, sent in the PlaybackInfo POST body.
   Available at `MediaInfoController.GetPostedPlaybackInfo` and anywhere a
   DeviceProfile is in scope.
2. **`videoRequest.AudioCodec`** on a transcode segment URL — derived by
   StreamBuilder for each transcode session. Scope is the decision about
   what _this particular transcode output_ should contain. Frequently
   narrowed to a single codec. Available in
   `EncodingHelper.AttachMediaSourceInfo` and downstream.
3. **`state.SupportedAudioCodecs`** in `EncodingJobInfo` — populated by
   encoder initialization. Empty at the specific point
   `AttachMediaSourceInfo` runs.

The pre-release regression came from treating (2) as if it were (1). It
is not. Substituting one for the other will silently break the working
case in exactly the scenarios the patch is supposed to help.

**Rule:** for "what does the client support" questions answered in
`MediaInfoController` scope, read DeviceProfile directly. For the same
question answered in `EncodingHelper.AttachMediaSourceInfo` scope, do not
derive client capability from `videoRequest`. Either trust universal-
compatibility heuristics (the v0.2 AC3/E-AC3 path) or route DeviceProfile
through the call chain explicitly. The intermediate "check videoRequest"
approach is a trap.

### Why no per-request codec gate is safe
- AC3/E-AC3 are HLS-TS, HLS-fMP4, MKV, and MP4 portable across every
  Apple TV and Android client we've tested or seen in the wild.
- No realistic client declares HEVC HDR10 capability but lacks AC3
  support; AC3 is older and more universal than HEVC.
- If a future client genuinely lacks AC3 support, the correct signal is
  `DeviceProfile.TranscodingProfile.AudioCodec` at `MediaInfoController`
  scope, not `videoRequest.AudioCodec` at `EncodingHelper` scope.

---

## v0.3.0 — Env var namespace: `LIDSLABS_*` unification

Status: Shipped.

### Context
- v0.2.0 introduced `JELLYFIN_ALLOW_HDR_TRANSCODE`. At design time the toggle
  felt like "a Jellyfin server config knob" so the upstream prefix seemed
  natural.
- v0.3.0 dev introduced a second toggle under `LIDSLABS_*`, which set up an
  inconsistency: two related toggles in two different namespaces, with no
  semantic distinction between them justifying the split.

### Decision
Rename both to a unified `LIDSLABS_*` prefix before v0.3.0 ships:

```
JELLYFIN_ALLOW_HDR_TRANSCODE  ->  LIDSLABS_ALLOW_HDR_TRANSCODE
<v0.3 dev name>               ->  LIDSLABS_FORCE_HEVC_CLIENTS
```

### Rationale
- **Truth in naming.** This build is not upstream Jellyfin. The `JELLYFIN_*`
  prefix would send anyone grepping for it to upstream docs first, where
  they'd find nothing. `LIDSLABS_*` points straight at this project.
- **Migration cost.** Currently near-zero — only one compose file exists.
  The cost of fixing this rises permanently the moment another user picks
  up the build.
- **Internal consistency.** Everything else about this project says
  `lidslabs` (org, image, fork branch, success log line, decisions file).
  The v0.2 env var was the lone exception. Cheaper to fix now than to
  explain the exception every time.

### Principle
For any project that publishes its own image and patches under a
recognizable identity, custom env vars carry the project's prefix, not
the upstream's. The project prefix points future readers at the right
documentation. The upstream prefix is a quiet lie that costs every future
grep a wasted lookup.

### Naming convention going forward
- Pattern: `LIDSLABS_<FEATURE>_<NOUN>`.
- Drop redundant scoping segments. The v0.3 var was originally
  `LIDSLABS_TRANSCODER_FORCE_HEVC_CLIENTS`; `TRANSCODER` was redundant
  because everything we do is transcoding.

### Codec-gate consistency note
- The `LidslabsHdrTranscodeEnabled()` helper exists in two places
  (`EncodingHelper.cs` and `MediaInfoController.cs`). Both must read the
  same env var with the same parsing rules (`"1"` or `"true"`,
  case-insensitive). Any new gate must mirror this exactly to prevent
  drift. The duplication is a known issue tracked for a post-v0.3.0
  consolidation pass — for now, paired edits are the cost of admission.

---

## Versioning policy — patch-layer semver vs. upstream build metadata

Status: Adopted v0.3.0.

### The rule
A release tag is `v{PATCH_LAYER_SEMVER}+jellyfin-{UPSTREAM_VERSION}`. The two
parts version different things and move independently:
- **`PATCH_LAYER_SEMVER`** (before `+`) versions the lidslabs patch layer only —
  the C# changes carried in `patches/`. It follows semver: MINOR for new
  features or breaking changes (pre-1.0), PATCH for backwards-compatible fixes.
- **`+jellyfin-X.Y.Z`** is semver *build metadata*. It records which upstream
  Jellyfin tag the patches are pinned to. Per the semver spec, build metadata is
  ignored for precedence — `0.1.0+jellyfin-10.11.10` and `0.1.0+jellyfin-10.11.11`
  are the *same* patch-layer version.

### Consequence
An upstream-only rebase that does not change the patch layer (the same patches
re-applied onto a new Jellyfin tag, no `.cs` behavior change) bumps **only** the
`+jellyfin-X.Y.Z` suffix. The patch-layer semver does not move.

### What this corrects
v0.2.0 was tagged `0.2.0+jellyfin-10.11.11` for what was purely an upstream-pin
bump from 10.11.10 → 10.11.11 with no patch-layer change — its own CHANGELOG
entry says "No changes to lidslabs patch layer." Under this rule that release
should have been `0.1.0+jellyfin-10.11.11`, a build-metadata change only. The
0.2.0 tag is published, deployed, and immutable, so it stands; the minor number
it consumed is a one-time gap, not repaid by under-numbering a later release.
v0.3.0 carries real features plus a breaking env-var rename, so it is a genuine
minor — numbered straight to 0.3.0 rather than back-filling 0.2.x (a patch
number would misrepresent the breaking change).

---

## v0.3.0 — Bitrate calibration: Apple HEVC clients

### Measurements
- Neptune Trident with `MaxStreamingBitrate=20` Mbps: transcoded HEVC stream
  uses ~12 Mbps actual. 60% of cap.
- Same client with `MaxStreamingBitrate=40` Mbps: ~30 Mbps actual. 75% of cap.
- Neptune AV Player (h264 baseline) with `MaxStreamingBitrate=40` Mbps: uses
  full 40 Mbps. 100% of cap.
- Same pattern reported anecdotally on Plex with Apple HEVC clients; not
  unique to Jellyfin.

### Conclusion
- Apple HEVC decoder paths target a quality metric and leave headroom
  relative to declared cap (60-75% range observed).
- Apple h264 paths and non-Apple HEVC paths (Wholphin, Android) use the
  full declared cap.
- For a target delivered bitrate of N Mbps to an Apple HEVC client, set
  the server cap to roughly N × 1.4 to leave room for the decoder's
  internal headroom.

### Recommended client config pattern for remote users
- Set `MaxStreamingBitrate` server-side per user, not client-side.
- Have remote users set their client to request direct-play (no
  client-side cap). The server's per-user policy becomes the binding
  constraint regardless of what the client requested.
- Works around Streamyfin's 8 Mbps client-side ceiling and any other
  client-side cap lower than what the server can deliver.

### Re-verify before locking policy
The 60-75% ratio was measured at 20 Mbps and 40 Mbps caps. The 25-30 Mbps
target range (likely the right range for most remote-user policies)
wasn't directly measured. Worth one calibration pass per cap setting
before committing to a server-side default.

---

## v0.3.0 — Released: final compatibility matrix

Supersedes all earlier running matrices. This is the v0.3.0 ship state.

### Verified end-to-end
- **Neptune tvOS (Trident):** HEVC HDR10 main 10 at native 4K, AC3 5.1
  sidecar via StreamBuilder selection. HEVC's compression efficiency lets
  the encoder hit the 20 Mbps cap at 3840x2160 where h264 had to downscale
  to 2560x1440 SDR — the HDR win brought a resolution win along with it.
- **Streamyfin:** HEVC HDR10 main 10 at client-capped resolution (typically
  1440p), AC3 5.1 sidecar via the lidslabs audio compat patch. Client-side
  audio routing bug remains (pre-existing, unchanged by this work); server
  output is correct and verified via FFmpeg log inspection.

### Server-side correct, client-side bugs prevent playback verification
- **Neptune tvOS (AV Player):** HEVC override correctly excluded by the
  friendly-name mapping. Baseline h264 SDR HLS transcode restored.
  Receives the audio compat patch benefit on its Progressive path (TrueHD
  → AC3 sidecar copy) — AV Player users gain audio quality even though
  the HEVC override doesn't apply.
- **Moonfin:** Override doesn't fire (no friendly-name entry).
  StreamBuilder would produce HEVC HDR10 HLS + AC3 if the player ever
  requested segments, but Moonfin's player aborts after PlaybackInfo and
  never invokes ffmpeg. Pre-existing client behavior, unchanged.

### Patch does not fire
- Swiftfin, Jellyfin Web, Jellyfin Mobile, Wholphin, Android clients: no
  friendly-name entry. Behavior unchanged from v0.2.0 baseline. Swiftfin
  already gets HEVC via its own profile and v0.2 handles it.

### Shipped principles in this release
- Profile-name gating with friendly-name → substring mapping (not UA).
- Audio compat widened to HLS or Progressive transcode outputs.
- AC3/E-AC3 substitution trusted as universally container-portable; no
  per-request capability gate.
- The forced-HEVC hook ships a gate-decision log at the eligibility
  evaluation point, at Debug level (dormant in a default Information-level
  prod build; raise the level to diagnose a "doesn't fire" report in one
  cycle). The HDR-toggle hook does not have one yet — deferred (below).
- Project-owned env vars use the `LIDSLABS_*` prefix.

### Deferred to v0.3.1 or later
- Neptune AV Player HEVC HDR10 support. Investigation continues on
  `feature/force-hevc-av-player-investigation`. If a working configuration
  is found, add `neptune_av` to the friendly-name mapping. If not,
  document as permanently excluded.
- Bitrate calibration sweep at 25-30 Mbps target before locking a
  server-side per-user policy.
- Streamyfin client-side audio routing — out of our scope; track upstream.
- Consolidating the duplicated `LidslabsHdrTranscodeEnabled()` helper
  into a single shared utility (currently in both `EncodingHelper.cs`
  and `MediaInfoController.cs`). Out of v0.3.0 scope; flagged as a
  refactor target.
- Extending the gate-decision Debug log to the HDR-toggle hook so every
  env-gated hook honors the diagnostic-logging principle (forced-HEVC hook
  has it; HDR passthrough predates the principle).
