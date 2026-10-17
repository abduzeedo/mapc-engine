import Foundation

public struct SystemReport: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case ok, warning(String), failed(String) }

    public var appleSilicon: Status
    public var macOS: Status
    public var rosetta: Status
    public var disk: Status
    public var memory: Status

    public var canContinue: Bool {
        for s in [appleSilicon, macOS, rosetta] { if case .failed = s { return false } }
        return true
    }
}

/// Probes the host for everything Macade needs (plan §4.9).
public struct SystemCheck: Sendable {
    public static let minMacOSMajor = 15
    public static let warnFreeBytes: Int64 = 30 * 1_000_000_000
    public static let warnMemoryBytes: UInt64 = 16 * 1_073_741_824

    public init() {}

    public func run(volume: URL = FileManager.default.homeDirectoryForCurrentUser) async -> SystemReport {
        SystemReport(
            appleSilicon: Self.sysctlInt("hw.optional.arm64") == 1
                ? .ok : .failed("MaPC needs a Mac with Apple Silicon."),
            macOS: ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Self.minMacOSMajor, minorVersion: 0, patchVersion: 0))
                ? .ok : .failed("MaPC needs macOS \(Self.minMacOSMajor) or later."),
            rosetta: await rosettaStatus(),
            disk: Self.diskStatus(volume),
            memory: ProcessInfo.processInfo.physicalMemory >= Self.warnMemoryBytes
                ? .ok : .warning("16 GB or more memory is recommended for demanding games.")
        )
    }

    public func rosettaStatus() async -> SystemReport.Status {
        let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", "/usr/bin/true"])
        return result?.succeeded == true ? .ok : .failed("Rosetta 2 is not installed.")
    }

    /// Installs Rosetta. Call only after explicit user confirmation.
    public func installRosetta() async throws -> Bool {
        let r = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/sbin/softwareupdate"), ["--install-rosetta", "--agree-to-license"])
        return r.succeeded
    }

    static func diskStatus(_ url: URL) -> SystemReport.Status {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return .ok }
        return free >= warnFreeBytes ? .ok : .warning("Less than 30 GB free. Games may not fit.")
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}
