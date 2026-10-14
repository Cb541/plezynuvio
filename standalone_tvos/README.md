# Nuvio Native Player — Apple TV

A **standalone** tvOS UIKit media player, using Plezy's existing native libmpv
Apple TV decoding core **only** as a source dependency (no Flutter/Plex account).
It has a distinct bundle identifier and `nuvio-player://` deep-link scheme.

## Features (prototype)

- Dolby Vision Profile 7 -> 8.1 conversion: inherited from pinned patched
  FFmpeg/libmpv via `PLEZY_DV_CONVERSION_MODE=dv81`. This is independent of
  whether the HDMI chain can actually present Dolby Vision.
- Native Siri Remote 15-second directional click/hold seeking and paused touch scrubbing.
- Full-screen target-position FFmpeg preview only during locked FF/RW and paused-touch scrubbing, with a reusable decoder and LRU frame cache.
- Zoom and independent vertical stretch, applied to the video layer rather
  than mpv's video-zoom (which would break DV on tvOS).
- No Plex/Jellyfin login. Nuvio passes a resolved stream URL.

## Handoff

`nuvio-player://stream?url=<RFC3986-encoded-http-url>&title=<encoded-title>&sub=<encoded-subtitle-URL>`

Subtitle forwarding is optional; signed URLs can expire. Only authorized direct
HTTP(S) streams without separate authentication headers are supported.

## Siri Remote and minimal controls — 1.1.2

- **Quick Left/Right click:** silently skip **15 seconds** in either
  direction. No thumbnail, progress bar, or pop-up is shown. Quick
  left/right touch-surface swipes do the same while video is playing.
- **Hold Left/Right (about half a second):** enter **locked fast-forward /
  rewind**. You can let go and the preview continues moving. Every
  additional click in that direction raises the speed through
  2× / 4× / 8× / 16× / 32×; clicking the opposite direction reverses
  the preview. **Select** commits one seek to the displayed position.
  **Back** cancels it. There is no three-second timeout in this mode.
- **Paused touch scrubbing:** drag the Siri Remote's surface to browse
  using a longer, duration-sensitive travel distance. Release commits
  the selected position **without unpausing**. A flick in pause mode
  advances a larger fraction of the movie and shows the preview.
- **Single full-screen, separate preview:** when and only when locked
  fast-forwarding/rewinding or paused-touch scrubbing, decode an
  independent image at the *target* movie timestamp, cropped to fill
  the full TV screen with `scaleAspectFill` rather than mirroring the
  currently playing AVFoundation video surface. No video preview is
  shown for ordinary 15-second skips.
- **Playback chrome:** transparent bottom timeline with **elapsed time on
  the left** and **total duration on the right**, alongside the
  liquid-glass AUDIO, CC and INFO actions. Glass falls back to a blur
  on older tvOS releases. The timeline only appears while paused or
  in locked/scrub mode. Press Down to focus the playback tools.
- **Timeout:** three seconds after the last inactive navigation
  interaction; while locked or actively touch-scrubbing, timeout is
  suspended. **Back** hides the controls immediately before
  the exit confirmation is offered.
- **Up:** zoom and vertical stretch, retained from the working release.
  Dolby Vision P7 → P8.1 conversion and playback-mode matching are
  unchanged.

## Preview decoder architecture

Uses a local FFmpeg decoder for remote HTTP(S) MKV/H.264/HEVC and
compatible files. The thumbnail worker reuses the demuxer, codec and
underlying HTTP session between requests for the **same file**,
instead of re-opening and re-scanning the entire file for each remote
movement. Only the newest pending target is retained; decoded frames
are cached in memory in five-second buckets. On-device only: no image
service, account, key, or upload.

This code is compiled/tested by tvOS CI, but real speed depends on
actual HTTP range support, remote remux/keyframe placement, network
latency and the Apple TV's software HEVC performance. It is not the
proprietary Infuse thumbnail engine.

## Build

The GitHub Action `native-apple-tv.yml` generates a dedicated Xcode project
using XcodeGen, builds against the same pinned tvOS MPVKit binary package as
the last working Plezy build, and packages an **unsigned** tvOS IPA.
Sign it using a tvOS provisioning profile before installing.

This is a first native prototype. A passing CI build does not validate actual
DV output or thumbnail latency from real remote MKV/DV files.
