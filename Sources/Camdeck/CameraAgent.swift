import Foundation
import FoundationModels
import UVCKit

/// Runs plain-language requests against the camera: Apple's on-device model picks tools (one per CameraCommand),
/// the keyword parser is the fallback. Everything happens on this Mac.
/// Docs: developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling
@MainActor
enum CameraAgent {
    /// Nil when the on-device model can be used; otherwise a short reason for the UI.
    static var unavailableReason: String? { LookAssistant.unavailableReason }
    /// Toast and return value of `run` when neither the model nor the parser found anything to do.
    static let nothingDone = "Couldn't tell what to do"

    // MARK: Execute

    /// Carries out one command. Returns a short past-tense description, or a reason it could not.
    static func perform(_ c: CameraCommand, on cam: CameraController) async -> String {
        switch c {
        case .look(let adj):
            return await cam.applyLook(adj)
        case .zoom(let z):
            guard let st = cam.state("zoom"), st.canSet else { return "This camera cannot zoom." }
            let range = cam.zoomFactorRange
            let target: Double
            switch z {
            case .factor(let f): target = f
            case .widest: target = range.lowerBound
            case .closest: target = range.upperBound
            case .step(let n):
                let step = (range.upperBound - range.lowerBound) / 8
                target = cam.zoomFactor + Double(n) * step
            }
            let f = min(max(target, range.lowerBound), range.upperBound)
            cam.setZoomFactor(f)
            return "Zoom \(String(format: "%.1f", f))×"
        case .move(let dx, let dy):
            guard let r = cam.reframe else { return "This camera cannot move its view." }
            guard r.canMove else { return "Zoom in first; the view cannot move at 1×." }
            cam.setReframe(center: CGPoint(x: r.center.x + dx, y: r.center.y + dy))
            return "View moved"
        case .format(let res, let fps):
            let cur = cam.formats.first { $0.id == cam.selectedFormatID }
            let wantRes = res.map { resolutionKey($0) }
            // No resolution named: stay at the current size.
            var candidates = cam.formats.filter { f in
                if let wantRes { return resolutionKey(for: f) == wantRes }
                if let cur { return f.width == cur.width && f.height == cur.height }
                return true
            }
            if candidates.isEmpty { return "No \(res ?? "") mode on this camera." }
            if let fps {
                let withFPS = candidates.filter { abs($0.fps - fps) <= 1 }
                if withFPS.isEmpty { return "No \(fps) fps mode\(res.map { " at \($0)" } ?? "")." }
                candidates = withFPS
            } else if let cur, candidates.contains(where: { $0.fps == cur.fps }) {
                candidates = candidates.filter { $0.fps == cur.fps }
            } else if candidates.contains(where: { $0.fps == 30 }) {
                candidates = candidates.filter { $0.fps == 30 }
            }
            // Highest resolution, then highest fps among what is left.
            guard let pick = candidates.max(by: { ($0.height, $0.fps) < ($1.height, $1.fps) }) else { return "No such mode." }
            cam.selectFormat(pick.id)
            return pick.label
        case .autoFraming(let mode):
            guard let m = AutoFramingMode(rawValue: mode.lowercased()) else { return "Unknown framing mode." }
            if m != .off, !cam.canAutoFrame { return "This camera cannot auto frame." }
            cam.autoFraming = m
            return m == .off ? "Auto framing off" : "Following you (\(m.title.lowercased()))"
        case .preset(let name):
            guard let store = cam.presets else { return "No camera." }
            guard let p = store.items.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                    ?? store.items.first(where: { $0.name.lowercased().contains(name.lowercased()) }) else {
                return "No preset named \(name)."
            }
            store.apply(p.id)
            return "Applied \(p.name)"
        case .savePreset(let name):
            guard let store = cam.presets else { return "No camera." }
            let p = store.save(name: name ?? store.defaultName)
            return "Saved as \(p.name)"
        case .reset(let what):
            switch what {
            case .view: cam.resetView(); return "View reset"
            case .image: cam.resetImage(); return "Image reset"
            case .all: cam.restoreDefaults(); return "Settings reset"
            }
        case .mirror(let on):
            cam.mirrored = on
            return on ? "Mirror on" : "Mirror off"
        case .keepSettings(let on):
            guard let lock = cam.settingsLock else { return "No camera." }
            lock.isEnabled = on
            return on ? "Keeping your settings" : "Settings unlocked"
        }
    }

    /// "4K", "1440p", "1080p", "720p" or "WxH": the names the parser and the model use.
    static func resolutionKey(for f: FormatOption) -> String {
        switch f.height {
        case 2160...: "4K"
        case 1440: "1440p"
        case 1080: "1080p"
        case 720: "720p"
        default: "\(f.width)x\(f.height)"
        }
    }
    private static func resolutionKey(_ s: String) -> String {
        let l = s.lowercased().replacingOccurrences(of: " ", with: "")
        if l.hasPrefix("4k") || l == "2160p" || l == "2160" || l == "uhd" { return "4K" }
        if l == "1440" || l == "1440p" || l == "qhd" { return "1440p" }
        if l == "1080" || l == "1080p" || l == "fullhd" || l == "fhd" { return "1080p" }
        if l == "720" || l == "720p" || l == "hd" { return "720p" }
        // "1920x1080" and the like: key by height, same as resolutionKey(for:).
        if let m = l.firstMatch(of: #/^(\d+)x(\d+)$/#), let w = Int(m.1), let h = Int(m.2) {
            switch h { case 2160...: return "4K"; case 1440: return "1440p"; case 1080: return "1080p"; case 720: return "720p"; default: return "\(w)x\(h)" }
        }
        return l.hasSuffix("p") ? l : l + "p"
    }

    static func resolutions(of cam: CameraController) -> [String] {
        var seen: [String] = []
        for f in cam.formats { let k = resolutionKey(for: f); if !seen.contains(k) { seen.append(k) } }
        return seen
    }

    // MARK: Run

    /// Executes `text`. Model with tools first; keyword fallback when the model is unavailable, fails or did
    /// nothing. Shows a toast and returns its text. The state before the request is kept for `undoLook()`.
    @discardableResult
    static func run(_ text: String, on cam: CameraController) async -> String {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return "" }
        let id = cam.selectedID
        let before = UndoExtras(framing: cam.autoFraming, mirrored: cam.mirrored, center: cam.reframe?.center)
        let beforeSettings = cam.captureSettings()
        var done: [String] = []
        var covered: Set<String> = []
        if unavailableReason == nil {
            let log = ToolLog()
            let session = LanguageModelSession(tools: tools(for: cam, log: log), instructions: instructions(for: cam))
            do {
                _ = try await session.respond(to: request, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 200))
            } catch {
                NSLog("CameraAgent: model failed: \(error)")
            }
            done = await log.entries
            covered = await log.kinds
        }
        guard cam.selectedID == id else { return "" }
        // The model tends to make one tool call per request. The keyword parser fills in the parts of a
        // compound request ("warmer and zoom in") it did not cover, and takes over entirely when it failed.
        // A preset is a look of its own, and a reset or preset after the model's look would wipe it.
        if covered.contains("preset") { covered.insert("look") }
        if covered.contains("look") { covered.formUnion(["reset", "preset"]) }
        let cmds = CameraCommand.parse(request, presets: cam.presets?.items.map(\.name) ?? [], resolutions: resolutions(of: cam))
            .sorted { fillOrder(kind(of: $0)) < fillOrder(kind(of: $1)) }   // reset and preset before adjustments
        for c in cmds where !covered.contains(kind(of: c)) { done.append(await perform(c, on: cam)) }
        done.removeAll(where: \.isEmpty)
        let msg: String
        if done.isEmpty {
            msg = nothingDone
        } else {
            cam.lookUndo = beforeSettings
            cam.undoExtras = before
            msg = done.joined(separator: " · ")
        }
        cam.showToast(msg)
        return msg
    }

    private static func fillOrder(_ kind: String) -> Int { ["reset": 0, "preset": 1].first { $0.key == kind }?.value ?? 2 }

    private static func instructions(for cam: CameraController) -> String {
        var lines = ["You operate a webcam app. Carry out the request with the tools, then answer in at most six words."]
        let res = resolutions(of: cam)
        if !res.isEmpty {
            let fps = Set(cam.formats.map(\.fps)).sorted()
            lines.append("Resolutions: \(res.joined(separator: ", ")). Frame rates: \(fps.map(String.init).joined(separator: ", ")).")
        }
        if let names = cam.presets?.items.map(\.name), !names.isEmpty { lines.append("Presets: \(names.joined(separator: ", ")).") }
        lines.append("Image controls: " + cam.states.filter { $0.canSet && LookAdjustment.imageControls.contains($0.id) }.map(\.id).joined(separator: ", ") + ".")
        lines.append("Use only ids that exist. Do nothing if the request is not about the camera.")
        return lines.joined(separator: "\n")
    }

    private static func tools(for cam: CameraController, log: ToolLog) -> [any Tool] {
        var t: [any Tool] = [AdjustImageTool(cam: cam, log: log), BlackAndWhiteTool(cam: cam, log: log), NaturalTool(cam: cam, log: log), ResetTool(cam: cam, log: log), MirrorTool(cam: cam, log: log)]
        if cam.state("zoom") != nil { t.append(ZoomTool(cam: cam, log: log)) }
        if cam.reframe != nil { t.append(MoveViewTool(cam: cam, log: log)) }
        if cam.formats.count > 1 { t.append(FormatTool(cam: cam, log: log)) }
        if cam.canAutoFrame { t.append(AutoFramingTool(cam: cam, log: log)) }
        if cam.presets != nil { t.append(PresetTool(cam: cam, log: log)); t.append(SavePresetTool(cam: cam, log: log)) }
        if cam.settingsLock != nil { t.append(KeepSettingsTool(cam: cam, log: log)) }
        return t
    }

    /// What the tools did, in order, and which kinds of command they covered; the toast and the
    /// compound-request fill-in are built from it.
    actor ToolLog {
        var entries: [String] = []
        var kinds: Set<String> = []
        func add(_ s: String, kind: String) { entries.append(s); kinds.insert(kind) }
    }

    /// Coarse kind of a command, to tell whether the model already handled that part of a request.
    static func kind(of c: CameraCommand) -> String {
        switch c {
        case .look: "look"
        case .zoom: "zoom"
        case .move: "move"
        case .format: "format"
        case .autoFraming: "framing"
        case .preset, .savePreset: "preset"
        case .reset: "reset"
        case .mirror: "mirror"
        case .keepSettings: "lock"
        }
    }

    // MARK: Tools (thin: build a CameraCommand, run it on the main actor, report back to the model)

    private static func execute(_ c: CameraCommand, _ cam: CameraController, _ log: ToolLog) async -> String {
        let r = await perform(c, on: cam)
        await log.add(r, kind: kind(of: c))
        return r
    }

    struct AdjustImageTool: Tool {
        let cam: CameraController; let log: ToolLog
        let name = "adjustImage"
        let description = "Change brightness, contrast, saturation, sharpness, wb-temp (lower is warmer, higher cooler), exposure, gain."
        @Generable struct Arguments {
            @Guide(description: "Controls to change") var changes: [Change]
        }
        @Generable struct Change {
            @Guide(.anyOf(LookAdjustment.imageControls)) var control: String
            @Guide(description: "Change in percent of the control's range; small requests about 15, strong about 35", .range(-40 ... 40)) var percent: Int
        }
        func call(arguments a: Arguments) async throws -> String {
            var adj = LookAdjustment()
            for m in a.changes { adj.moves[m.control] = Double(m.percent) / 100 }
            return await execute(.look(adj), cam, log)
        }
    }

    struct BlackAndWhiteTool: Tool {
        let cam: CameraController; let log: ToolLog
        let name = "blackAndWhite"
        let description = "Make the picture black and white (monochrome), or bring color back."
        @Generable struct Arguments { var on: Bool }
        func call(arguments a: Arguments) async throws -> String {
            await execute(.look(a.on ? LookAdjustment(levels: ["saturation": 0]) : LookAdjustment(levels: ["saturation": 0.5])), cam, log)
        }
    }

    struct NaturalTool: Tool {
        let cam: CameraController; let log: ToolLog
        let name = "naturalColors"
        let description = "Natural, normal or automatic colors and exposure: hands white balance and exposure back to the camera."
        @Generable struct Arguments { var on: Bool }
        func call(arguments a: Arguments) async throws -> String {
            await execute(.look(LookAdjustment(autos: ["wb-auto": a.on, "ae-mode": a.on])), cam, log)
        }
    }

    struct ZoomTool: Tool {
        let cam: CameraController; let log: ToolLog
        let name = "zoom"
        let description = "Zoom in or out, go to the widest or closest view, or set an exact zoom."
        @Generable struct Arguments {
            @Guide(.anyOf(["in", "out", "widest", "closest", "exact"])) var direction: String
            @Guide(description: "Steps for in/out: 1 normal, 2 a lot") var steps: Int
            @Guide(description: "For exact only: percent, 100 = widest, 200 = twice as close") var percent: Int
        }
        func call(arguments a: Arguments) async throws -> String {
            let z: CameraCommand.Zoom
            switch a.direction {
            case "in": z = .step(max(1, min(a.steps, 3)))
            case "out": z = .step(-max(1, min(a.steps, 3)))
            case "widest": z = .widest
            case "closest": z = .closest
            default: z = .factor(Double(max(a.percent, 100)) / 100)
            }
            return await execute(.zoom(z), cam, log)
        }
    }

    struct MoveViewTool: Tool {
        let cam: CameraController; let log: ToolLog
        let name = "moveView"
        let description = "Shift the zoomed view. Percent of available travel; right and down are positive."
        @Generable struct Arguments {
            @Guide(.range(-100 ... 100)) var right: Int
            @Guide(.range(-100 ... 100)) var down: Int
        }
        func call(arguments a: Arguments) async throws -> String { await execute(.move(dx: Double(a.right) / 100, dy: Double(a.down) / 100), cam, log) }
    }

    struct FormatTool: Tool {
        let cam: CameraController; let log: ToolLog
        let name = "setVideoMode"
        let description = "Change resolution and/or frame rate. Empty string or 0 keeps the current one."
        @Generable struct Arguments {
            @Guide(description: "4K, 1080p, 720p or empty") var resolution: String
            @Guide(description: "Frames per second, or 0") var fps: Int
        }
        func call(arguments a: Arguments) async throws -> String {
            await execute(.format(resolution: a.resolution.isEmpty ? nil : a.resolution, fps: a.fps > 0 ? a.fps : nil), cam, log)
        }
    }

    struct AutoFramingTool: Tool {
        let cam: CameraController; let log: ToolLog
        let name = "setAutoFraming"
        let description = "Follow the person automatically (close, medium, wide) or turn it off."
        @Generable struct Arguments { @Guide(.anyOf(CameraCommand.framingModes)) var mode: String }
        func call(arguments a: Arguments) async throws -> String { await execute(.autoFraming(a.mode), cam, log) }
    }

    struct PresetTool: Tool {
        let cam: CameraController; let log: ToolLog
        let name = "applyPreset"
        let description = "Apply a saved preset by name."
        @Generable struct Arguments { var name: String }
        func call(arguments a: Arguments) async throws -> String { await execute(.preset(a.name), cam, log) }
    }

    struct SavePresetTool: Tool {
        let cam: CameraController; let log: ToolLog
        let name = "savePreset"
        let description = "Save the current settings as a preset. Empty name picks one."
        @Generable struct Arguments { var name: String }
        func call(arguments a: Arguments) async throws -> String { await execute(.savePreset(a.name.isEmpty ? nil : a.name), cam, log) }
    }

    struct ResetTool: Tool {
        let cam: CameraController; let log: ToolLog
        let name = "reset"
        let description = "Reset: view (zoom and position), image (color and exposure) or all."
        @Generable struct Arguments { @Guide(.anyOf(["view", "image", "all"])) var what: String }
        func call(arguments a: Arguments) async throws -> String { await execute(.reset(CameraCommand.Reset(rawValue: a.what) ?? .image), cam, log) }
    }

    struct MirrorTool: Tool {
        let cam: CameraController; let log: ToolLog
        let name = "setMirror"
        let description = "Mirror the preview on or off."
        @Generable struct Arguments { var on: Bool }
        func call(arguments a: Arguments) async throws -> String { await execute(.mirror(a.on), cam, log) }
    }

    struct KeepSettingsTool: Tool {
        let cam: CameraController; let log: ToolLog
        let name = "keepSettings"
        let description = "Lock settings so other apps cannot change them, on or off."
        @Generable struct Arguments { var on: Bool }
        func call(arguments a: Arguments) async throws -> String { await execute(.keepSettings(a.on), cam, log) }
    }
}
