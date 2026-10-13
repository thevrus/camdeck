import AVFoundation
import UVCKit

extension ZebraAnalyzer {
    /// Convenience for AVCaptureVideoDataOutputSampleBufferDelegate.captureOutput(_:didOutput:from:).
    func process(sampleBuffer: CMSampleBuffer) {
        guard isEnabled, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        process(pb)
    }
}
