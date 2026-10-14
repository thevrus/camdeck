import Foundation
import IOKit

/// A USB 3 camera that enumerated at USB 2 speed or lower.
public struct USBLinkWarning: Equatable, Sendable {
    public var message: String { "Connected at USB 2 speed. Use a USB 3 port or cable for full quality." }
}

public enum USBLink {
    /// `speed` is IOKit's USBSpeed enum: 0 low, 1 full, 2 high, 3 super, 4 super+.
    /// Warns only for a device that advertises USB 3 (bcdUSB >= 0x0300) but linked below SuperSpeed.
    public static func assess(bcdUSB: Int, speed: Int) -> USBLinkWarning? {
        bcdUSB >= 0x0300 && speed < 3 ? USBLinkWarning() : nil
    }

    /// bcdUSB and link speed from the device's IOUSBHostDevice registry entry. Registry reads only.
    /// "Device Speed" is preferred: on this Mac "USBSpeed" read 3 for a device linked at 480 Mbit/s.
    static func read(_ s: io_service_t) -> (bcdUSB: Int, speed: Int)? {
        func int(_ k: String) -> Int? { IORegistryEntryCreateCFProperty(s, k as CFString, nil, 0)?.takeRetainedValue() as? Int }
        guard let bcd = int("bcdUSB"), let speed = int("Device Speed") ?? int("USBSpeed") else { return nil }
        return (bcd, speed)
    }
}
