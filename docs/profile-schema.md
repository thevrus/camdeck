# Device profile schema

Profiles are JSON files in `Sources/UVCKit/Resources/Profiles/`, loaded through `Bundle.module` by `VendorProfiles`. Swift code is a generic interpreter (`DeviceProfile`, `ProfileControl`, `UVCDevice.readProfile/writeProfile`); nothing about a device is hardcoded. A file that fails to decode or validate is logged and skipped.

## Top level

| Key | Type | Notes |
| --- | --- | --- |
| `name` | string | Shown as the vendor section title. |
| `match.vendorID` | int or `"0x2E1A"` | Required. |
| `match.productIDs` | array, optional | Omit to match every product of the vendor. |
| `units` | object | Alias to extension-unit GUID. Unit IDs are never written down: they are resolved at runtime from the parsed descriptor (`UVCTopology.extensionUnits`). |
| `forbiddenSelectors` | array | `{unit, selector, reason?}`. `UVCDevice.set` throws `UVCError.forbidden` for any listed (unit GUID, selector), whoever the caller is. Every loaded profile's list applies. |
| `controls` | array | Ordered; UI order follows file order. |

`unit` in controls and forbidden entries is a key of `units`, or a raw GUID.

## Control

| Key | Notes |
| --- | --- |
| `id` | Stable identifier (used by `uvcctl` and `enabledWhen`). |
| `title`, `symbol` | UI label, SF Symbol name. |
| `section` | `"image"` puts it in the inspector Image section; other names form a section of their own. |
| `unit`, `selector` | Where it lives. |
| `encoding` | `"u8"`, `"u16le"`, `"i16le"`, or `{"type": "bit-in-u16le", "bit": N}`. The bit form is one bit of a 2-byte feature mask; value 0/1. |
| `rmw` | `true`: read the current bytes, change only this control, write back. Required for `bit-in-u16le` (validated). |
| `enabledWhen` | `{"control": "<id>", "equals": <wire value>}`. UI disables (never hides) the control otherwise; `uvcctl set` refuses. |
| `ui` | See below. |

GET_MIN/MAX/RES are not used for extension-unit selectors (they return zeros); ranges come from `ui`.

### `ui`

- `{"kind": "slider", "min", "max", "step", "scale", "format", "default"}`: `min`, `max`, `step`, `default` are in display units; `wire = display * scale`. `format` is a printf format applied to the display value, e.g. `"%+.1f EV"`.
- `{"kind": "toggle"}`: wire 0/1.
- `{"kind": "picker", "options": [{"label", "value"}], "snapToNearest"}`: `value` is the wire value. With `snapToNearest`, a read-back that is not an option (the device quantizes, e.g. shutter 30 reads 29) is shown as the nearest option.

## Interpreter behaviour

- Read once on device attach and after hotplug re-enumeration; no polling of extension-unit selectors. One optional re-read about 300 ms after a write.
- Writes are coalesced at about 30 Hz and serialized by `UVCDevice`'s transfer lock; read-modify-write holds an extra lock across read and write.
- A control whose unit GUID is absent from the descriptor is not offered.
- Unknown cameras get `DeviceProfile.generic` (no controls, vendor UI hidden).

## Example

See `Sources/UVCKit/Resources/Profiles/insta360-link.json`.
