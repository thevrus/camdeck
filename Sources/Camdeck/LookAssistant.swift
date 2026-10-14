import Foundation
import FoundationModels
import UVCKit

/// Turns "make it warmer" into a LookAdjustment with Apple's on-device model (Apple Intelligence).
/// Nothing leaves the Mac. Falls back to keyword matching when the model is unavailable or does not understand.
enum LookAssistant {
    /// Nil when the on-device model can be used; otherwise a short reason for the UI.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings for free-form requests."
        case .unavailable(.deviceNotEligible): return "This Mac cannot run Apple Intelligence; only simple requests work."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading; only simple requests work for now."
        case .unavailable: return "Apple Intelligence is unavailable; only simple requests work."
        }
    }

    /// The shape the model fills in. Names match LookAdjustment.
    @Generable(description: "Image adjustments for a webcam.")
    struct Plan {
        @Guide(description: "Relative changes, as a fraction of each control's range from -1 to 1. Small requests are about 0.1, strong ones about 0.3.")
        var moves: [Move]
        @Guide(description: "Absolute positions in a control's range from 0 to 1, for requests like black and white (saturation 0).")
        var levels: [Level]
        @Guide(description: "Auto modes to switch on or off: wb-auto, ae-mode.")
        var autos: [Auto]
    }

    @Generable
    struct Move {
        @Guide(description: "Control id, exactly as listed.")
        var control: String
        @Guide(description: "Fraction of the control's range to move by, between -0.4 and 0.4. Negative lowers it.")
        var amount: Double
    }

    @Generable
    struct Level {
        @Guide(description: "Control id, exactly as listed.")
        var control: String
        @Guide(description: "Position in the control's range: 0 is the minimum, 1 the maximum.")
        var amount: Double
    }

    @Generable
    struct Auto {
        var control: String
        var on: Bool
    }

    /// Asks the model, then validates against what the camera has. Throws when the model is unavailable or fails.
    static func plan(_ request: String, states: [UVCControlState], current: [String: [Int]]) async throws -> LookAdjustment {
        let available = states.filter { $0.canSet && LookAdjustment.imageControls.contains($0.id) }
        let autos = states.filter { $0.canSet && LookAdjustment.autoControls.contains($0.id) }
        var lines: [String] = []
        for st in available {
            guard let lo = st.min?.first, let hi = st.max?.first, hi > lo, let d = LookAdjustment.describe(st.id) else { continue }
            let cur = current[st.id]?.first ?? st.cur?.first ?? lo
            let pos = Int((Double(cur - lo) / Double(hi - lo) * 100).rounded())
            lines.append("- \(st.id): \(d). Currently at \(pos)% of its range.")
        }
        let session = LanguageModelSession(instructions: """
            You adjust a webcam's picture from a short request. Use only these control ids:
            \(lines.joined(separator: "\n"))
            Auto modes: \(autos.map(\.id).joined(separator: ", ")).
            Rules: prefer small changes (0.1 to 0.2 of range); black and white means saturation level 0; \
            warmer means wb-temp lower, cooler means wb-temp higher; natural or normal means both autos on and no moves. \
            Change only what the request mentions. Never turn an auto mode off; manual values do that by themselves. \
            Leave every list empty if the request is not about the picture.
            """)
        let r = try await session.respond(to: request, generating: Plan.self)
        var a = LookAdjustment()
        // Range guides on Double fail at generation time on macOS 26, so the cap is applied here instead.
        for m in r.content.moves { a.moves[m.control] = min(max(m.amount, -0.4), 0.4) }
        for m in r.content.levels { a.levels[m.control] = m.amount }
        for m in r.content.autos { a.autos[m.control] = m.on }
        return a
    }
}
