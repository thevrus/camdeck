import Foundation
import os

/// One USB EP0 class request. `UVCTransport` is the only caller; IOKit in the app, a fake in tests.
public protocol UVCRequestChannel: AnyObject, Sendable {
    /// Performs the request. IN requests return the bytes received; OUT requests return `[]` or the data.
    func deviceRequest(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, data: [UInt8]) throws -> [UInt8]
}

/// Spacing rules for control requests. Pure (time is passed in), so it is unit-testable.
/// The vendor app crashed at ~400 req/s, hence a hard cap well below that.
public struct UVCRateLimiter: Sendable {
    /// Minimum gap between two requests.
    public var minSpacing: TimeInterval
    /// Hard cap on requests in any one-second window.
    public var maxPerSecond: Int
    private var recent: [TimeInterval] = []

    public init(minSpacing: TimeInterval = 0.005, maxPerSecond: Int = 100) {
        self.minSpacing = minSpacing
        self.maxPerSecond = max(maxPerSecond, 1)
    }

    /// Reserves a slot for a request that wants to go at `now`; returns the time it may go.
    public mutating func reserve(now: TimeInterval) -> TimeInterval {
        var t = now
        if let last = recent.last { t = max(t, last + minSpacing) }
        recent.removeAll { $0 <= t - 1 }
        if recent.count >= maxPerSecond {
            t = max(t, recent[recent.count - maxPerSecond] + 1)
            recent.removeAll { $0 <= t - 1 }
        }
        recent.append(t)
        return t
    }
}

/// Process-wide serial queue plus rate limiter: every UVC control request of every device goes
/// through `perform`, one at a time, spaced by the limiter.
public final class UVCRequestScheduler: @unchecked Sendable {
    public static let shared = UVCRequestScheduler()

    private let queue = DispatchQueue(label: "app.camdeck.uvc.transport")
    private var limiter: UVCRateLimiter
    private let clock: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) -> Void

    public init(limiter: UVCRateLimiter = UVCRateLimiter(),
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.limiter = limiter; self.clock = clock; self.sleep = sleep
    }

    public func perform<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync {
            let now = clock()
            let at = limiter.reserve(now: now)
            if at > now { sleep(at - now) }
            return try body()
        }
    }
}

/// Extension-unit selector that must never be written.
public struct ForbiddenSelectorKey: Hashable, Sendable {
    public let guid: String
    public let selector: Int
    public init(guid: String, selector: Int) { self.guid = guid.lowercased(); self.selector = selector }
}

/// The single path to the camera: serial, rate-limited, and guarded against forbidden selectors.
public final class UVCTransport: @unchecked Sendable {
    public let topology: UVCTopology
    public let forbidden: Set<ForbiddenSelectorKey>
    private let channel: UVCRequestChannel
    private let scheduler: UVCRequestScheduler
    /// Held across a read-modify-write so two writers cannot interleave.
    private let rmwLock = NSRecursiveLock()
    private static let log = Logger(subsystem: "app.camdeck.uvckit", category: "transport")

    public init(channel: UVCRequestChannel, topology: UVCTopology,
                forbidden: Set<ForbiddenSelectorKey> = DriverRegistry.allForbiddenSelectors,
                scheduler: UVCRequestScheduler = .shared) {
        self.channel = channel; self.topology = topology; self.forbidden = forbidden; self.scheduler = scheduler
    }

    /// Throws `UVCError.forbidden` if (unit, selector) is an extension-unit selector on the list.
    public func guardWrite(unit: UInt8, selector: UInt8) throws {
        try Self.guardWrite(topology: topology, forbidden: forbidden, unit: unit, selector: selector)
    }

    public static func guardWrite(topology: UVCTopology, forbidden: Set<ForbiddenSelectorKey>, unit: UInt8, selector: UInt8) throws {
        guard let xu = topology.extensionUnits.first(where: { $0.id == unit }) else { return }
        if forbidden.contains(ForbiddenSelectorKey(guid: xu.guid, selector: Int(selector))) {
            throw UVCError.forbidden("\(xu.guid) selector \(selector)")
        }
    }

    public func get(unit: UInt8, selector: UInt8, length: Int, request: UVCRequest = .cur) throws -> [UInt8] {
        try transfer(0xA1, request.rawValue, unit: unit, selector: selector, data: [UInt8](repeating: 0, count: length))
    }

    /// SET_CUR. Refuses forbidden extension-unit selectors before anything reaches the bus.
    public func set(unit: UInt8, selector: UInt8, data: [UInt8]) throws {
        try guardWrite(unit: unit, selector: selector)
        Self.log.debug("SET_CUR unit \(unit) sel \(selector) \(data.map { String(format: "%02x", $0) }.joined(), privacy: .public)")
        _ = try transfer(0x21, 0x01, unit: unit, selector: selector, data: data)
    }

    /// GET_LEN (u16 LE).
    public func length(unit: UInt8, selector: UInt8) throws -> Int {
        let b = try get(unit: unit, selector: selector, length: 2, request: .len)
        guard b.count >= 2 else { throw UVCError.io(-1) }
        return Int(b[0]) | Int(b[1]) << 8
    }

    /// Reads `length` bytes, lets `modify` change them, writes them back, all under one lock.
    /// The guard runs before the read, so a forbidden selector is not even read.
    public func readModifyWrite(unit: UInt8, selector: UInt8, length: Int, _ modify: ([UInt8]) throws -> [UInt8]) throws {
        try guardWrite(unit: unit, selector: selector)
        rmwLock.lock(); defer { rmwLock.unlock() }
        let cur = try get(unit: unit, selector: selector, length: length)
        guard cur.count == length else { throw UVCError.io(-1) }
        try set(unit: unit, selector: selector, data: try modify(cur))
    }

    /// Runs `body` while holding the read-modify-write lock (for callers composing their own RMW).
    public func withRMWLock<T>(_ body: () throws -> T) rethrows -> T {
        rmwLock.lock(); defer { rmwLock.unlock() }
        return try body()
    }

    private func transfer(_ type: UInt8, _ req: UInt8, unit: UInt8, selector: UInt8, data: [UInt8]) throws -> [UInt8] {
        let value = UInt16(selector) << 8
        let index = UInt16(unit) << 8 | UInt16(topology.controlInterface)
        return try scheduler.perform {
            try channel.deviceRequest(requestType: type, request: req, value: value, index: index, data: data)
        }
    }
}
