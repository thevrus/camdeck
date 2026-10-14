import Foundation

/// Display text for the auto-exposure readout.
public enum ExposureFormat {
    private static let common = [2, 4, 5, 8, 10, 15, 20, 25, 30, 50, 60, 100, 120, 125, 200, 250, 500, 1000, 2000, 4000, 8000]

    /// UVC absolute exposure time (100 µs units) as "1/60 s", or "0.8 s" / "2 s" when slower than 1/2 s.
    public static func shutter(exposure100us v: Int) -> String? {
        guard v > 0 else { return nil }
        let denom = 10000.0 / Double(v)
        guard denom >= 2 else { return String(format: "%g s", (Double(v) / 1000).rounded() / 10) }
        return shutter(denominator: Int(denom.rounded()))
    }

    /// "1/x s" with x snapped to the nearest common value (by ratio).
    public static func shutter(denominator d: Int) -> String? {
        guard d > 0 else { return nil }
        let best = common.min { abs(log(Double($0) / Double(d))) < abs(log(Double($1) / Double(d))) } ?? d
        return "1/\(best) s"
    }

    /// "Auto: 1/60 s · gain 32"; nil when both parts are missing.
    public static func readout(shutter: String?, gainLabel: String?) -> String? {
        let parts = [shutter, gainLabel].compactMap { $0 }
        return parts.isEmpty ? nil : "Auto: " + parts.joined(separator: " · ")
    }
}
