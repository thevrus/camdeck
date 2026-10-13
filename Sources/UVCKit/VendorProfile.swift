import Foundation

// Data-driven vendor profiles. A profile is a JSON file (see docs/profile-schema.md);
// the types below decode it and turn display values into wire bytes and back.

/// Integer that decodes from a JSON number or a "0x2E1A" style string.
public struct HexInt: Codable, Sendable, Hashable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i; return }
        let s = try c.decode(String.self)
        let t = s.lowercased().hasPrefix("0x") ? String(s.dropFirst(2)) : s
        guard let i = Int(t, radix: 16) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an integer: \(s)")
        }
        value = i
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(String(format: "0x%04X", value))
    }
}

public enum ProfileEncoding: Codable, Sendable, Equatable {
    case u8
    case u16le
    case i16le
    /// One bit of a little-endian u16 feature mask. Writes need the current mask (rmw).
    case bitInU16le(bit: Int)

    private enum Keys: String, CodingKey { case type, bit }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            switch s {
            case "u8": self = .u8
            case "u16le": self = .u16le
            case "i16le": self = .i16le
            default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown encoding \(s)"))
            }
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        guard type == "bit-in-u16le" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown encoding \(type)")
        }
        let bit = try c.decode(Int.self, forKey: .bit)
        guard (0 ..< 16).contains(bit) else {
            throw DecodingError.dataCorruptedError(forKey: .bit, in: c, debugDescription: "bit out of range")
        }
        self = .bitInU16le(bit: bit)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .u8: var c = encoder.singleValueContainer(); try c.encode("u8")
        case .u16le: var c = encoder.singleValueContainer(); try c.encode("u16le")
        case .i16le: var c = encoder.singleValueContainer(); try c.encode("i16le")
        case .bitInU16le(let bit):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode("bit-in-u16le", forKey: .type)
            try c.encode(bit, forKey: .bit)
        }
    }

    /// Bytes on the wire.
    public var size: Int { self == .u8 ? 1 : 2 }

    public func decode(_ b: [UInt8]) -> Int? {
        guard b.count >= size else { return nil }
        switch self {
        case .u8: return Int(b[0])
        case .u16le: return Int(b[0]) | Int(b[1]) << 8
        case .i16le: return Int(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8))
        case .bitInU16le(let bit): return (Int(b[0]) | Int(b[1]) << 8) >> bit & 1
        }
    }

    /// `current` is the bytes just read from the device; required for bit encodings, ignored otherwise.
    public func encode(_ v: Int, current: [UInt8]?) -> [UInt8]? {
        switch self {
        case .u8: return [UInt8(clamping: v)]
        case .u16le:
            let u = UInt16(clamping: v)
            return [UInt8(u & 0xFF), UInt8(u >> 8)]
        case .i16le:
            let u = UInt16(bitPattern: Int16(clamping: v))
            return [UInt8(u & 0xFF), UInt8(u >> 8)]
        case .bitInU16le(let bit):
            guard let current, current.count >= 2 else { return nil }
            var mask = UInt16(current[0]) | UInt16(current[1]) << 8
            if v != 0 { mask |= 1 << UInt16(bit) } else { mask &= ~(1 << UInt16(bit)) }
            return [UInt8(mask & 0xFF), UInt8(mask >> 8)]
        }
    }
}

public struct ProfileOption: Codable, Sendable, Equatable {
    public var label: String
    public var value: Int
}

public struct ProfileUI: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case slider, toggle, picker }
    public var kind: Kind
    // slider: min/max/step/default are in display units; wire = display * scale.
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var scale: Double?
    public var format: String?
    public var `default`: Double?
    // picker
    public var options: [ProfileOption]?
    /// Read-back values (the device quantizes) are shown as the nearest option.
    public var snapToNearest: Bool?
}

public struct ProfileCondition: Codable, Sendable, Equatable {
    public var control: String
    /// Wire value the referenced control must hold.
    public var equals: Int
}

public struct ProfileControl: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var symbol: String
    public var section: String
    /// Key into the profile's `units` table (or a raw GUID).
    public var unit: String
    public var selector: Int
    public var encoding: ProfileEncoding
    public var ui: ProfileUI
    public var enabledWhen: ProfileCondition?
    public var rmw: Bool?

    public var needsReadModifyWrite: Bool { rmw ?? false }

    private var scale: Double { ui.scale ?? 1 }

    /// Slider range and step on the wire.
    public var wireRange: ClosedRange<Int>? {
        guard ui.kind == .slider, let lo = ui.min, let hi = ui.max else { return nil }
        return Int((lo * scale).rounded()) ... Int((hi * scale).rounded())
    }
    public var wireStep: Int { max(Int(((ui.step ?? 1) * scale).rounded()), 1) }

    /// Clamps, snaps and quantizes a wire value to what this control can express.
    public func normalize(_ wire: Int) -> Int {
        switch ui.kind {
        case .toggle: return wire != 0 ? 1 : 0
        case .slider:
            guard let r = wireRange else { return wire }
            let s = wireStep
            let snapped = r.lowerBound + Int((Double(wire - r.lowerBound) / Double(s)).rounded()) * s
            return Swift.min(Swift.max(snapped, r.lowerBound), r.upperBound)
        case .picker:
            guard ui.snapToNearest == true, let opts = ui.options, !opts.isEmpty else { return wire }
            return opts.min { abs($0.value - wire) < abs($1.value - wire) }!.value
        }
    }

    public func displayText(_ wire: Int) -> String {
        switch ui.kind {
        case .toggle: return wire != 0 ? "on" : "off"
        case .slider: return String(format: ui.format ?? "%g", Double(wire) / scale)
        case .picker: return ui.options?.first { $0.value == wire }?.label ?? "\(wire)"
        }
    }

    /// Parses user text in display units ("-2.0", "250", "1/250", "auto", "on") to a wire value.
    public func wire(fromDisplay s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        switch ui.kind {
        case .toggle:
            switch t {
            case "on", "1", "true", "yes": return 1
            case "off", "0", "false", "no": return 0
            default: return nil
            }
        case .slider:
            return Double(t).map { Int(($0 * scale).rounded()) }
        case .picker:
            let opts = ui.options ?? []
            if let o = opts.first(where: { $0.label.lowercased() == t }) { return o.value }
            if let n = Int(t), let o = opts.first(where: { $0.value == n }) { return o.value }
            return nil
        }
    }

    /// Wire value -> display units (slider: wire / scale; toggle: 0/1; picker: the option's value).
    public func displayValue(_ wire: Int) -> Double { ui.kind == .slider ? Double(wire) / scale : Double(wire) }
    /// Display units -> normalized wire value.
    public func wire(fromDisplayValue d: Double) -> Int {
        normalize(ui.kind == .slider ? Int((d * scale).rounded()) : Int(d.rounded()))
    }
    /// Display units -> text, e.g. 0.6 -> "+0.6 EV", 250 -> "1/250".
    public func formatDisplay(_ d: Double) -> String { displayText(wire(fromDisplayValue: d)) }

    public func isEnabled(values: [String: Int]) -> Bool {
        guard let w = enabledWhen else { return true }
        return values[w.control] == w.equals
    }
}

public struct ForbiddenSelector: Codable, Sendable, Equatable {
    /// Key into the profile's `units` table (or a raw GUID).
    public var unit: String
    public var selector: Int
    public var reason: String?
}

public struct DeviceProfile: Codable, Sendable, Equatable {
    public struct Match: Codable, Sendable, Equatable {
        public var vendorID: HexInt
        public var productIDs: [HexInt]?
    }
    public var name: String
    public var match: Match?
    /// Alias -> extension unit GUID. Unit IDs are always resolved from the parsed descriptor.
    public var units: [String: String]
    public var controls: [ProfileControl]
    public var forbiddenSelectors: [ForbiddenSelector]
    /// Vendor-tuned "natural" defaults, preferred over GET_DEF by Restore Defaults.
    public var naturalDefaults: NaturalDefaults?

    /// `standard`: UVCControl id -> wire value. `profile`: ProfileControl id -> display value.
    public struct NaturalDefaults: Codable, Sendable, Equatable {
        public var standard: [String: Int]?
        public var profile: [String: Double]?
        public init(standard: [String: Int]? = nil, profile: [String: Double]? = nil) { self.standard = standard; self.profile = profile }
    }

    /// Unknown cameras: no vendor controls, nothing forbidden.
    public static let generic = DeviceProfile(name: "Generic UVC", match: nil, units: [:], controls: [], forbiddenSelectors: [], naturalDefaults: nil)

    public func matches(vendorID: UInt16, productID: UInt16) -> Bool {
        guard let m = match, m.vendorID.value == Int(vendorID) else { return false }
        guard let ids = m.productIDs else { return true }
        return ids.contains { $0.value == Int(productID) }
    }

    public func guid(for unitRef: String) -> String { (units[unitRef] ?? unitRef).lowercased() }

    public func control(_ id: String) -> ProfileControl? { controls.first { $0.id == id } }

    public func isForbidden(unitGUID: String, selector: Int) -> Bool {
        forbiddenSelectors.contains { guid(for: $0.unit) == unitGUID.lowercased() && $0.selector == selector }
    }

    public struct ValidationError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Structural checks beyond what Codable enforces.
    public func validate() throws {
        var seen = Set<String>()
        for c in controls {
            func fail(_ m: String) -> ValidationError { ValidationError(description: "\(name)/\(c.id): \(m)") }
            guard seen.insert(c.id).inserted else { throw fail("duplicate id") }
            guard units[c.unit] != nil || UUID(uuidString: c.unit) != nil else { throw fail("unknown unit \(c.unit)") }
            guard (0 ... 255).contains(c.selector) else { throw fail("selector out of range") }
            if case .bitInU16le = c.encoding, !c.needsReadModifyWrite { throw fail("bit encoding requires rmw") }
            switch c.ui.kind {
            case .slider:
                guard let lo = c.ui.min, let hi = c.ui.max, hi > lo else { throw fail("slider needs min < max") }
            case .picker:
                guard let o = c.ui.options, !o.isEmpty else { throw fail("picker needs options") }
            case .toggle: break
            }
        }
        for c in controls {
            if let w = c.enabledWhen, control(w.control) == nil {
                throw ValidationError(description: "\(name)/\(c.id): enabledWhen references unknown control \(w.control)")
            }
        }
        if let nd = naturalDefaults {
            let std = Set(UVCControl.all.map(\.id))
            for k in (nd.standard ?? [:]).keys where !std.contains(k) {
                throw ValidationError(description: "\(name): naturalDefaults.standard has unknown control \(k)")
            }
            for k in (nd.profile ?? [:]).keys where control(k) == nil {
                throw ValidationError(description: "\(name): naturalDefaults.profile has unknown control \(k)")
            }
        }
        for f in forbiddenSelectors where units[f.unit] == nil && UUID(uuidString: f.unit) == nil {
            throw ValidationError(description: "\(name): forbidden selector references unknown unit \(f.unit)")
        }
    }

    public static func decode(_ data: Data) throws -> DeviceProfile {
        let p = try JSONDecoder().decode(DeviceProfile.self, from: data)
        try p.validate()
        return p
    }
}

public enum VendorProfiles {
    /// Every JSON file in Resources/Profiles. Files that fail to decode are logged and skipped.
    public static let all: [DeviceProfile] = {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Profiles") ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            do { return try DeviceProfile.decode(Data(contentsOf: url)) }
            catch { NSLog("profile \(url.lastPathComponent) rejected: \(error)"); return nil }
        }
    }()

    public static func profile(vendorID: UInt16, productID: UInt16) -> DeviceProfile {
        all.first { $0.matches(vendorID: vendorID, productID: productID) } ?? .generic
    }
}
