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
        var out: [FormatOption] = []
        var index: [String: Int] = [:]
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            for r in f.videoSupportedFrameRateRanges {
                // Ranges can be continuous (e.g. 1–60); offer the common rates inside them plus the max.
                for fps in VideoModeChooser.offeredRates(minFrameRate: r.minFrameRate, maxFrameRate: r.maxFrameRate) {
                    let id = VideoMode(width: Int(d.width), height: Int(d.height), fps: fps).id
                    let opt = FormatOption(id: id, width: Int(d.width), height: Int(d.height), fps: fps, format: f)
                    if let i = index[id] {
                        // Same mode in two pixel formats: keep 4:2:2 (2vuy), twice the color detail of 4:2:0.
                        if is422(f), !is422(out[i].format) { out[i] = opt }
                    } else {
                        index[id] = out.count
                        out.append(opt)
                    }
                }
            }
        }
        return out.sorted { ($0.height, $0.fps) > ($1.height, $1.fps) }
    }

    private static func is422(_ f: AVCaptureDevice.Format) -> Bool {
        CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_422YpCbCr8
    }
}
