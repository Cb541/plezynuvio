# Nuvio Native Player — Apple TV

A **standalone** tvOS UIKit media player, using Plezy's existing native libmpv
Apple TV decoding core **only** as a source dependency (no Flutter/Plex account).
It has a distinct bundle identifier and `nuvio-player://` deep-link scheme.

## Features (prototype)

- Dolby Vision Profile 7 -> 8.1 conversion: inherited from pinned patched
  FFmpeg/libmpv via `PLEZY_DV_CONVERSION_MODE=dv81`. This is independent of
  whether the HDMI chain can actually present Dolby Vision.
- Native Siri Remote 15-second directional click/hold seeking and paused touch scrubbing.
- Single local FFmpeg thumbnail above the timeline for HTTP(S) MKV and compatible formats, with coalesced requests and an LRU frame cache.
- Zoom and independent vertical stretch, applied to the video layer rather
  than mpv's video-zoom (which would break DV on tvOS).
- No Plex/Jellyfin login. Nuvio passes a resolved stream URL.

## Handoff

`nuvio-player://stream?url=<RFC3986-encoded-http-url>&title=<encoded-title>&sub=<encoded-subtitle-URL>`

Subtitle forwarding is optional; signed URLs can expire. Only authorized direct
HTTP(S) streams without separate authentication headers are supported.

## Remote and player overlay

- **Quick Left/Right click:** a 15-second jump, based on MPV's real
  `time-pos` and `duration` observations (not stale zero-value caches).
  Rapid clicks accumulate before a single asynchronous seek commits.
- **Hold Left/Right:** after 380ms, begin a continuous 15-second-per-tick
  preview that changes as the button is held. Let go to seek once to the
  final target, rather than issuing costly HTTP seeks every 380ms.
- **While paused:** drag left/right on the touch surface to scrub the
  preview playhead with reduced sensitivity. Releasing seeks to the chosen
  position but keeps the film paused.
- The preview uses a **single thumbnail** above the slim timeline. A
  coalescing queue lets the current image complete its decode and skips
  obsolete intermediate requests, so repeated hold events don't starve
  the thumbnail decoder. It caches frames rounded to five-second intervals.
- **Up:** opens Zoom and Vertical Stretch controls unchanged; Up/Down
  selects a property, Left/Right adjusts it, Select restores defaults.
- **Down:** focuses three clearly labeled bottom-right controls:
  AUDIO, CC, and INFO. Left/Right selects, Select opens. Track menus use
  Up/Down and Select to set MPV's actual track IDs.
- **Back:** closes the open menu, hides the slim transport bar/preview
  immediately, or (on the following Back with controls hidden) displays
  a confirmation before stopping the current video.
- The transport controls auto-hide after **three seconds** of inactivity.
  The title card and opaque progress container are removed.
- Apple TV/Infuse's public control guide is the behavior reference;
  this implementation is native UIKit/libmpv, not Infuse code.

## Preview extraction

The previous secondary mpv process used `vo=image`, which couldn't
produce frames on the Apple TV. The new preview uses FFmpeg demuxing
and on-device frame decoding from the same stream; no server/API-key,
third-party requests, or uploads. A bounded in-memory cache and
latest-target coalescing are used for random seek traffic.

Remote MKV/DV preview speed depends on stream index/keyframe position,
HTTP byte-range support, and codec decode cost. This native path builds
in tvOS CI, but still requires on-device verification against actual 4K
network files. It does not precompute every frame or promise the exact
latency of Infuse's proprietary extraction.

## Build

The GitHub Action `native-apple-tv.yml` generates a dedicated Xcode project
using XcodeGen, builds against the same pinned tvOS MPVKit binary package as
the last working Plezy build, and packages an **unsigned** tvOS IPA.
Sign it using a tvOS provisioning profile before installing.

This is a first native prototype. A passing CI build does not validate actual
DV output or thumbnail latency from real remote MKV/DV files.
