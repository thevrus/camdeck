import Foundation

public struct UVCOption: Hashable, Sendable {
    public var value: Int
    public var label: String
    public init(_ value: Int, _ label: String) { self.value = value; self.label = label }
}

/// A standard UVC control (camera terminal or processing unit).
public struct UVCControl: Identifiable, Hashable, Sendable {
    public enum Unit: Sendable { case cameraTerminal, processingUnit }
    public enum Widget: Hashable, Sendable {
        case slider, toggle, picker([UVCOption]), panTilt
    }
    public enum Group: Sendable { case view, image }

    public let id: String
    public let name: String
    public let unit: Unit
    public let selector: UInt8
    /// Payload size in bytes.
    public let size: Int
    /// Number of packed values (2 for pan/tilt).
    public let valueCount: Int
    public let signed: Bool
    /// Bit position in the unit's bmControls.
    public let bit: Int
    public let widget: Widget
    public let group: Group

    init(_ id: String, _ name: String, _ unit: Unit, sel: UInt8, size: Int, count: Int = 1,
         signed: Bool = false, bit: Int, widget: Widget = .slider, group: Group) {
        self.id = id; self.name = name; self.unit = unit; self.selector = sel; self.size = size
        self.valueCount = count; self.signed = signed; self.bit = bit; self.widget = widget; self.group = group
    }

    public func decode(_ bytes: [UInt8]) -> [Int]? {
        let w = size / valueCount
        guard bytes.count >= size else { return nil }
        return (0 ..< valueCount).map { n in
            var u: UInt64 = 0
            for k in 0 ..< w { u |= UInt64(bytes[n * w + k]) << UInt64(8 * k) }
            if signed {
                let shift = UInt64(64 - 8 * w)
                return Int(Int64(bitPattern: u << shift) >> Int64(shift))
            }
            return Int(u)
        }
    }

    public func encode(_ values: [Int]) -> [UInt8] {
        let w = size / valueCount
        var out = [UInt8](repeating: 0, count: size)
        for n in 0 ..< min(valueCount, values.count) {
            let u = UInt64(bitPattern: Int64(values[n]))
            for k in 0 ..< w { out[n * w + k] = UInt8((u >> UInt64(8 * k)) & 0xFF) }
        }
        return out
    }

    /// CT ae-mode bitmap: auto (2) or aperture priority (8) means the camera drives exposure time.
    public static func isAutoExposure(_ mode: Int) -> Bool { mode & 0x0A != 0 }

    public static let all: [UVCControl] = [
        // Camera terminal
        UVCControl("ae-mode", "Auto Exposure", .cameraTerminal, sel: 0x02, size: 1, bit: 1, widget: .toggle, group: .image),
        UVCControl("exposure", "Exposure", .cameraTerminal, sel: 0x04, size: 4, bit: 3, group: .image),
        UVCControl("focus-auto", "Autofocus", .cameraTerminal, sel: 0x08, size: 1, bit: 17, widget: .toggle, group: .view),
        UVCControl("focus", "Focus", .cameraTerminal, sel: 0x06, size: 2, bit: 5, group: .view),
        UVCControl("zoom", "Zoom", .cameraTerminal, sel: 0x0B, size: 2, bit: 9, group: .view),
        UVCControl("pantilt", "Pan / Tilt", .cameraTerminal, sel: 0x0D, size: 8, count: 2, signed: true, bit: 11, widget: .panTilt, group: .view),
        UVCControl("roll", "Roll", .cameraTerminal, sel: 0x0F, size: 2, signed: true, bit: 13, group: .view),
        // Processing unit
        UVCControl("brightness", "Brightness", .processingUnit, sel: 0x02, size: 2, signed: true, bit: 0, group: .image),
        UVCControl("contrast", "Contrast", .processingUnit, sel: 0x03, size: 2, bit: 1, group: .image),
        UVCControl("hue", "Hue", .processingUnit, sel: 0x06, size: 2, signed: true, bit: 2, group: .image),
        UVCControl("saturation", "Saturation", .processingUnit, sel: 0x07, size: 2, bit: 3, group: .image),
        UVCControl("sharpness", "Sharpness", .processingUnit, sel: 0x08, size: 2, bit: 4, group: .image),
        UVCControl("gamma", "Gamma", .processingUnit, sel: 0x09, size: 2, bit: 5, group: .image),
        UVCControl("wb-auto", "Auto White Balance", .processingUnit, sel: 0x0B, size: 1, bit: 12, widget: .toggle, group: .image),
        UVCControl("wb-temp", "White Balance", .processingUnit, sel: 0x0A, size: 2, bit: 6, group: .image),
        UVCControl("backlight", "Backlight Comp.", .processingUnit, sel: 0x01, size: 2, bit: 8, group: .image),
        UVCControl("gain", "Gain", .processingUnit, sel: 0x04, size: 2, bit: 9, group: .image),
        UVCControl("powerline", "Power Line", .processingUnit, sel: 0x05, size: 1, bit: 10,
                   widget: .picker([UVCOption(0, "Off"), UVCOption(1, "50 Hz"), UVCOption(2, "60 Hz"), UVCOption(3, "Auto")]), group: .image),
    ]

    /// Controls whose bmControls bit is set in the given descriptor topology.
    public static func availableControls(in topology: UVCTopology) -> [UVCControl] {
        all.filter { c in
            switch c.unit {
            case .cameraTerminal: return topology.cameraTerminal?.supports(bit: c.bit) ?? false
            case .processingUnit: return topology.processingUnit?.supports(bit: c.bit) ?? false
            }
        }
    }
}

/// A control plus everything read from the device.
public struct UVCControlState: Identifiable, Sendable {
    public var control: UVCControl
    public var min: [Int]?
    public var max: [Int]?
    public var res: [Int]?
    public var def: [Int]?
    public var cur: [Int]?
    /// GET_INFO capability byte (bit0 GET, bit1 SET, bit2 disabled by automatic mode).
    public var info: UInt8?
    public var id: String { control.id }
    public var canSet: Bool { (info ?? 0x03) & 0x02 != 0 }
}
