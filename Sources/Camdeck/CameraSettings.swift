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
