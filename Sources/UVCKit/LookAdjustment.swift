import Foundation

/// A plain-language image change ("warmer", "black and white") resolved against the camera's real ranges.
/// Values are normalized so the same plan works on any camera: a *move* is a fraction of the control's range
/// (-1 ... 1, relative to the current value), a *level* is an absolute position in the range (0 ... 1).
/// Pure value type; the language model and the keyword fallback both produce it.
public struct LookAdjustment: Equatable, Sendable {
    public var moves: [String: Double] = [:]
    public var levels: [String: Double] = [:]
    /// Auto toggles to switch: "wb-auto", "ae-mode".
    public var autos: [String: Bool] = [:]

    public init(moves: [String: Double] = [:], levels: [String: Double] = [:], autos: [String: Bool] = [:]) {
        self.moves = moves; self.levels = levels; self.autos = autos
    }

    public var isEmpty: Bool { moves.isEmpty && levels.isEmpty && autos.isEmpty }

    /// Controls the assistant may touch, with the words the model sees. Everything else is ignored.
    public static let imageControls = ["brightness", "contrast", "saturation", "sharpness", "gamma", "hue", "wb-temp", "backlight", "gain", "exposure"]
    public static let autoControls = ["wb-auto", "ae-mode"]

    /// One-line description of a control for the model: direction and meaning in plain words.
    public static func describe(_ id: String) -> String? {
        switch id {
        case "brightness": "overall lightness"
        case "contrast": "difference between light and dark"
        case "saturation": "color intensity; 0 is black and white"
        case "sharpness": "edge enhancement"
        case "gamma": "mid-tone brightness"
        case "hue": "color shift around the wheel"
        case "wb-temp": "color temperature in kelvin; LOWER is warmer/orange, HIGHER is cooler/blue"
        case "backlight": "compensation for a bright background"
        case "gain": "sensor amplification; brightens but adds noise"
        case "exposure": "shutter time; longer is brighter"
        default: nil
        }
    }

    /// Raw target values per control id. Only controls present in `states` and settable are produced.
    /// Setting a manual value turns the gating auto off (wb-temp -> wb-auto, exposure/gain -> ae-mode)
    /// unless the plan asks for that auto explicitly.
    public func resolve(states: [UVCControlState], current: [String: [Int]]) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        let byID = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        func range(_ id: String) -> (lo: Int, hi: Int, cur: Int)? {
            guard let st = byID[id], st.canSet, let lo = st.min?.first, let hi = st.max?.first, hi > lo else { return nil }
            return (lo, hi, current[id]?.first ?? st.cur?.first ?? st.def?.first ?? lo)
        }
        func clamp(_ v: Double, _ lo: Int, _ hi: Int) -> [Int] { [Int(v.rounded()).clamped(to: lo...hi)] }
        for (id, m) in moves where Self.imageControls.contains(id) {
            guard let r = range(id) else { continue }
            out[id] = clamp(Double(r.cur) + m.clamped(to: -1...1) * Double(r.hi - r.lo), r.lo, r.hi)
        }
        for (id, l) in levels where Self.imageControls.contains(id) {
            guard let r = range(id) else { continue }
            out[id] = clamp(Double(r.lo) + l.clamped(to: 0...1) * Double(r.hi - r.lo), r.lo, r.hi)
        }
        for (id, on) in autos where Self.autoControls.contains(id) {
            guard let st = byID[id], st.canSet else { continue }
            // A manual value in the same plan decides the auto: "auto off" alone leaves the picture wherever the
            // camera last had it, and "auto on" next to a manual value would make the camera ignore that value.
            let manual = id == "wb-auto" ? out["wb-temp"] != nil : out["exposure"] != nil || out["gain"] != nil
            if on == manual { continue }
            if id == "ae-mode" {
                let supported = st.res?.first ?? 0x09
                out[id] = [on ? (supported & 8 != 0 ? 8 : 2) : 1]
            } else { out[id] = [on ? 1 : 0] }
        }
        // Manual values need their auto off, or the camera ignores them.
        if out["wb-temp"] != nil, let st = byID["wb-auto"], st.canSet { out["wb-auto"] = [0] }
        if out["exposure"] != nil || out["gain"] != nil, let st = byID["ae-mode"], st.canSet { out["ae-mode"] = [1] }
        return out
    }

    // MARK: Keyword fallback

    /// Understands the common requests without a language model. Nil when nothing matched.
    /// Each keyword names a control and a direction; "too", "less", "not", "reduce", "lower" or "de-" just before it
    /// flips the direction ("too bright" darkens). The first keyword for a control wins.
    public static func parse(_ text: String) -> LookAdjustment? {
        let words = text.lowercased().split { !$0.isLetter && $0 != "&" && $0 != "/" }.map(String.init)
        let t = " " + words.joined(separator: " ") + " "
        var a = LookAdjustment()
        let strength: Double = ["much", "very", "lot", "way", "really"].contains(where: words.contains) ? 0.3
            : ["slightly", "bit", "little", "touch", "tad"].contains(where: words.contains) ? 0.08 : 0.15
        for phrase in ["black and white", "black & white", "b&w", "b/w", "monochrome", "grayscale", "greyscale", "no color", "no colour"]
        where t.contains(" \(phrase) ") { a.levels["saturation"] = 0 }
        // (keyword prefix, control, direction when stated plainly)
        let table: [(String, String, Double)] = [
            ("warm", "wb-temp", -1), ("cool", "wb-temp", 1), ("cold", "wb-temp", 1), ("blue", "wb-temp", 1), ("orange", "wb-temp", -1),
            ("bright", "brightness", 1), ("light", "brightness", 1), ("dark", "brightness", -1), ("dim", "brightness", -1),
            ("contrast", "contrast", 1), ("punch", "contrast", 1), ("pop", "contrast", 1), ("flat", "contrast", -1),
            ("desaturat", "saturation", -1), ("saturat", "saturation", 1), ("vivid", "saturation", 1), ("vibrant", "saturation", 1), ("colorful", "saturation", 1),
            ("colourful", "saturation", 1), ("muted", "saturation", -1), ("pastel", "saturation", -1), ("washed", "saturation", -1),
            ("sharp", "sharpness", 1), ("crisp", "sharpness", 1), ("detail", "sharpness", 1), ("soft", "sharpness", -1), ("smooth", "sharpness", -1),
        ]
        let negations: Set<String> = ["too", "less", "not", "reduce", "lower", "overly"]
        for (i, w) in words.enumerated() {
            guard let (_, control, dir) = table.first(where: { w.hasPrefix($0.0) }) else { continue }
            if control == "saturation", a.levels["saturation"] != nil { continue }
            guard a.moves[control] == nil else { continue }
            let before = words[max(0, i - 2) ..< i]
            let negated = before.contains(where: negations.contains)
            a.moves[control] = (negated ? -dir : dir) * strength
        }
        if t.contains(" auto white ") || t.contains(" auto wb ") { a.autos["wb-auto"] = true }
        if t.contains(" auto exposure ") { a.autos["ae-mode"] = true }
        if a.isEmpty, ["natural", "neutral", "normal", "default"].contains(where: words.contains) { a.autos["wb-auto"] = true; a.autos["ae-mode"] = true }
        return a.isEmpty ? nil : a
    }

    /// "Warmer, less saturation" style summary of what will change, for the confirmation toast.
    public func summary() -> String {
        var parts: [String] = []
        for (id, m) in moves.sorted(by: { $0.key < $1.key }) {
            let name = id == "wb-temp" ? (m < 0 ? "warmer" : "cooler") : (m < 0 ? "less " : "more ") + id
            parts.append(name)
        }
        for (id, l) in levels.sorted(by: { $0.key < $1.key }) {
            parts.append(id == "saturation" && l == 0 ? "black and white" : "\(id) \(Int((l * 100).rounded()))%")
        }
        for (id, on) in autos.sorted(by: { $0.key < $1.key }) {
            parts.append((id == "wb-auto" ? "auto white balance " : "auto exposure ") + (on ? "on" : "off"))
        }
        return parts.joined(separator: ", ")
    }
}

extension Comparable {
    public func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
