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
    /// Applies a resolved look plan. While an auto is on, the cached manual value is stale, so those controls are
    /// read from the camera first. Returns a short description of what changed, or why nothing did.
    @discardableResult
    func applyLook(_ adj: LookAdjustment) async -> String {
        let id = selectedID
        var current = values
        var live: [String] = []
        if (value("wb-auto").first ?? 0) != 0 { live.append("wb-temp") }
        if autoExposureOn() { live += ["exposure", "gain"] }
        if !live.isEmpty { current.merge(await readStandard(live)) { _, fresh in fresh } }
        guard selectedID == id else { return "" }
        let writes = adj.resolve(states: states, current: current)
        guard !writes.isEmpty else { return adj.isEmpty ? "Nothing to change" : "This camera can't do that" }
        for (k, v) in writes { set(k, v) }   // flush() orders autos before manual values
        func wrote<V>(_ d: [String: V]) -> [String: V] { d.filter { writes[$0.key] != nil } }
        let summary = LookAdjustment(moves: wrote(adj.moves), levels: wrote(adj.levels), autos: wrote(adj.autos)).summary()
        return summary.prefix(1).uppercased() + summary.dropFirst()
    }

    /// Puts everything back as it was before the last request.
    func undoLook() {
        guard let s = lookUndo else { return }
        lookUndo = nil
        if let x = undoExtras {
            undoExtras = nil
            autoFraming = x.framing   // first: a running framer would fight the view restore
            mirrored = x.mirrored
            apply(s)
            if let c = x.center, reframe != nil { setReframe(center: c) }
        } else {
            apply(s)
        }
        showToast("Undone")
    }
}
