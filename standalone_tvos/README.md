# Nuvio Native Player — Apple TV

A **standalone** tvOS UIKit media player, using Plezy's existing native libmpv
Apple TV decoding core **only** as a source dependency (no Flutter/Plex account).
It has a distinct bundle identifier and `nuvio-player://` deep-link scheme.

## Features (prototype)

- Dolby Vision Profile 7 -> 8.1 conversion: inherited from pinned patched
  FFmpeg/libmpv via `PLEZY_DV_CONVERSION_MODE=dv81`. This is independent of
  whether the HDMI chain can actually present Dolby Vision.
- Native Siri Remote discrete 15-second swipes/clicks with stable seek targets.
- Five-frame local FFmpeg thumbnail filmstrip for HTTP(S) MKV and compatible formats, with an LRU frame cache.
- Zoom and independent vertical stretch, applied to the video layer rather
  than mpv's video-zoom (which would break DV on tvOS).
- No Plex/Jellyfin login. Nuvio passes a resolved stream URL.

## Handoff

`nuvio-player://stream?url=<RFC3986-encoded-http-url>&title=<encoded-title>&sub=<encoded-subtitle-URL>`

Subtitle forwarding is optional; signed URLs can expire. Only authorized direct
HTTP(S) streams without separate authentication headers are supported.

## Remote and player overlay

- Touch-surface horizontal swipe / click Left or Right: **exactly 15 seconds** per action.
  A short idle debounce accumulates several consecutive actions against one
  stable seek target instead of snapping the target to an older player position.
- While seeking, a five-picture strip appears over the slim, transparent
  progress bar. It remains visible briefly after seek commit to give the local
  thumbnail decoder time to finish the current network extraction.
- Select or Play/Pause: pause or resume; Select while a seek is pending commits it.
- Up: picture controls. Up/Down selects Zoom / Vertical stretch; Left/Right
  adjusts the selected value, Select restores 100%, Back closes the panel.
- Down: focus three bottom-right playback tools. Left/Right moves between
  **Audio, Subtitles, Info**; Select opens one. Within a track panel,
  Up/Down selects the item, Select applies the real MPV aid/sid track ID.
  Subtitles include Off. The Info panel queries current decoded file properties.
- Back: close the active panel, leave toolbar focus, or (while watching a movie)
  ask for confirmation before exiting the current stream.
- A playing movie has no title card or giant black playback box. A minimal
  timeline and action icons appear while seeking, paused, or operating menus,
  and auto-hide during regular playback.

## Thumbnail extraction

The original secondary mpv process used `vo=image`, which failed to return
frames on the Apple TV package. The new backend directly decodes the remote
video stream with FFmpeg's demuxer/decoder and scales a small image with
libswscale, entirely on-device. AVAssetImageGenerator is a fallback for
compatible tvOS MP4/HLS sources.

Remote MKV previews depend on server HTTP seek/range support and network
latency. This is a new extraction path, tested by CI for compilation, not
yet verified on physical Apple TV for every MKV/HEVC/Dolby Vision variant.

## Build

The GitHub Action `native-apple-tv.yml` generates a dedicated Xcode project
using XcodeGen, builds against the same pinned tvOS MPVKit binary package as
the last working Plezy build, and packages an **unsigned** tvOS IPA.
Sign it using a tvOS provisioning profile before installing.

This is a first native prototype. A passing CI build does not validate actual
DV output or thumbnail latency from real remote MKV/DV files.
