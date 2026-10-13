# Insta360 Link 2C (2E1A:4C03) control notes

Verified on this unit unless marked otherwise.

## Topology (verified, config descriptor)
- VC interface 0. CT 1 bmControls 0x027A20 (focus abs/auto, zoom abs, pan/tilt abs+rel, roll abs+rel). No exposure.
- PU 5 bmControls 0x145F (brightness, contrast, hue, saturation, sharpness, WB temp, WB auto, power line).
- XU 9 {FAF1672D-B71B-4793-8C91-7B1C9B7F95F8}, XU 10 {E307E649-4618-A3FF-82FC-2D8B5F216773}, XU 11 {A8BD5DF2-1A98-474E-8DD0-D92672D194FA}. Resolve by GUID, not ID.

## Transport rules
- DeviceRequest on EP0 without opening the device works (GET verified).
- Do NOT poll the control endpoint fast: ~400 req/s collided with the vendor app (stall 0xe000404f, timeout 0xe0004051) and crashed it. Keep polling <= a few req/s, coalesce writes.
- Camera re-enumerates on some mode changes; handle hotplug.
- Prior art: vendor writes only stick while streaming; selector 2 must be read-modify-write; size from GET_LEN.
- NEVER SET XU9 selector 17 (USB mode switch / firmware path).

## Selector observations (verified reads)
| Unit/Sel | Len | Meaning |
| --- | --- | --- |
| 9/2 | 61 | AI mode record. Byte 0 = 7 when Auto Framing on (vendor log: "set video mode: 7"), 0 off. Bytes 38-41 move with subject. |
| 9/3 | 234 | Hardware IDs (ASCII) |
| 9/12 | 32 | Serial "IBNLA25128JG3D" |
| 10/1 | 8 | Byte 4 slowly drifts 73->66: likely temperature C (unverified) |
| 1/0x0B | 2 | Zoom abs (120 seen at ~1.2x) |

## Verified writes (2026-10-13, read-back + frame-luma meter)
| Control | Unit/Sel | Encoding | Evidence |
| --- | --- | --- | --- |
| AE mode | 9/30 | u8: 2 auto, 1 manual | ISO/shutter only take effect in manual |
| EV comp | 9/9 | i16 LE, EV x100 (vendor UI 0.6 = 60), use -300..300 | -2.0 luma 46, +2.0 luma 130 |
| ISO | 9/25 | u16 LE (100..?), manual AE only | 100 luma 112, 800 luma 191 |
| Shutter | 9/29 | u16 LE, 1/N s, quantized (30 reads back 29) | 1/30 luma 183, 1/250 85, 1/1000 39 |
| HDR | 9/27 bit 2 | RMW of u16 LE feature mask (idle 0x01C0) | off 88, on 136 |
| Auto Framing | 9/2 byte0=7 | Write persists but camera does NOT frame, even with the fmontes sequence (mode 0, target 9/21, 550 ms, mode 7). 9/27 bit 8 already set. Byte1 forced to 0x10 by firmware. Vendor log shows host-side algorithm (alg_fps_monitor ~30 fps, host pitch, rect clears): on 2C (no gimbal) framing is computed on the Mac. Camdeck implements it in software (Vision + CT zoom/pan/tilt). |
GET_MIN/MAX on XU selectors return junk (zeros); hardcode ranges.

## Vendor app log (passive RE source)
`~/Library/Application Support/Insta360 Link Controller/log/<date>/*.log`; `uvc_camera_mac.cc` logs "send <bits>" plus semantic lines ("set HDR: 1", "set gesture to 1", "set video mode: N").
- HDR on: send 0000000111000100 ... feature mask writes (likely XU9 sel 27); gestures: sel 5 bitmask ("send 00000010").

## Prior art (Link 1/2, unverified on 2C)
Mode bytes on 9/2: normal 0, track 1, whiteboard 4, overhead 5, deskview 6 (2C uses 7 for auto framing: differs).
Sel 27 = 2-byte feature mask (bit 2 HDR, 3 mirror, 4 gesture zoom, 8 tracking, 11 privacy). Sel 5 gesture mask, 0x13 framing, 0x1E AE mode, 0x09 EV, 0x19 ISO, 0x1D shutter.
Repos: fmontes/insta360-link-cli (macOS, closest), csmarshall/link-ctl, schlarpc/insta360-link-firmware-re, satishlokkoju/insta360_link_control. 

## Other vendors
- OBSBOT Tiny 2 (3564:fef8): XU GUID {9a1e7291-6843-4683-6d92-39bc7906ee49}, sel 6 60-byte TLV (AI mode tag 0x16, HDR 0x01, FOV 0x04). Meet 4K same TLV on unit 6.
- Opal C1 (03e7:f63d): XU 4 GUID all-FF, 80 controls, no public map. Tadpole: nothing.

## Software auto framing (2026-10-13, measured on this unit)
- CT zoom abs (1/0x0B) works: digital crop, sticks, 100..400.
- CT pan/tilt abs (1/0x0D) writes are accepted and read back (up to 252000 at zoom 400) but do NOT move the image: Vision translational registration of before/after frames |shift| < 0.003 frame for pan +-36000 @2x, +36000 @1x/3x/4x, +108000 @2x, +252000 @4x, tilt +-36000 @2x, +180000 @4x; saved frames visually identical. Values also revert to 0 about 2 s after a write (no capture in our process needed; cause unknown, vendor log shows no PTZ writes).
- Consequence: CT pan/tilt is unused on the 2C. Auto framing uses the XU9 sel 2 Reframe capability (zoom + reframe). See ADR-001 "Link 2C specifics" for the calibration. Re-check with `uvcctl framing-calibrate` / `uvcctl framing-probe <zoom> <pan> <tilt> [s]` (SAVE_DIR=dir saves frames, READBACK=1 logs CT reads) after firmware updates.
- Diagnostics: `uvcctl pt-test z200 p36000,0 x x` writes/reads CT zoom and pan/tilt only. `uvcctl framing-run [s] [mode]` runs the app's FramingEngine headless (START_ZOOM=n to start zoomed in). All tools space USB writes >= 350 ms and restore the original zoom/pan/tilt on exit or Ctrl-C.

## To test — from Link 1/2 prior-art dig (2026-10-13, unverified on 2C)
Source: vrwallace/Insta360-Link-1-and-2-Controller-for-Linux (Windows-monitored XU map, selectors 1-20 only, so it never saw our 9/25-9/30 finds and its "HDR/gesture/privacy not controllable" claims are wrong for the 2C — ignore those).
- **9/13, 129 bytes (Windows-monitored; SET-only is NOT stated for this selector)**: relative pan/tilt on Link/Link2. The `[signX, magX, signY, magY]` layout (sign 0=stop/1=pos/0xFF=neg, mag 0-30) is only a code comment in vrwallace's `PanTiltRelative`; its implementation never actually writes XU 13 (it uses V4L2 absolute pan/tilt instead), so the byte layout is unexercised. Our CT pan/tilt (1/0x0D) writes don't move the image — this may still be the real hardware pan path, but treat the layout as a guess. Probe order: GET_LEN/GET_INFO on 9/13 and 9/14 first (read-only); if present, one small write (sign 1, mag 5) measured with the existing Vision registration probe (`uvcctl framing-probe`). If it moves the image, zoom-only framing (ADR-001) should be revisited.
- **9/14, 1 byte, SET-only**: gimbal reset (write 0x01) on Link. 2C has no gimbal — leave out of the profile until GET_INFO confirms what it is here.
- **9/19 (0x13), 1 byte**: tracking frame size on Link — 1 head, 2 half body, 3 full body. Read-only GET_CUR while toggling vendor-UI framing size would confirm whether firmware also reads this on the 2C.
- **10/1 byte 4**: Link docs say this is a tracking-target enum (0 single, 1 group) — doesn't match our observed drift 73->66 (see Selector observations table above), so "likely temperature" is probably wrong; downgrade to "semantics unknown." Do not write it.
- **9/2 byte 1**: forced to 0x10 by firmware on our mode-7 write; matches Link's "DeskView" flag value in the same byte, so likely a firmware-derived mode-class flag rather than host-settable.
- **Link 2 is PID 2E1A:4C04**, documented with the same XU9/10/11 GUIDs as Link 1 and (per our notes) the 2C. Add 4C04 as a second candidate PID in the Insta360 profile match (GUID-based resolution already covers it; this just widens device detection).

## Borrowed engineering notes (not protocol, from CameraController/uvc-util/YaUVC dig)
- Camdeck's "never open the USB device" design (EP0 `DeviceRequest` only) is confirmed to be the right call: codetheweb/CameraController's zoom-grayed-out bug on macOS 12+ comes from opening the VideoControl interface, which the system UVC stack now holds exclusively. No entitlement needed for our approach; if Camdeck is ever sandboxed, `com.apple.security.device.usb` is the only one required.
- If two identical cameras are ever attached, upstream CameraController matches `AVCaptureDevice.uniqueID` by `locationID` prefix (`"0x" + String(locationID, radix: 16)`) to tell them apart — a reusable heuristic if that case comes up.
- `uvc-util` and Huddly `YaUVC` have no GUID-resolved XU handling, rate limiting, or RMW locking — nothing else to borrow from either.

## Natural defaults (vendor UI)
Insta360 Link Controller default Image settings, matching the camera's live state: HDR on, WB auto, AE auto, EV +0.6, AF on, brightness/contrast/saturation 50, sharpness 26, anti-flicker 60 Hz. Firmware GET_DEF sharpness is 50, so the profile's `naturalDefaults` override GET_DEF (applyNaturalDefaults).
