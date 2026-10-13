# AnkerWork C310 (291A:3367) and PowerConf C200 (291A:3369) control notes

**Unverified on hardware.** Nobody here owns either camera. Everything below comes from two open-source tools and public `lsusb -v` probes, cross-checked against each other. Profiles: `Sources/UVCKit/Resources/Profiles/ankerwork-c310.json`, `anker-powerconf-c200.json`. Status in the README: experimental.

Sources:
- C200: [erans/anker-powerconf-c200-linux-tools](https://github.com/erans/anker-powerconf-c200-linux-tools) @ 1912f86 (`src/c200_vendor.c`, `src/c200_fov.c`, `src/c200_controls.c`, `README.md`). Author confirms on a C200, `291a:3369`.
- C310: [soyersoyer/cameractrls](https://github.com/soyersoyer/cameractrls) @ 6f38825, `cameractrls.py` lines 1790-2083 (`ANKERWORK_*`, `AnkerWorkCtrls`). Matches `291a:3367` only.
- Descriptors: linux-hardware.org probes `ab0a6cc352` (C200) and `abb07364c1` (C310, bcdDevice 8.21).

## Topology
- C200 (probe, verified against source): a single XU, unit 6, `{6CB3ABAC-B431-5316-C4AC-D27A1F11A12E}`, 15 controls, bmControls `00 f8 27`. That advertises selectors 0x0C-0x10, 0x11, 0x12, 0x13 and 0x16. Unit 6 matches `C200_VENDOR_UNIT_ID 0x06` in the tool. The tool never names the GUID, so the GUID comes from the probe.
- C310 (cameractrls): XU `41769ea2-04de-e347-8b2b-f4341aff003b`, given as LE bytes `a2 9e 76 41 de 04 47 e3 8b 2b f4 34 1a ff 00 3b`, found by GUID (unit ID not given).
- **Conflict:** the one public C310 probe (fw 8.21) has four XUs and none of them is that GUID: unit 6 `{A40261F4-869A-9071-881E-99549794BF60}`, unit 8 `{580E91FF-19E5-7C27-BBF9-08E1BB11AD68}`, unit 7 `{050C9A90-EB04-ACA6-208C-D4A67E54C7E6}`, unit 3 `{01FE5C92-BECD-4BE9-A098-F66B069BEF8B}`. Most likely the firmware differs. On such a unit the C310 profile offers nothing, because a missing GUID means the control is not offered. Do not map these GUIDs to the cameractrls selectors without a capture.
- The two models use different GUIDs, so there are two profile files, not one.

## Transport rules
- Every vendor selector is an opaque buffer. Its size comes from GET_LEN: C200 FoV is 60 (tool README; the vendor macOS app stages 64 bytes, but the real length is 60). C310 lengths in cameractrls are fixed: FoV 7, 0x0B 2, 0x1F 2, others 1. Linux uvcvideo rejects XU GET_CUR/SET_CUR whose size differs from GET_LEN, so these are presumably the GET_LEN values (inference).
- Camdeck uses the `u8-at-offset` / `u16le-at-offset` encodings: GET_LEN, GET_CUR, change this control's bytes, SET_CUR the whole buffer.
- The C200 tool does *not* read-modify-write. It zeroes the buffer, sets byte 0 (flags), or for FoV writes `00 01` at bytes 0-1 plus the value at bytes 2-3. Camdeck keeps whatever GET_CUR returned in bytes 0-1. If the firmware does not echo `00 01` on read, FoV writes may be ignored. **First thing to check on hardware.** cameractrls compares the full 7-byte C310 read-back against `00 01 xx 00 00 00 00`, which suggests the C310 does echo it.
- No dangerous selectors are known. None are forbidden, and Camdeck writes only the selectors listed below.

## Selectors in the profiles
| Model | Sel | Len | Offset / width | Meaning | Source |
| --- | --- | --- | --- | --- | --- |
| C200 | 0x10 | 60 | 2, u16 LE | FoV 65 narrow / 78 medium / 95 wide | `c200_fov.c` (`value_offset` 2), README |
| C200 | 0x13 | GET_LEN | 0, u8 | HDR 0/1 | `c200_vendor_get/set_bool` (`payload[0]`) |
| C200 | 0x11 | GET_LEN | 0, u8 | Horizontal flip 0/1 | same |
| C310 | 0x10 | 7 | 2, u16 LE | FoV 65 / 78 / 95 (see label conflict) | `ANKERWORK_FOV_*` |
| C310 | 0x1B | 1 | 0, u8 | Face focus 0/1 | `ANKERWORK_FACE_FOCUS_*` |
| C310 | 0x0B | 2 | 0, u8 | Face exposure compensation on/off | `setup_ctrls` keeps byte 1, sets byte 0 |
| C310 | 0x0B | 2 | 1, u8 | Face exposure amount 0-100; 0 = -3.5 EV, 35 = 0 EV, 100 = +6.5 EV | `_map_comp_to_int` (`value << 8`) |
| C310 | 0x1D | 1 | 0, u8 | Mic AI noise reduction 0/1 | `ANKERWORK_MIC_AI_NOISERED_*` |
| C310 | 0x1F | 2 | 0, u16 LE | Mic pickup 0 = 360°, 0x5A = 90° | `ANKERWORK_MIC_PICKUP_*` |

FoV label conflict: the C200 tool says wire 65 = narrow and 95 = wide, confirmed from source — C200 keeps degree labels. cameractrls labels the C310's wire 0x5F (95) as "65°" and 0x41 (65) as "95°", the reverse, and the direction could not be independently confirmed (re-checked against `cameractrls.py` main and the only public C310 descriptor, fw 8.21, which doesn't expose this XU GUID at all — see Topology conflict above). The C310 profile uses neutral "Narrow/Medium/Wide" labels with no degree numbers instead of guessing. Settle on hardware with a `uvcctl` read-back + visible image change, then add the confirmed degree numbers back.

The face exposure amount slider shows the raw 0-100 value. The schema scales but cannot offset, so it cannot show EV.

## Known but left out
| Model | Sel | Why |
| --- | --- | --- |
| C310 | 0x13 HDR | Broken per source: "FIXME: This do seems to be the right selector toggled but nothing on Linux happens." |
| C310 | 0x11 horizontal flip | Broken per source: "FIXME: Nothing seems to work with this." |
| C310 | 0x10 auto / "Solo Frame" | Payload `02 01 5f 00…`: byte 0 = 2 together with a fixed FoV byte. A coupled two-field write, unverified as a standalone byte 0 write. Note: if the camera is in this mode, RMW FoV writes keep byte 0 = 2 and may not leave it. |
| C310 | 0x18 exposure point | Raw captures only ("TODO: Raw data below"), 9 bytes, layout unknown. |
| C200 | 0x12 anti-flicker | Offset 0 u8 is confirmed, but the tool writes a raw number with no value meanings. Standard UVC power-line frequency already covers it. |
| C200 | 0x0A vertical screen | Listed in the tool, but not advertised in the probe's bmControls (bit 9 clear). On Linux, uvcvideo would refuse an unadvertised selector, so it may not exist on all firmware. Offset/semantics otherwise as the bool controls. |
| C200 | 0x0C-0x0F, 0x16 | Advertised in bmControls, meaning unknown. |
| C200 | mic, face controls | No source for the C200. |

## To verify on hardware (read-only first)
1. `uvcctl` descriptor dump: confirm the XU GUID per model (C310 especially).
2. GET_LEN and GET_CUR on each listed selector; check C200 0x10 bytes 0-1 read `00 01`.
3. One FoV write each way, with read-back and a visible image change; settle the C310 label direction.
