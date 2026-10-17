import Foundation
import IOKit

/// Game controllers in Wine.
///
/// Wine treats Sony pads (DualShock 4, DualSense) as raw "hidraw" devices and drops the SDL/XInput version of
/// the same pad. Games that only read XInput then see no controller. The Backbone One (PlayStation edition) is
/// affected because it presents itself over USB as a DualShock 4 (054C:09CC). Setting `Hidraw` to 0 for those
/// product IDs makes Wine expose them as XInput pads instead (verified on a Backbone One: the device gains an
/// `XI_00` entry). The IDs below are the ones Wine's own `is_dualshock4_gamepad` and `is_dualsense_gamepad` list.
public enum ControllerSupport {
    public static let sonyVendor: UInt16 = 0x054c

    public struct Pad: Sendable, Equatable {
        public let productID: UInt16
        public let name: String
    }

    public static let playStationPads: [Pad] = [
        Pad(productID: 0x05c4, name: "DualShock 4"),
        Pad(productID: 0x09cc, name: "DualShock 4 (v2, also the Backbone One PlayStation Edition)"),
        Pad(productID: 0x0ba0, name: "DualShock 4 Wireless Adapter"),
        Pad(productID: 0x0ce6, name: "DualSense"),
        Pad(productID: 0x0df2, name: "DualSense Edge"),
    ]

    /// Where winebus reads per-device options: `<vendor>/<product>` subkeys, each with a `Hidraw` DWORD.
    static let devicesKey = #"HKLM\System\CurrentControlSet\Services\WineBus\Devices"#

    static func deviceKey(_ pad: Pad) -> String {
        devicesKey + "\\" + hex4(sonyVendor) + "/" + hex4(pad.productID)
    }

    private static func hex4(_ value: UInt16) -> String {
        let s = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 4 - s.count)) + s
    }

    /// The `wine reg` arguments that turn the PlayStation-as-Xbox behaviour on (write `Hidraw=0`) or off
    /// (remove the keys, which restores Wine's default). Pure, so it is unit-tested.
    public static func registryCommands(playStationAsXbox enabled: Bool) -> [[String]] {
        playStationPads.map { pad in
            enabled
                ? ["reg", "add", deviceKey(pad), "/v", "Hidraw", "/t", "REG_DWORD", "/d", "0", "/f"]
                : ["reg", "delete", deviceKey(pad), "/f"]
        }
    }

    // MARK: What the Mac sees

    public enum Kind: String, Sendable {
        case playStation, xbox, nintendo, other

        public static func classify(vendorID: Int, productID: Int) -> Kind {
            switch vendorID {
            case Int(sonyVendor): playStationPads.contains { Int($0.productID) == productID } ? .playStation : .other
            case 0x045e: .xbox
            case 0x057e: .nintendo
            default: .other
            }
        }
    }

    public struct Connected: Sendable, Equatable, Identifiable {
        public let name: String
        public let vendorID: Int
        public let productID: Int
        public let locationID: Int
        public let transport: String
        public var kind: Kind { Kind.classify(vendorID: vendorID, productID: productID) }
        public var id: String { "\(vendorID):\(productID):\(locationID)" }
        public var idString: String { String(format: "%04X:%04X", vendorID, productID) }
    }

    /// Game controllers and joysticks the Mac currently has. It reads the I/O Registry only and never opens a
    /// device, so it needs no permission and cannot interfere with a game that is using the pad.
    public static func connected() -> [Connected] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        func property(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        var found: [Connected] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let page = property(entry, "PrimaryUsagePage") as? Int
            let usage = property(entry, "PrimaryUsage") as? Int
            guard page == 0x01, usage == 0x04 || usage == 0x05 else { continue }   // Generic Desktop: Joystick, Game Pad
            let device = Connected(
                name: (property(entry, "Product") as? String) ?? "Game controller",
                vendorID: (property(entry, "VendorID") as? Int) ?? 0,
                productID: (property(entry, "ProductID") as? Int) ?? 0,
                locationID: (property(entry, "LocationID") as? Int) ?? 0,
                transport: (property(entry, "Transport") as? String) ?? "")
            if !found.contains(where: { $0.id == device.id }) { found.append(device) }
        }
        return found.sorted { $0.name < $1.name }
    }
}

public extension WineRunner {
    /// Writes (or removes) the PlayStation-as-Xbox registry values in a bottle. They take effect the next time
    /// Wine starts in that bottle. Removing keys that don't exist is harmless.
    func applyControllerCompatibility(playStationAsXbox enabled: Bool, engine: Engine, bottle: Bottle) async {
        let env = Self.environment(bottle: bottle, profile: LaunchProfile())
        for arguments in ControllerSupport.registryCommands(playStationAsXbox: enabled) {
            _ = try? await ProcessRunner.run(engine.wine, arguments, environment: env)
        }
    }
}
