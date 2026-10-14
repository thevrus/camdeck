import Foundation

/// One thing the assistant can do to the camera. The language model's tools and the keyword fallback both
/// produce these; the app executes them. Pure value type so the parser is testable.
public enum CameraCommand: Equatable, Sendable {
    public enum Zoom: Equatable, Sendable {
        /// 1.0 is the widest view.
        case factor(Double)
        /// +1 zooms in one step, -1 out one step.
        case step(Int)
        case widest, closest
    }
    public enum Reset: String, Equatable, Sendable { case view, image, all }

    case look(LookAdjustment)
    case zoom(Zoom)
    /// Shift the view by a fraction of the available travel (x + right, y + down), -1 ... 1.
    case move(dx: Double, dy: Double)
    /// Either part may be nil: "1080p" keeps the frame rate, "60 fps" keeps the size.
    case format(resolution: String?, fps: Int?)
    /// "off", "close", "medium" or "wide".
    case autoFraming(String)
    case preset(String)
    case savePreset(String?)
    case reset(Reset)
    case mirror(Bool)
    case keepSettings(Bool)

    public static let framingModes = ["off", "close", "medium", "wide"]

    /// Keyword fallback for the common requests. Several commands can come from one sentence
    /// ("warmer and zoom in"). `presets` and `resolutions` are the names available right now.
    public static func parse(_ text: String, presets: [String] = [], resolutions: [String] = []) -> [CameraCommand] {
        let lower = text.lowercased().replacingOccurrences(of: "'", with: "")   // "don't" -> "dont"
        let words = lower.split { !$0.isLetter && !$0.isNumber && $0 != "." }.map(String.init)
        let t = " " + words.joined(separator: " ") + " "
        var out: [CameraCommand] = []
        func has(_ phrases: String...) -> Bool { phrases.contains { t.contains(" \($0) ") } }

        // Presets by name first: a preset called "Warm" must not be read as "warmer".
        for name in presets where t.contains(" \(name.lowercased()) ") && (has("preset", "apply", "use", "switch", "load") || words.count <= name.split(separator: " ").count + 1) {
            out.append(.preset(name)); break
        }
        if has("save") && has("preset") {
            let after = lower.range(of: "preset").map { text[$0.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let name = after.replacingOccurrences(of: #"^(?i)(as|called|named)\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ."))
            out.append(.savePreset(name.isEmpty ? nil : name))
        }

        // Reset
        if has("reset", "restore", "default", "defaults") {
            if has("everything", "all") { out.append(.reset(.all)) }
            else if has("image", "picture", "color", "colors", "colour", "exposure") { out.append(.reset(.image)) }
            else if has("view", "zoom", "framing", "position") { out.append(.reset(.view)) }
            else { out.append(.reset(.image)) }
        }

        // Zoom
        if let m = lower.firstMatch(of: #/(\d+(?:\.\d+)?)\s*x\b/#), let f = Double(m.1) {
            out.append(.zoom(.factor(f)))
        } else if has("zoom") || has("closer", "wider", "tighter") {
            if has("all the way", "fully", "max", "maximum", "closest") && !has("out") { out.append(.zoom(.closest)) }
            else if has("all the way", "fully", "widest", "full view", "entire") { out.append(.zoom(.widest)) }
            else if has("in", "closer", "tighter") { out.append(.zoom(.step(has("more", "lot", "much") ? 3 : 1))) }
            else if has("out", "wider", "back") { out.append(.zoom(.step(has("more", "lot", "much") ? -3 : -1))) }
        }
        // View shift
        var dx = 0.0, dy = 0.0
        if has("left") { dx -= 0.25 }; if has("right") { dx += 0.25 }
        if has("up", "higher") && !has("set up") { dy -= 0.25 }; if has("down", "lower") && !has("lower contrast", "lower brightness", "lower saturation") { dy += 0.25 }
        if (dx != 0 || dy != 0), has("move", "pan", "tilt", "shift", "nudge", "view", "frame", "camera", "point", "aim") { out.append(.move(dx: dx, dy: dy)) }

        // Format
        var res: String? = nil
        for r in resolutions where t.contains(" \(r.lowercased()) ") { res = r; break }
        if res == nil, has("4k", "uhd", "2160p") { res = "4K" }
        if res == nil, has("1440p", "qhd") { res = "1440p" }
        if res == nil, has("1080p", "1080", "full hd", "fhd") { res = "1080p" }
        if res == nil, has("720p", "720", "hd") { res = "720p" }
        let fps = lower.firstMatch(of: #/(\d+)\s*(?:fps|frames|hz)\b/#).flatMap { Int($0.1) }
        if res != nil || fps != nil { out.append(.format(resolution: res, fps: fps)) }

        // Auto framing
        if has("stop following", "stop tracking", "framing off", "auto framing off", "stop auto framing", "dont follow", "do not follow") {
            out.append(.autoFraming("off"))
        } else if has("follow", "track", "keep me", "center me", "centre me", "auto frame", "auto framing", "autoframe", "autoframing") {
            out.append(.autoFraming(has("close", "tight") ? "close" : has("wide") ? "wide" : "medium"))
        }

        // Mirror, lock
        if has("mirror", "flip") { out.append(.mirror(!has("off", "stop", "unmirror", "dont", "do not", "no"))) }
        if has("keep", "lock", "protect") && has("settings", "setting") { out.append(.keepSettings(!has("off", "stop", "unlock", "dont", "do not"))) }
        if has("unlock") && has("settings") { out.append(.keepSettings(false)) }

        let presetMatched = out.contains { if case .preset = $0 { return true } else { return false } }
        if !presetMatched, let look = LookAdjustment.parse(text) {
            // "lighter" after "zoom" words etc. is still an image request; a bare "reset" is not.
            if !out.contains(where: { if case .reset = $0 { return true } else { return false } }) || !words.allSatisfy({ ["reset", "restore", "the", "image", "picture", "colors", "view", "everything", "all", "to", "default", "defaults", "normal", "natural"].contains($0) }) {
                out.append(.look(look))
            }
        }
        return out
    }
}
