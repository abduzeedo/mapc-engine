import Foundation
import Testing
@testable import MacadeKit

@Suite struct ExternalDrivesTests {
    let fm = FileManager.default

    func makeBottle() throws -> (bottle: URL, dosdevices: URL) {
        let bottle = fm.temporaryDirectory.appendingPathComponent("drives-\(UUID().uuidString)")
        let dosdevices = bottle.appendingPathComponent("dosdevices")
        try fm.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: dosdevices.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: dosdevices.appendingPathComponent("z:").path, withDestinationPath: "/")
        return (bottle, dosdevices)
    }

    func target(_ dosdevices: URL, _ letter: String) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: dosdevices.appendingPathComponent(letter).path)
    }

    @Test func givesEachDriveTheNextFreeLetter() throws {
        let (bottle, dosdevices) = try makeBottle()
        defer { try? fm.removeItem(at: bottle) }
        // A letter in use (here a CD drive at d:) is skipped; Wine's raw device entries ("e::") don't take a letter.
        try fm.createSymbolicLink(atPath: dosdevices.appendingPathComponent("d:").path, withDestinationPath: "/Volumes/CD")
        try fm.createSymbolicLink(atPath: dosdevices.appendingPathComponent("e::").path, withDestinationPath: "/dev/disk4s1")
        let added = ExternalDrives.link([URL(fileURLWithPath: "/Volumes/TUF Gaming A2 SSD"), URL(fileURLWithPath: "/Volumes/Backup/")],
                                        in: bottle)
        #expect(added == ["e:": "/Volumes/TUF Gaming A2 SSD", "f:": "/Volumes/Backup"])
        #expect(target(dosdevices, "e:") == "/Volumes/TUF Gaming A2 SSD")
        #expect(target(dosdevices, "z:") == "/")
    }

    @Test func keepsLettersStableAndNeverAddsTwice() throws {
        let (bottle, dosdevices) = try makeBottle()
        defer { try? fm.removeItem(at: bottle) }
        let ssd = URL(fileURLWithPath: "/Volumes/SSD")
        #expect(ExternalDrives.link([ssd], in: bottle) == ["d:": "/Volumes/SSD"])
        #expect(ExternalDrives.link([ssd], in: bottle).isEmpty)
        // Unplugged: the dangling d: stays reserved, so another drive doesn't take it and the SSD gets d: back.
        #expect(ExternalDrives.link([URL(fileURLWithPath: "/Volumes/Stick")], in: bottle) == ["e:": "/Volumes/Stick"])
        #expect(ExternalDrives.link([ssd, URL(fileURLWithPath: "/Volumes/Stick")], in: bottle).isEmpty)
        #expect(target(dosdevices, "d:") == "/Volumes/SSD")
    }

    @Test func respectsALetterTheUserAlreadyMade() throws {
        let (bottle, dosdevices) = try makeBottle()
        defer { try? fm.removeItem(at: bottle) }
        try fm.createSymbolicLink(atPath: dosdevices.appendingPathComponent("g:").path, withDestinationPath: "/Volumes/SSD")
        #expect(ExternalDrives.link([URL(fileURLWithPath: "/Volumes/SSD")], in: bottle).isEmpty)
    }

    @Test func doesNothingWithoutAnEnvironment() {
        let missing = fm.temporaryDirectory.appendingPathComponent("drives-\(UUID().uuidString)")
        #expect(ExternalDrives.link([URL(fileURLWithPath: "/Volumes/SSD")], in: missing).isEmpty)
        #expect(!fm.fileExists(atPath: missing.path))
    }
}
