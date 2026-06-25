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
