import Foundation

/// A capture mode as (size, frame rate). Pure, so format selection is unit-testable.
public struct VideoMode: Hashable, Sendable {
    public var width: Int, height: Int, fps: Int
    public init(width: Int, height: Int, fps: Int) { self.width = width; self.height = height; self.fps = fps }
    public var id: String { "\(width)x\(height)@\(fps)" }
}

public enum VideoModeChooser {
    /// Highest resolution with a >= minFPS mode; 16:9 preferred; the lowest qualifying rate at that size (30 over 60).
    public static func natural(_ modes: [VideoMode], minFPS: Int) -> VideoMode? {
        let ok = modes.filter { $0.fps >= minFPS }
        let wide = ok.filter { abs(Double($0.width) / Double(max($0.height, 1)) - 16.0 / 9.0) < 0.02 }
        let pool = wide.isEmpty ? ok : wide
        return pool.min { a, b in
            let pa = a.width * a.height, pb = b.width * b.height
            if pa != pb { return pa > pb }
            return a.fps < b.fps
        }
    }

    /// Rates offered for one supported range: the common rates inside it plus its max.
    public static func offeredRates(minFrameRate: Double, maxFrameRate: Double) -> [Int] {
        let common = [60, 50, 30, 25, 24, 15].filter { Double($0) >= minFrameRate - 0.01 && Double($0) <= maxFrameRate + 0.01 }
        return Array(Set(common + [Int(maxFrameRate.rounded())])).sorted(by: >)
    }
}
