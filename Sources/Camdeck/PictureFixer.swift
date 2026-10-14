import Foundation
import OSLog
import UVCKit

/// "Fix My Picture": one shot. Reads a few frames, writes exposure, white balance, focus and anti-flicker, and stops.
/// Nothing keeps analyzing afterwards. Writes go through `set`/`setProfileValue`, so the settings lock and
/// presets see them as user edits.
extension CameraController {
    private static let fixLog = Logger(subsystem: "app.camdeck", category: "fix")

    func fixPicture() async {
        guard !fixing, hasUVC, currentDevice != nil else { return }
        let started = ContinuousClock.now
        let wasRunning = session.isRunning
        fixing = true
        defer { fixing = false }
        showToast("Fixing picture…")

        // Auto white balance and autofocus settle together, then both are locked at what they found.
        let wb = state("wb-auto") != nil && state("wb-temp")?.canSet == true
        let af = state("focus-auto") != nil && state("focus")?.canSet == true
        if wb || af {
            if wb { set("wb-auto", [1]) }
            if af { set("focus-auto", [1]) }
            try? await Task.sleep(for: .seconds(1.5))
            let read = await readStandard((wb ? ["wb-temp"] : []) + (af ? ["focus"] : []))
            if wb { set("wb-auto", [0]) }
            if af { set("focus-auto", [0]) }
            // The auto toggles must land first: a manual value written while auto is on is ignored.
            try? await Task.sleep(for: .milliseconds(100))
            for id in ["wb-temp", "focus"] {
                guard let v = read[id] else { continue }
                values[id] = nil // force the write even if the cached value already matches
                set(id, v)
            }
        }

        // Camera warm-up: the first frames after starting the session are dark and still converging.
        if !wasRunning { try? await Task.sleep(for: .milliseconds(500)) }

        await fixFlicker()

        // Exposure: up to three rounds of measure, step, write, settle.
        var sawFace = false
        for _ in 0 ..< 3 {
            if ContinuousClock.now - started > .seconds(8.5) { break }
            let frames = await grabFrames(3)
            guard !frames.isEmpty else { break }
            let faces = frames.compactMap(\.faceLuma)
            if !faces.isEmpty { sawFace = true }
            let faceLuma = faces.isEmpty ? nil : faces.reduce(0, +) / Double(faces.count)
            let frameLuma = frames.map(\.frameLuma).reduce(0, +) / Double(frames.count)
            let step = PictureFix.exposureStep(faceLuma: faceLuma, frameLuma: frameLuma, controls: exposureControls())
            Self.fixLog.debug("exposure face=\(faceLuma ?? -1) frame=\(frameLuma) step=\(String(describing: step), privacy: .public)")
            if step.isEmpty { break }
            if let ev = step.ev { setProfileValue("ev", ev) }
            if let b = step.backlight { set("backlight", [b]) }
            if let b = step.brightness { set("brightness", [b]) }
            try? await Task.sleep(for: .seconds(0.8))
        }
        showToast(sawFace ? "Picture fixed" : "No face found, used the whole frame")
    }

    /// Anti-flicker: only when the camera offers both 50 and 60 Hz. Scores rolling bands under each; keeps the
    /// clearly better one, else puts the original setting back.
    private func fixFlicker() async {
        guard let st = state("powerline"), st.canSet, let lo = st.min?.first, let hi = st.max?.first,
              lo <= PictureFix.hz50, hi >= PictureFix.hz60 else { return }
        let original = value("powerline").first ?? 0
        var scores: [Int: Double] = [:]
        for hz in [PictureFix.hz50, PictureFix.hz60] {
            set("powerline", [hz])
            try? await Task.sleep(for: .seconds(0.6))
            let frames = await grabFrames(8)
            guard frames.count >= 2 else { set("powerline", [original]); return }
            scores[hz] = PictureFix.flickerScore(frames.map(\.rowMeans))
        }
        let pick = PictureFix.pickPowerline(score50: scores[PictureFix.hz50] ?? 0, score60: scores[PictureFix.hz60] ?? 0, current: original)
        Self.fixLog.debug("flicker 50=\(scores[PictureFix.hz50] ?? -1) 60=\(scores[PictureFix.hz60] ?? -1) pick=\(pick ?? -1)")
        set("powerline", [pick ?? original])
    }

    /// EV only while it is usable (AE auto); otherwise backlight and brightness.
    private func exposureControls() -> PictureFix.ExposureControls {
        var c = PictureFix.ExposureControls()
        if let ev = profileControls.first(where: { $0.id == "ev" }), isProfileControlEnabled("ev"),
           let lo = ev.ui.min, let hi = ev.ui.max, hi > lo, let cur = profileValues["ev"] {
            c.ev = .init(cur, lo ... hi)
        }
        func knob(_ id: String) -> PictureFix.Knob<Int>? {
            guard let st = state(id), st.canSet, let lo = st.min?.first, let hi = st.max?.first, hi > lo else { return nil }
            return .init(value(id).first ?? lo, lo ... hi)
        }
        c.backlight = knob("backlight")
        c.brightness = knob("brightness")
        return c
    }

    /// Stats of the next `count` frames, or what arrived within 1.5 s. The output connection goes back to
    /// what framing and zebra need afterwards.
    private func grabFrames(_ count: Int) async -> [FrameStats] {
        let framer = self.framer, queue = sessionQueue
        let frames: [FrameStats] = await withCheckedContinuation { k in
            // On the session queue so it lands after a pending startRunning().
            queue.async {
                let id = framer.requestFrames(count: count) { k.resume(returning: $0) }
                queue.asyncAfter(deadline: .now() + 1.5) { framer.finishFrameRequest(id) }
            }
        }
        queue.async { framer.updateConnection() }
        return frames
    }
}
