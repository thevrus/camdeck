import Foundation

/// Builds one capability for a device. Runs on the caller's I/O thread; may do USB reads.
public typealias CapabilityFactory = @Sendable (UVCDevice) throws -> AnyObject

/// A driver contributes capabilities to devices it matches. Higher `specificity` wins per capability.
public protocol CameraDriver: Sendable {
    var name: String { get }
    /// 0 generic, 10 JSON profile, 20 code driver.
    var specificity: Int { get }
    func matches(_ d: CameraDescriptor) -> Bool
    /// Facts about the device that change what other drivers offer (e.g. CT pan/tilt is a no-op).
    func quirks(for d: CameraDescriptor) -> Set<CameraQuirk>
    func capabilities(for d: CameraDescriptor, quirks: Set<CameraQuirk>) -> [CapabilityKind: CapabilityFactory]
    /// Extension-unit selectors that must never be written, on any device.
    var forbiddenSelectors: [ForbiddenSelectorKey] { get }
}

public extension CameraDriver {
    func quirks(for d: CameraDescriptor) -> Set<CameraQuirk> { [] }
    var forbiddenSelectors: [ForbiddenSelectorKey] { [] }
}

/// Which driver provides which capability for a device. Pure: no USB traffic.
public struct CompositionPlan: Equatable, Sendable {
    public var drivers: [String]
    public var quirks: Set<CameraQuirk>
    public var providers: [CapabilityKind: String]
}

public struct DriverRegistry: Sendable {
    public var drivers: [CameraDriver]
    public init(drivers: [CameraDriver]) { self.drivers = drivers }

    /// Generic + every JSON profile (as loaded today) + code drivers.
    public static let standard = DriverRegistry(drivers: [GenericUVCDriver(), ProfileDriver(profiles: VendorProfiles.all), Insta360LinkDriver()])

    /// Union of every forbidden selector from all profiles and drivers; enforced by every UVCTransport.
    public static let allForbiddenSelectors: Set<ForbiddenSelectorKey> = Set(standard.drivers.flatMap(\.forbiddenSelectors))

    /// Drivers matching `d` in ascending specificity, and the union of their quirks.
    private func match(_ d: CameraDescriptor) -> (drivers: [CameraDriver], quirks: Set<CameraQuirk>) {
        let m = drivers.filter { $0.matches(d) }.sorted { $0.specificity < $1.specificity }
        return (m, m.reduce(into: Set<CameraQuirk>()) { $0.formUnion($1.quirks(for: d)) })
    }

    public func plan(for d: CameraDescriptor) -> CompositionPlan {
        let (m, quirks) = match(d)
        var providers: [CapabilityKind: String] = [:]
        for driver in m { // ascending specificity: later (more specific) overrides
            for k in driver.capabilities(for: d, quirks: quirks).keys { providers[k] = driver.name }
        }
        return CompositionPlan(drivers: m.map(\.name), quirks: quirks, providers: providers)
    }

    /// Composes the device's capabilities (does USB reads, e.g. zoom range). Call off the main thread.
    /// A capability whose factory fails falls back to the next less specific driver that offers it.
    public func compose(_ device: UVCDevice) -> CameraDevice {
        let d = device.descriptor
        let (m, quirks) = match(d)
        var built: [CapabilityKind: AnyObject] = [:]
        var providers: [CapabilityKind: String] = [:]
        for kind in CapabilityKind.allCases {
            for driver in m.reversed() {
                guard let f = driver.capabilities(for: d, quirks: quirks)[kind] else { continue }
                do { built[kind] = try f(device); providers[kind] = driver.name; break }
                catch { NSLog("\(driver.name): \(kind.rawValue) unavailable: \(error)") }
            }
        }
        return CameraDevice(device: device, plan: CompositionPlan(drivers: m.map(\.name), quirks: quirks, providers: providers), capabilities: built)
    }
}

/// A camera as the app sees it: a USB handle plus the capabilities composed for it.
public final class CameraDevice: @unchecked Sendable {
    public let device: UVCDevice
    public let plan: CompositionPlan
    public let imageControls: ImageControlsCapability?
    public let zoom: ZoomCapability?
    public let reframe: ReframeCapability?
    public let deviceInfo: DeviceInfoCapability?
    public let profileControls: ProfileControlsCapability?

    init(device: UVCDevice, plan: CompositionPlan, capabilities c: [CapabilityKind: AnyObject]) {
        self.device = device
        self.plan = plan
        imageControls = c[.imageControls] as? ImageControlsCapability
        zoom = c[.zoom] as? ZoomCapability
        reframe = c[.reframe] as? ReframeCapability
        deviceInfo = c[.deviceInfo] as? DeviceInfoCapability
        profileControls = c[.profileControls] as? ProfileControlsCapability
    }

    public var quirks: Set<CameraQuirk> { plan.quirks }
}
