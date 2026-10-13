# ADR-001: Camera driver architecture

Status: accepted, 2026-10-13

## Context
Camdeck must work with any UVC webcam, and also unlock vendor features where we know the protocol. Findings so far:
- Standard UVC (camera terminal and processing unit) works on every camera, but vendors deviate from it. On the Link 2C, standard pan/tilt is accepted and read back, yet does nothing to the image.
- Simple vendor controls (a scalar or a bit in an extension unit) fit in data: JSON profiles, as already shipped for exposure and HDR.
- Some features need logic that JSON cannot express:
  - Link 2C digital pan/tilt is read-modify-write of a 61-byte record (XU9 sel 2, bytes 38-41).
  - OBSBOT uses TLV frames with sequence numbers and CRC.
  - Insta360 tracking needs ordered sequences with delays.
- The app must not care which camera it is. Auto framing needs "zoom and reframe", not "XU9 sel 2".
- Hard lessons:
  - Fast polling crashed the vendor app.
  - Some selectors are dangerous (XU9 sel 17).
  - Firmware may revert vendor writes unless streaming.

## Decision
Three layers behind capability protocols. The app talks only to capabilities.

```
App (CameraController, AutoFramer, UI)
        │  uses capabilities only
        ▼
Camera (composed per device)
  capabilities: ImageControls, Exposure, Zoom, Reframe (pan/tilt), DeviceInfo,
                HardwareFraming?, HardwarePresets?, Privacy?   (optional = unsupported)
        ▲  provided by, most specific wins per capability
        │
  1. GenericUVCDriver   standard CT/PU from the descriptor bitmaps  (any UVC camera)
  2. ProfileDriver      JSON profile: simple XU scalars/bits, naturalDefaults, forbidden selectors
  3. Code drivers       Swift, for protocols needing logic: Insta360LinkDriver, later OBSBOTDriver
        │
        ▼
UVCTransport  (IOKit EP0 DeviceRequest, no open/seize)
  - global rate limiter and serial queue (one place enforces USB politeness)
  - forbidden-selector guard (from every loaded profile/driver)
  - descriptor parse: unit IDs resolved by GUID, never hardcoded
```

- **DriverRegistry** matches each driver by VID/PID and XU GUID presence. It composes Generic + Profile + Code for the device. Each capability is taken from the most specific driver that provides it. For example, Insta360LinkDriver overrides `Reframe` because CT pan/tilt is a no-op on the 2C.
- **Capabilities** expose normalized units: zoom factor 1.0…N; reframe as center x/y in −1…1 of the available crop travel; plus ranges. Auto framing and the mini-map work in these units for every camera.
- **Missing capability = feature hidden.** No Reframe and no Zoom means no auto framing. We never do a software crop, because that needs a virtual camera, which is out of scope (bloat).
- **Adding a camera:**
  1. Dump its descriptor with `uvcctl`.
  2. Generic works immediately.
  3. Map simple vendor controls in a JSON profile.
  4. Write a code driver only for logic-heavy features.
  5. Add the descriptor fixture and tests.

## Consequences
- Pro: any UVC webcam gets image, zoom, focus, WB and exposure on day one. Vendor support grows incrementally. Auto framing works on any camera with a working Zoom and Reframe, including mechanical PTZ cameras such as OBSBOT.
- Pro: USB safety rules live in one place, the transport.
- Con: more types. Code drivers are kept small and capability-scoped.
- Not doing: cross-platform transports (Mac only for now; the transport boundary allows it later), virtual camera, kernel drivers or DriverKit. Plain user-space control requests are enough; no driver install is needed.

## Link 2C specifics (verified on hardware 2026-10-13, firmware v3.2.7.8_build2)
- Reframe: XU9 sel 2, RMW of u16 LE values. Byte 38 holds X and byte 40 holds Y; 0x7FFF is center. Implemented in `Insta360LinkDriver` (`LinkReframe`, `Link2CReframeMapping`).
- Calibration (`uvcctl reframe-calibrate`, `reframe-chain`; Vision translational registration, writes >= 400 ms apart):
  - Raw is an absolute crop-center position: shift (fraction of the 1x frame) = (raw - 0x7FFF) / 65536, the same at every zoom. Measured: 2x 0x800 -> 0.0625 output frame (0.031 of 1x); 3x 0x800 -> 0.0935 output (0.031 of 1x); 4x 0x1000 -> 0.125 output (0.031 of 1x). Linear; the image moves in steps of about 1/32 output frame.
  - Sign: raw above 0x7FFF moves the view right (X) / down (Y).
  - Firmware clamp (read back after a write): +-65536 * ((1 - 1/z)/2 - 0.01). Measured 1x 0 (no reframe at 1x at all), 2x +-15728 (0x3D70), 3x +-21190, 4x +-23920 (0x5D70). That is the crop edge minus 1% of the frame. Shift at the 2x clamp: 0.486 output frame.
  - Y works like X, measured against frame height. Writes persist (still there after 3 s and after a zoom change 2x -> 3x).
  - Normalized center c (-1...1) is relative to the clamp at the current zoom: raw = 0x7FFF + c * clamp(z).
- Caution, byte 50 (zoom, u16 LE) sits in the same record. A sel 2 write carries the zoom value that was read. In some runs a zoom write followed by a sel 2 write left the zoom at another value (380 -> 360, 399 -> 100). It did not reproduce in isolation (`uvcctl ramp-test`), and Camdeck was being relaunched during those runs, so the cause is unconfirmed. Mitigation (in place): reframe writes now carry the commanded zoom in byte 50 instead of the stale read.
- Zoom: standard CT 0x0B works (also reported in XU9 sel 2 byte 50).
- CT pan/tilt (0x0D): accepted, no effect, reverts after about 2 s. `Insta360LinkDriver` marks it `.ctPanTiltIneffective` for PID 0x4C03, so `GenericUVCDriver` does not offer CT reframe.
- Device info: XU9 sel 3 (firmware at offset 97 len 15 "v3.2.7.8_build2", UUID at 33 len 36, model at 170 len 10 "Insta Puc2") and sel 12 (serial, 32 bytes). Fixtures: `Tests/UVCKitTests/Fixtures/link2c_xu9_sel3.txt`, `link2c_xu9_sel12.txt`.

## Addendum: scalars inside a device-sized buffer (2026-10-13)
- Context: Anker cameras (AnkerWork C310, PowerConf C200; see [anker-protocol.md](anker-protocol.md)) keep each vendor control as 1 or 2 bytes inside an opaque XU buffer. Its length is whatever GET_LEN reports: 7 bytes for C310 field of view, 60 for C200. Every existing encoding has a fixed size known to the JSON.
- Decision: two new profile encodings, `u8-at-offset` and `u16le-at-offset`. `ProfileEncoding.size` is nil for them, and `UVCDevice.readProfile/writeProfile` then ask GET_LEN. Writes are always read-modify-write of the whole buffer (validated, as for `bit-in-u16le`). A read that comes back shorter than GET_LEN is never written back.
- Why not a code driver: by this ADR's own rule this is a plain scalar or flag. There is no sequencing, no CRC, no multi-step state, and no capability beyond `profileControls`. Only the buffer length is dynamic. A driver would duplicate the profile interpreter just to call GET_LEN.
- Generalizes to the same shape elsewhere ("short opaque command in a vendor XU"), for example Razer Kiyo Pro/Ultra and Dell WB7022. Nothing is implemented for those here. Each still needs its own source-verified offsets.
- Limit: an offset write keeps every other byte as read. If a firmware wants fixed marker bytes on SET that GET_CUR does not echo, this encoding cannot express it, and that control needs a code driver or a further schema extension.
