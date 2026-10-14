# Camdeck 1.0 scope

Camdeck sets up your webcam and gets out of the way. No virtual camera, no video pipeline, no effects engine. Settings are written to the camera, so every app sees them.

**Rule:** a feature ships only if it ends in a UVC/XU write to the camera. Anything that renders, re-encodes or continuously analyzes video is out.

## In

**Reliability**
- Auto-restore settings on reconnect (IOKit attach notification, no polling)
- Watchdog: re-apply when another app (Zoom, Teams) resets controls; triggered by camera-in-use events, not a timer
- Multi-camera identity (per-device settings keyed by serial / location ID)
- USB speed warning (camera on USB 2 or a slow hub)

**Full control**
- Every UVC control the device exposes, plus reset to defaults
- Manual shutter/gain readout
- Max-quality format pick
- PTZ presets
- Link 2C modes via XU, gesture toggle
- Framing controls; face detection runs on demand only, never always-on

**Presets and zebra**
- Looks = saved presets, not live analysis
- Zebra in the preview (the only preview overlay)

**Automation**
- Global hotkeys
- CLI, URL scheme, JSON import/export
- Shortcuts actions
- Per-app presets, driven by camera-in-use events

**Distribution**
- Notarized build, Homebrew cask, one-page site

## Out

| Cut | Why |
|---|---|
| Virtual camera, backgrounds, LUTs, beauty, overlays, chroma key | Renders video |
| Teleprompter, floating self-view, capture | Renders video |
| Histogram/waveform, before/after, framing guides | Preview chrome |
| Deeper Apple video effects | Thin wrapper on Apple's own UI |
| Firmware updater | Bricking risk; vendor's job |
| "Fix my picture" (face-metered exposure/WB/backlight, focus lock, flicker detect) | Dropped: one-shot auto-tuning gave poor results on real cameras |
| Preset marketplace, calendar triggers, sync | Services, not camera control |

## Two wording constraints

- **"No background process" is not literally true.** Restore, watchdog, hotkeys and per-app presets need a running app. The claim is: opt-in menu-bar app, event-driven, near-zero CPU when idle, no video pipeline. Say "nothing runs unless you want it to", as the README already does.
- **"Stored on the camera" holds only while it's powered.** Most UVC cameras drop settings on unplug; that is why auto-restore exists. Say "written to the camera", not "stored on".
