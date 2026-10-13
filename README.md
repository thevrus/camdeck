# Camdeck: webcam controller for Mac

Native macOS app to control your USB webcam: Insta360 Link 2C, OBSBOT, Opal and any UVC camera. Zoom, pan, tilt, exposure, white balance, auto framing and presets in one small window. A lightweight open source alternative to Insta360 Link Controller, OBSBOT Center and Opal Composer.

## Why

Every webcam vendor ships its own control app. They are heavy, Electron or Qt, sit in the menu bar forever, and only talk to that vendor's camera. Switch cameras and you need another one.

Camdeck replaces them with a single native SwiftUI app that speaks UVC directly over user-space USB control requests. No kernel extension, no driver install, no background daemon.

| Vendor app | Camdeck |
| --- | --- |
| Hundreds of MB, Qt or Electron | A few MB, Swift and SwiftUI |
| One brand only | Any UVC webcam |
| Opaque vendor features | Vendor features via open JSON profiles and small code drivers |
| Always running | Opens when you need it, optional menu bar item |

## What it does

- **Live preview** with mirror, resolution and frame rate picker.
- **Image controls** for brightness, contrast, saturation, sharpness, white balance, focus and anti-flicker on any UVC camera.
- **Exposure** with auto and manual modes, plus vendor extras where the profile knows them (ISO, shutter, HDR, compensation).
- **Zoom and pan/tilt** with a draggable pad, including digital reframe on cameras whose standard pan/tilt is a no-op.
- **Auto framing** on any camera that can zoom and reframe, using the Vision framework to keep you centered.
- **Presets** to save and recall a full camera state, and a settings lock that keeps firmware from drifting.
- **Zebra overlay** to spot clipped highlights.
- **macOS video effects** such as Portrait, Studio Light and Background from one row.
- **Menu bar mode** and open at login.
- **`uvcctl`** command line tool to dump descriptors and read or write controls while adding support for a new camera.

## Supported cameras

Any UVC webcam gets image, exposure, zoom, focus and white balance on day one. That includes Logitech Brio and C920, Elgato Facecam, Razer Kiyo, Anker PowerConf and most others.

| Camera | Replaces | Extras | Status |
| --- | --- | --- | --- |
| Insta360 Link 2C | Insta360 Link Controller | Digital pan/tilt, ISO, shutter, HDR, exposure mode, serial and firmware info | Verified on hardware |
| Insta360 Link 2, Link | Insta360 Link Controller | Same protocol family | Untested |
| AnkerWork C310, PowerConf C200 | AnkerWork app | Field of view, HDR and flip (C200), face focus and exposure, mic noise reduction and pickup (C310) | Experimental, unverified on hardware |
| OBSBOT Tiny 2, Tiny SE, Meet | OBSBOT Center | Mechanical PTZ via TLV protocol | Planned |
| Opal Tadpole, C1 | Opal Composer | | Planned |

Have one of the planned cameras? Open an issue with the output of `uvcctl` and we can add it.

## FAQ

**Does it work without the Insta360 Link Controller app?**
Yes. Camdeck talks to the camera directly over USB. You can uninstall the vendor app.

**Does it work in Zoom, Google Meet, Teams, OBS?**
Yes. Settings are written to the camera itself, so every app sees the same image.

**Does it install a driver or kernel extension?**
No. It uses plain user-space UVC control requests. Nothing runs in the background unless you turn on the menu bar item.

**Is it Apple Silicon native?**
Yes. Swift and SwiftUI, built for macOS 26.

## Install

Requires macOS 26 and Xcode 26 command line tools.

```sh
git clone https://github.com/thevrus/camdeck.git
cd camdeck
make app      # builds build/Camdeck.app
make run      # builds and opens it
make test     # runs the UVCKit test suite
```

## How it works

```
App (SwiftUI, AutoFramer)
    │  capabilities only: Zoom, Reframe, Exposure, ImageControls…
    ▼
Camera (composed per device)
    ▲  most specific driver wins per capability
    │
    GenericUVCDriver   standard UVC, from the descriptor
    ProfileDriver      JSON profile for simple vendor controls
    Code drivers       Swift, for protocols that need logic
    │
    ▼
UVCTransport (IOKit EP0, rate limited, forbidden selector guard)
```

The app never knows which camera is attached. It asks for capabilities. Drivers provide them. USB safety rules live in one place.

Details in [docs/adr-001-camera-drivers.md](docs/adr-001-camera-drivers.md). The Link 2C protocol notes are in [docs/link2c-protocol.md](docs/link2c-protocol.md).

## Adding a camera

1. Plug it in and run `uvcctl` to dump its descriptor.
2. Standard controls already work.
3. Map simple vendor controls in a JSON profile. Schema in [docs/profile-schema.md](docs/profile-schema.md).
4. Write a code driver only for features that need logic.
5. Add the descriptor as a test fixture.

## License

MIT
