import Foundation

/// A restorable snapshot of everything the user can tune on one camera.
/// Pure value type: the diffing/apply logic is injectable so it is testable without USB.
public struct CameraSettings: Codable, Equatable, Sendable {
    public struct Format: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var fps: Int
        public init(width: Int, height: Int, fps: Int) { self.width = width; self.height = height; self.fps = fps }
        /// Same scheme as the app's FormatOption.id.
        public var id: String { "\(width)x\(height)@\(fps)" }
    }

    /// Standard UVC values by control id, only controls the device supports.
    /// "zoom" and "pantilt" are NOT stored here; see `zoom` / `pan` / `tilt`.
    public var controls: [String: [Int]]
    /// Profile control values by id, in display units (same as CameraController.profileValues).
    public var profile: [String: Double]
    public var zoom: Int?
    public var pan: Int?
    public var tilt: Int?
    public var format: Format?
    /// Auto-framing mode raw value; nil until that feature lands.
    public var autoFraming: String?

    public init(controls: [String: [Int]] = [:], profile: [String: Double] = [:], zoom: Int? = nil, pan: Int? = nil,
                tilt: Int? = nil, format: Format? = nil, autoFraming: String? = nil) {
        self.controls = controls; self.profile = profile; self.zoom = zoom; self.pan = pan; self.tilt = tilt
        self.format = format; self.autoFraming = autoFraming
    }

    /// Build from a raw controller value map (which includes "zoom" and "pantilt").
    public init(standard: [String: [Int]], profile: [String: Double], format: Format?, autoFraming: String? = nil) {
        var c = standard
        let z = c.removeValue(forKey: "zoom")
        let pt = c.removeValue(forKey: "pantilt")
        self.init(controls: c, profile: profile, zoom: z?.first, pan: pt?[safe: 0], tilt: pt?[safe: 1],
                  format: format, autoFraming: autoFraming)
    }

    /// Value of any standard control id, folding zoom/pan/tilt back in.
    public func value(of id: String) -> [Int]? {
        switch id {
        case "zoom": return zoom.map { [$0] }
        case "pantilt": if let pan, let tilt { return [pan, tilt] } else { return nil }
        default: return controls[id]
        }
    }

    /// Copy without zoom/pan/tilt (used while auto framing owns the view).
    public func withoutView() -> CameraSettings {
        var s = self; s.zoom = nil; s.pan = nil; s.tilt = nil; return s
    }

    // MARK: Apply

    public struct Writer {
        public var setControl: (String, [Int]) -> Void
        public var setProfile: (String, Double) -> Void
        public var setFormat: (Format) -> Void
        public init(setControl: @escaping (String, [Int]) -> Void, setProfile: @escaping (String, Double) -> Void,
                    setFormat: @escaping (Format) -> Void) {
            self.setControl = setControl; self.setProfile = setProfile; self.setFormat = setFormat
        }
    }

    /// Auto toggles go before the values they gate.
    private static let first = ["ae-mode", "wb-auto", "focus-auto"]

    /// Writes only what differs from `current` and exists in `current` (i.e. is supported). Format last.
    /// Returns the number of writes issued.
    @discardableResult
    public static func apply(_ target: CameraSettings, current: CameraSettings, writer: Writer) -> Int {
        var n = 0
        var ids = Set(target.controls.keys).intersection(current.controls.keys)
        for v in ["zoom", "pantilt"] { ids.insert(v) }
        let ordered = ids.sorted { a, b in
            let ia = first.firstIndex(of: a) ?? first.count, ib = first.firstIndex(of: b) ?? first.count
            return ia != ib ? ia < ib : a < b
        }
        for id in ordered {
            guard let cur = current.value(of: id) else { continue }
            var want: [Int]
            if id == "pantilt" {
                // Partial targets keep the other axis.
                guard target.pan != nil || target.tilt != nil, cur.count == 2 else { continue }
                want = [target.pan ?? cur[0], target.tilt ?? cur[1]]
            } else {
                guard let w = target.value(of: id) else { continue }
                want = w
            }
            if want != cur { writer.setControl(id, want); n += 1 }
        }
        for id in target.profile.keys.sorted(by: { ($0 == "aeMode" ? 0 : 1, $0) < ($1 == "aeMode" ? 0 : 1, $1) }) {
            guard let cur = current.profile[id], let want = target.profile[id] else { continue }
            if abs(cur - want) > 1e-6 { writer.setProfile(id, want); n += 1 }
        }
        if let f = target.format, f != current.format { writer.setFormat(f); n += 1 }
        return n
    }
}

extension Array {
    public subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
