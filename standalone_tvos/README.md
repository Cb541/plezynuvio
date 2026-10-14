# Nuvio Native Player — Apple TV

A **standalone** tvOS UIKit media player, using Plezy's existing native libmpv
Apple TV decoding core **only** as a source dependency (no Flutter/Plex account).
It has a distinct bundle identifier and `nuvio-player://` deep-link scheme.

## Features (prototype)

- Dolby Vision Profile 7 -> 8.1 conversion: inherited from pinned patched
  FFmpeg/libmpv via `PLEZY_DV_CONVERSION_MODE=dv81`. This is independent of
  whether the HDMI chain can actually present Dolby Vision.
- Native Siri Remote directional seek and touch-surface pan scrub.
- Five-frame filmstrip preview, independent on-demand decode using `vo=image`
  with a bounded frame cache. Requires seekable HTTP; the image VO is not yet
  proven on physical hardware.
- Zoom and independent vertical stretch, applied to the video layer rather
  than mpv's video-zoom (which would break DV on tvOS).
- No Plex/Jellyfin login. Nuvio passes a resolved stream URL.

## Handoff

`nuvio-player://stream?url=<RFC3986-encoded-http-url>&title=<encoded-title>&sub=<encoded-subtitle-URL>`

Subtitle forwarding is optional; signed URLs can expire. Only authorized direct
HTTP(S) streams without separate authentication headers are supported.

## Remote

Left/right: scrub 10 sec (release to seek). Swipe the touch surface horizontally
while controls are visible to scrub rapidly. Select/play-pause toggles playback.
Up opens picture controls; up/down select zoom/stretch; left/right change values;
Menu closes settings, and second Menu returns to idle.

## Build

The GitHub Action `native-apple-tv.yml` generates a dedicated Xcode project
using XcodeGen, builds against the same pinned tvOS MPVKit binary package as
the last working Plezy build, and packages an **unsigned** tvOS IPA.
Sign it using a tvOS provisioning profile before installing.

This is a first native prototype. A passing CI build does not validate actual
DV output or thumbnail latency from real remote MKV/DV files.
