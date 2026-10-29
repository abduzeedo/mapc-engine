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

    // MARK: SDL mappings

    /// Pads the engine's SDL (2.32.8, from the pinned Gcenx runtime) has no macOS mapping for. Without one, winebus
    /// exposes the pad as a plain joystick: XInput games see nothing, others get raw axes ("up is down"). Worse,
    /// Steam's own SDL3 inside Wine has an 8BitDo HIDAPI driver that claims these pads by ID and decodes Wine's
    /// synthesized HID reports as if they were the pad's own, so Steam Input scrambles them. With a mapping, Wine
    /// presents an XInput gamepad and both paths work. The layouts match SDL_GameControllerDB's Linux entries for the
    /// same pad, which line up with its macOS entry for the Ultimate 2C (same axis order).
    public struct Mapping: Sendable, Equatable {
        public let name: String
        /// SDL GUIDs for the pad, one per bus (USB 03, Bluetooth 05).
        public let guids: [String]
        public let layout: String

        /// SDL mapping strings, `<guid>,<name>,<layout>,platform:Mac OS X,`.
        public var lines: [String] { guids.map { "\($0),\(name),\(layout),platform:Mac OS X," } }
    }

    public static let sdlMappings: [Mapping] = [
        Mapping(name: "8BitDo Ultimate 2 Wireless",   // 2DC8:6012
                guids: ["03000000c82d00001260000001000000", "05000000c82d00001260000001000000"],
                layout: "a:b0,b:b1,back:b10,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b6,"
                    + "leftstick:b13,lefttrigger:a5,leftx:a0,lefty:a1,paddle1:b17,paddle2:b16,paddle3:b2,paddle4:b5,"
                    + "rightshoulder:b7,rightstick:b14,righttrigger:a4,rightx:a2,righty:a3,start:b11,x:b3,y:b4"),
    ]

    /// Bump when `sdlMappings` or the way they are delivered changes, so every bottle gets `applyControllerMappings`
    /// again. 2: mappings moved from the registry to a file (see `mappingsKey`).
    public static let sdlMappingsVersion = 2

    /// Where MaPC 1.1.15 wrote the mappings. Don't write here: Wine's `sdl_bus_load_mappings` (still the same in
    /// Wine 11 and master) copies each value into the wrong slot of its array, so any REG_SZ value under this key
    /// makes winebus crash when it starts ("Auto-start service winebus failed to start"). No controller then reaches
    /// Windows at all, Xbox and PlayStation pads included. `applyControllerMappings` deletes the key.
    static let mappingsKey = #"HKLM\System\CurrentControlSet\Services\WineBus\map"#

    /// The `wine reg` arguments that remove `mappingsKey`. Removing a key that isn't there is harmless.
    public static func mappingCleanupCommands() -> [[String]] {
        [["reg", "delete", mappingsKey, "/f"]]
    }

    /// The bottle file `SDL_GAMECONTROLLERCONFIG_FILE` points at. SDL reads it when winebus starts it, keeping only
    /// lines for its own platform. Windows programs (Steam's own SDL3) inherit the variable but can't open a Mac path.
    public static func mappingsFile(in bottle: Bottle) -> URL {
        bottle.url.appendingPathComponent("sdl-controller-mappings.txt")
    }

    /// `sdlMappings` in SDL_GameControllerDB's file format, one mapping per line.
    public static func mappingsFileContents() -> String {
        sdlMappings.flatMap(\.lines).map { $0 + "\n" }.joined()
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
        /// Made by software (`IOHIDUserDevice`, a driver's virtual pad), not a device on a bus.
        public var isVirtual = false
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
                transport: (property(entry, "Transport") as? String) ?? "",
                isVirtual: (property(entry, "HIDVirtualDevice") as? Bool) ?? false)
            if !found.contains(where: { $0.id == device.id }) { found.append(device) }
        }
        return withoutDuplicates(found).sorted { $0.name < $1.name }
    }

    /// One pad can show up twice: the device itself and a copy a third-party driver publishes for it (an Xbox 360
    /// pad listed as "GamePad-1" and as "Wireless 360 Controller", same 045E:028E, different location). A virtual
    /// entry, or one with no transport, is dropped when a real one with the same IDs is there. Two real pads of
    /// the same model both have a transport and both stay.
    static func withoutDuplicates(_ devices: [Connected]) -> [Connected] {
        func isReal(_ d: Connected) -> Bool { !d.isVirtual && !d.transport.isEmpty }
        return devices.filter { device in
            isReal(device) || !devices.contains { other in
                isReal(other) && other.vendorID == device.vendorID && other.productID == device.productID
            }
        }
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

    /// Writes `ControllerSupport.sdlMappings` into the bottle's mappings file and removes the registry key 1.1.15
    /// wrote them to, which stops winebus from starting. Wine reads both when it starts.
    func applyControllerMappings(engine: Engine, bottle: Bottle) async {
        try? Data(ControllerSupport.mappingsFileContents().utf8).write(to: ControllerSupport.mappingsFile(in: bottle), options: .atomic)
        let env = Self.environment(bottle: bottle, profile: LaunchProfile())
        for arguments in ControllerSupport.mappingCleanupCommands() {
            _ = try? await ProcessRunner.run(engine.wine, arguments, environment: env)
        }
    }
}
