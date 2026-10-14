import Foundation
import FoundationModels
import UVCKit

/// Availability of Apple's on-device model (Apple Intelligence). The requests themselves run in CameraAgent.
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
}
