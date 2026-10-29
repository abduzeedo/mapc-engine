import Foundation
import Testing
@testable import MacadeKit

@Suite struct ControllerSupportTests {
    @Test func coversExactlyWinesPlayStationIDs() {
        // Wine's is_dualshock4_gamepad / is_dualsense_gamepad (dlls/winebus.sys/unixlib.h).
        #expect(ControllerSupport.playStationPads.map(\.productID).sorted() == [0x05c4, 0x09cc, 0x0ba0, 0x0ce6, 0x0df2].sorted())
    }

    @Test func enablingWritesHidrawZeroForEachPadUnderWinebus() {
        let commands = ControllerSupport.registryCommands(playStationAsXbox: true)
        #expect(commands.count == ControllerSupport.playStationPads.count)
        let backbone = commands.first { $0.contains { $0.hasSuffix(#"\054c/09cc"#) } }
        #expect(backbone == ["reg", "add", #"HKLM\System\CurrentControlSet\Services\WineBus\Devices\054c/09cc"#,
                             "/v", "Hidraw", "/t", "REG_DWORD", "/d", "0", "/f"])
        // Product IDs are zero-padded to four digits, as winebus parses them with %04x.
        #expect(commands.allSatisfy { $0[2].range(of: #"\\054c/[0-9a-f]{4}$"#, options: .regularExpression) != nil })
    }

    @Test func disablingRemovesTheSameKeys() {
        let on = ControllerSupport.registryCommands(playStationAsXbox: true).map { $0[2] }
        let off = ControllerSupport.registryCommands(playStationAsXbox: false)
        #expect(off.map { $0[2] } == on)
        #expect(off.allSatisfy { $0.prefix(2) == ["reg", "delete"] && $0.last == "/f" })
    }

    @Test func mappingsGoInAFileNotTheWinebusMapKey() throws {
        // Any value under WineBus\map crashes winebus (Wine's sdl_bus_load_mappings), so the key is only ever removed.
        #expect(ControllerSupport.mappingCleanupCommands() == [["reg", "delete", #"HKLM\System\CurrentControlSet\Services\WineBus\map"#, "/f"]])
        #expect(ControllerSupport.sdlMappingsVersion >= 2)   // bottles 1.1.15 wrote the key into get it removed

        let lines = ControllerSupport.mappingsFileContents().split(separator: "\n").map(String.init)
        #expect(lines.count == ControllerSupport.sdlMappings.flatMap(\.guids).count)
        let usb = try #require(lines.first { $0.hasPrefix("03000000c82d00001260000001000000,") })
        // A mapping SDL accepts: GUID, name, layout, then the platform it is for.
        #expect(usb.hasPrefix("03000000c82d00001260000001000000,8BitDo Ultimate 2 Wireless,a:b0,"))
        #expect(usb.hasSuffix(",platform:Mac OS X,"))
        #expect(lines.contains { $0.hasPrefix("05000000c82d00001260000001000000,") })   // Bluetooth
    }

    @Test func environmentPointsSDLAtTheBottleMappingsFile() {
        let bottle = Bottle(kind: .steam, paths: Paths(home: URL(fileURLWithPath: "/tmp/m")))
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile(), base: [:])
        #expect(env["SDL_GAMECONTROLLERCONFIG_FILE"] == ControllerSupport.mappingsFile(in: bottle).path)
        #expect(env["SDL_GAMECONTROLLERCONFIG"] == nil)   // would replace the file's mappings in winebus
    }

    @Test func mappingGUIDsAreSDLShaped() {
        // bus (03 USB / 05 Bluetooth), CRC 0, vendor and product little-endian, version: 32 lowercase hex digits.
        for guid in ControllerSupport.sdlMappings.flatMap(\.guids) {
            #expect(guid.range(of: "^0[35]000000[0-9a-f]{24}$", options: .regularExpression) != nil)
        }
        // Every layout names the standard XInput controls.
        for mapping in ControllerSupport.sdlMappings {
            for control in ["a", "b", "x", "y", "leftx", "lefty", "rightx", "righty", "lefttrigger", "righttrigger", "start"] {
                #expect(mapping.layout.split(separator: ",").contains { $0.hasPrefix(control + ":") })
            }
        }
    }

    @Test func classifiesPadsByVendorAndProduct() {
        #expect(ControllerSupport.Kind.classify(vendorID: 0x054c, productID: 0x09cc) == .playStation)   // Backbone One PS
        #expect(ControllerSupport.Kind.classify(vendorID: 0x054c, productID: 0x0ce6) == .playStation)   // DualSense
        #expect(ControllerSupport.Kind.classify(vendorID: 0x054c, productID: 0x0268) == .other)         // DualShock 3: not covered
        #expect(ControllerSupport.Kind.classify(vendorID: 0x045e, productID: 0x0b12) == .xbox)
        #expect(ControllerSupport.Kind.classify(vendorID: 0x057e, productID: 0x2009) == .nintendo)
        #expect(ControllerSupport.Kind.classify(vendorID: 0x1234, productID: 0x0001) == .other)
    }

    @Test func connectedPadsAreListedWithoutOpeningAnything() {
        // Whatever is plugged in, this must return cleanly and only contain gamepad/joystick entries once each.
        let pads = ControllerSupport.connected()
        #expect(Set(pads.map(\.id)).count == pads.count)
    }

    @Test func aPadSeenTwiceIsListedOnce() {
        func pad(_ name: String, _ location: Int, _ transport: String, virtual: Bool = false) -> ControllerSupport.Connected {
            .init(name: name, vendorID: 0x045e, productID: 0x028e, locationID: location, transport: transport, isVirtual: virtual)
        }
        // The report's Xbox 360 pad: a driver's copy with no transport next to the device.
        #expect(ControllerSupport.withoutDuplicates([pad("GamePad-1", 1, ""), pad("Wireless 360 Controller", 2, "Wireless")])
            .map(\.name) == ["Wireless 360 Controller"])
        #expect(ControllerSupport.withoutDuplicates([pad("Virtual", 1, "USB", virtual: true), pad("Pad", 2, "USB")])
            .map(\.name) == ["Pad"])
        // Two real pads of the same model stay two.
        #expect(ControllerSupport.withoutDuplicates([pad("A", 1, "USB"), pad("B", 2, "Bluetooth")]).count == 2)
        // A pad with no transport and nothing to duplicate is kept.
        #expect(ControllerSupport.withoutDuplicates([pad("GamePad-1", 1, "")]).count == 1)
    }

    @Test func settingsWithoutControllerKeysStillLoad() throws {
        let old = #"{"onboardingCompleted":true,"verboseLogs":false,"appliedRetina":{}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(s.playStationAsXbox == nil)            // nil means on
        #expect(s.appliedControllerCompat == nil)
        #expect(s.appliedControllerMappings == nil)
    }
}
