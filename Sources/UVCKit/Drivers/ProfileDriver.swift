import Foundation

/// JSON profiles (docs/profile-schema.md): simple XU scalars/bits, naturalDefaults, forbidden selectors.
/// The first profile matching VID/PID applies, as before.
public struct ProfileDriver: CameraDriver {
    public let name = "Profile"
    public let specificity = 10
    public let profiles: [DeviceProfile]
    public init(profiles: [DeviceProfile]) { self.profiles = profiles }

    public func profile(for d: CameraDescriptor) -> DeviceProfile? {
        profiles.first { $0.matches(vendorID: d.vendorID, productID: d.productID) }
    }

    public func matches(_ d: CameraDescriptor) -> Bool { profile(for: d) != nil }

    public func capabilities(for d: CameraDescriptor, quirks: Set<CameraQuirk>) -> [CapabilityKind: CapabilityFactory] {
        guard let p = profile(for: d) else { return [:] }
        return [.profileControls: { dev in ProfileControls(dev, profile: p) }]
    }

    public var forbiddenSelectors: [ForbiddenSelectorKey] {
        profiles.flatMap { p in p.forbiddenSelectors.map { ForbiddenSelectorKey(guid: p.guid(for: $0.unit), selector: $0.selector) } }
    }
}

final class ProfileControls: ProfileControlsCapability, @unchecked Sendable {
    let dev: UVCDevice
    let profile: DeviceProfile
    let controls: [ProfileControl]
    init(_ dev: UVCDevice, profile: DeviceProfile) {
        self.dev = dev; self.profile = profile
        controls = profile.controls.filter { dev.unitID(forGUID: profile.guid(for: $0.unit)) != nil }
    }
    func read(_ c: ProfileControl) throws -> Int { try dev.readProfile(c) }
    func write(_ c: ProfileControl, wire: Int) throws { try dev.writeProfile(c, wire: wire) }
}
