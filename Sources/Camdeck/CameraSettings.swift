import AVFoundation
import UVCKit

// Uses only CameraController's non-private API. The pure model and diffing live in UVCKit/CameraSettings.swift.
extension CameraController {
    func captureSettings() -> CameraSettings {
        var standard: [String: [Int]] = [:]
        for st in states where st.canSet { if let v = values[st.id] { standard[st.id] = v } }
        let fmt = formats.first { $0.id == selectedFormatID }.map { CameraSettings.Format(width: $0.width, height: $0.height, fps: $0.fps) }
        return CameraSettings(standard: standard, profile: profileValues, format: fmt)
    }

    /// Writes only values that differ from the current state, through the throttled setters. Format last.
    /// Returns the number of writes issued.
    @discardableResult
    func apply(_ s: CameraSettings) -> Int {
        let writer = CameraSettings.Writer(
            setControl: { [self] id, v in set(id, v) },
            setProfile: { [self] id, v in setProfileValue(id, v) },
            setFormat: { [self] f in if let o = formats.first(where: { $0.id == f.id }) { selectFormat(o.id) } })
        return CameraSettings.apply(s, current: captureSettings(), writer: writer)
    }
}

// MARK: Describe a look

extension CameraController {
    /// Applies a plain-language request ("warmer", "black and white"). On-device model first, keyword fallback second.
    /// Returns the toast text. The previous image settings are kept for `undoLook()`.
    @discardableResult
    func applyLook(_ request: String) async -> String {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let id = selectedID
        // While an auto is on, the cached manual value is stale: start moves from what the camera is doing now.
        var current = values
        var live: [String] = []
        if (value("wb-auto").first ?? 0) != 0 { live.append("wb-temp") }
        if autoExposureOn() { live += ["exposure", "gain"] }
        if !live.isEmpty { current.merge(await readStandard(live)) { _, fresh in fresh } }
        // The model's plan, if it yields any write on this camera; otherwise the keyword parser's.
        var adj = LookAdjustment(), writes: [String: [Int]] = [:]
        if LookAssistant.unavailableReason == nil, let a = try? await LookAssistant.plan(text, states: states, current: current) {
            adj = a; writes = a.resolve(states: states, current: current)
        }
        guard selectedID == id else { return "" }
        if writes.isEmpty, let a = LookAdjustment.parse(text) {
            adj = a; writes = a.resolve(states: states, current: current)
        }
        guard !writes.isEmpty else {
            let msg = adj.isEmpty ? "Couldn't tell what to change" : "This camera can't do that"
            showToast(msg); return msg
        }
        // Undo covers only what this request touched.
        lookUndo = CameraSettings(controls: values.filter { writes[$0.key] != nil })
        for (k, v) in writes { set(k, v) }   // flush() orders autos before manual values
        // Describe only what produced a write on this camera.
        let done = LookAdjustment(moves: adj.moves.filter { writes[$0.key] != nil }, levels: adj.levels.filter { writes[$0.key] != nil },
                                  autos: adj.autos.filter { writes[$0.key] != nil })
        let summary = done.isEmpty ? adj.summary() : done.summary()
        let msg = summary.prefix(1).uppercased() + summary.dropFirst()
        showToast(msg)
        return msg
    }

    /// Puts the image back as it was before the last `applyLook`.
    func undoLook() {
        guard let s = lookUndo else { return }
        lookUndo = nil
        apply(s)
        showToast("Undone")
    }
}
