import AVFoundation
import UVCKit

struct FormatOption: Identifiable, Hashable {
    let id: String
    let width: Int
    let height: Int
    let fps: Int
    let format: AVCaptureDevice.Format

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var label: String {
        let res: String
        switch height {
        case 2160...: res = "4K"
        case 1440: res = "1440p"
        case 1080: res = "1080p"
        case 720: res = "720p"
        default: res = "\(width)×\(height)"
        }
        return "\(res) \(fps)"
    }

    static func options(for device: AVCaptureDevice) -> [FormatOption] {
        var seen = Set<String>()
        var out: [FormatOption] = []
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            for r in f.videoSupportedFrameRateRanges {
                // Ranges can be continuous (e.g. 1–60); offer the common rates inside them plus the max.
                for fps in VideoModeChooser.offeredRates(minFrameRate: r.minFrameRate, maxFrameRate: r.maxFrameRate) {
                    let id = VideoMode(width: Int(d.width), height: Int(d.height), fps: fps).id
                    if seen.insert(id).inserted {
                        out.append(FormatOption(id: id, width: Int(d.width), height: Int(d.height), fps: fps, format: f))
                    }
                }
            }
        }
        return out.sorted { ($0.height, $0.fps) > ($1.height, $1.fps) }
    }
}
