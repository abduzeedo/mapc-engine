import Foundation
import Security

public enum D3DMetalError: Error, LocalizedError, Equatable {
    case couldNotOpen
    case notFound
    case notSignedByApple(String)
    case missingModule(String)
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .couldNotOpen:
            "Couldn't open the disk image. Open it in Finder first (agree to Apple's license if asked), then choose the opened disk."
        case .notFound:
            "That file doesn't contain D3DMetal. Choose the Game Porting Toolkit disk image you downloaded from Apple."
        case .notSignedByApple(let item):
            "\(item) isn't signed by Apple, so MaPC won't use it. Download the Game Porting Toolkit again from developer.apple.com."
        case .missingModule(let name):
            "This Game Porting Toolkit is missing \(name). Download the current version from developer.apple.com."
        case .copyFailed(let m):
            "Couldn't install D3DMetal. \(m)"
        }
    }
}

public struct D3DMetalInfo: Codable, Sendable, Equatable {
    public var version: String
    public var importedAt: Date
}

/// D3DMetal checked and copied out of the user's download, waiting for them to accept Apple's license.
public struct StagedD3DMetal: Sendable {
    public let directory: URL
    public let info: D3DMetalInfo
    /// Apple's license as shipped in the toolkit (text or RTF), if one was found.
    public let license: URL?
}

/// Apple's D3DMetal (DirectX 12 on Metal). Its license only allows non-commercial redistribution, so Macade
/// never ships it: the user downloads Apple's Game Porting Toolkit, and Macade copies D3DMetal out of it,
/// byte for byte, after checking Apple's code signature. The copy lives in `Paths.d3dMetal` and is linked
/// into every engine that can use it, so engine updates don't lose it.
public struct D3DMetalStore: Sendable {
    /// Windows modules that come with D3DMetal (the rest of Direct3D stays Wine's).
    static let modules = ["d3d10", "d3d11", "d3d12", "dxgi", "atidxx64", "nvapi64", "nvngx", "nvngx-on-metalfx"]
    static let requiredModules: Set = ["d3d11", "d3d12", "dxgi"]
    static let marker = ".macade-d3dmetal"

    /// Apple's download page for the toolkit (free Apple Account sign-in).
    public static let downloadPage = URL(string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit")!

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    var root: URL { paths.d3dMetal }
    var infoFile: URL { root.appendingPathComponent("D3DMETAL.json") }

    /// The imported D3DMetal, if any.
    public var installed: D3DMetalInfo? {
        guard let data = try? Data(contentsOf: infoFile),
              let info = try? JSONDecoder.iso.decode(D3DMetalInfo.self, from: data),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("external/libd3dshared.dylib").path)
        else { return nil }
        return info
    }

    public var licenseFile: URL? {
        ["LICENSE.rtf", "LICENSE.txt"].map(root.appendingPathComponent).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Import

    /// Opens `source` (Apple's `.dmg`, an opened toolkit disk, or a folder inside it), checks D3DMetal's
    /// signature and copies it into a staging folder. Nothing is installed until `commit`.
    public func stage(from source: URL) async throws -> StagedD3DMetal {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let staging = paths.home.appendingPathComponent(".d3dmetal-\(UUID().uuidString)", isDirectory: true)
        do {
            if source.pathExtension.lowercased() == "dmg" {
                return try await stageImage(source, to: staging, nestedLevels: 1)
            }
            do { return try copy(from: source, to: staging) }
            catch D3DMetalError.notFound {
                // The user opened Apple's disk and chose it; D3DMetal is in the image inside.
                guard let inner = Self.nestedImage(in: source) else { throw D3DMetalError.notFound }
                return try await stageImage(inner, to: staging, nestedLevels: 0)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Mounts `image` and copies D3DMetal out of it. Since Game Porting Toolkit 3.0, Apple's download is a disk
    /// image holding another one ("Evaluation environment for Windows games"), which is where D3DMetal is.
    private func stageImage(_ image: URL, to staging: URL, nestedLevels: Int) async throws -> StagedD3DMetal {
        let mount = try await Self.attach(image)
        let result: Result<StagedD3DMetal, Error>
        do { result = .success(try copy(from: mount, to: staging)) }
        catch D3DMetalError.notFound where nestedLevels > 0 {
            if let inner = Self.nestedImage(in: mount) {
                do { result = .success(try await stageImage(inner, to: staging, nestedLevels: nestedLevels - 1)) }
                catch { result = .failure(error) }
            } else {
                result = .failure(D3DMetalError.notFound)
            }
        } catch {
            result = .failure(error)
        }
        await Self.detach(mount)
        return try result.get()
    }

    /// A disk image at the top of `folder`, preferring Apple's evaluation environment.
    static func nestedImage(in folder: URL) -> URL? {
        let images = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "dmg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return images.first { $0.lastPathComponent.localizedCaseInsensitiveContains("evaluation") } ?? images.first
    }

    /// Installs a staged copy (the user accepted Apple's license) and links it into `engines`.
    public func commit(_ staged: StagedD3DMetal, engines: [Engine]) throws {
        let fm = FileManager.default
        let old = paths.home.appendingPathComponent(".d3dmetal-old-\(UUID().uuidString)", isDirectory: true)
        if fm.fileExists(atPath: root.path) { try fm.moveItem(at: root, to: old) }
        do { try fm.moveItem(at: staged.directory, to: root) }
        catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: root) }
            throw D3DMetalError.copyFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: old)
        for engine in engines { try link(into: engine) }
    }

    public func discard(_ staged: StagedD3DMetal) {
        try? FileManager.default.removeItem(at: staged.directory)
    }

    // MARK: Engines

    /// Whether `engine` is built to run D3DMetal (Macade's CrossOver-based engines).
    public static func canUse(_ engine: Engine) -> Bool {
        engine.info.backends.contains(GraphicsBackend.d3dMetal.rawValue)
    }

    /// Copies the imported D3DMetal into `engine` unless it already has this version. APFS clones the files,
    /// so each engine costs almost no extra disk space.
    public func link(into engine: Engine) throws {
        guard Self.canUse(engine), let info = installed else { return }
        let fm = FileManager.default
        let lib = engine.wineRoot.appendingPathComponent("lib")
        let external = lib.appendingPathComponent("external")
        let marker = external.appendingPathComponent(Self.marker)
        if (try? String(contentsOf: marker, encoding: .utf8)) == info.version { return }
        do {
            let fresh = lib.appendingPathComponent("external.new")
            try? fm.removeItem(at: fresh)
            try fm.copyItem(at: root.appendingPathComponent("external"), to: fresh)
            try? fm.removeItem(at: external)
            try fm.moveItem(at: fresh, to: external)

            let windows = lib.appendingPathComponent("wine/x86_64-windows")
            let unix = lib.appendingPathComponent("wine/x86_64-unix")
            try WineD3DFallback.stashOriginals(of: engine)
            for module in Self.modules {
                let dll = root.appendingPathComponent("x86_64-windows/\(module).dll")
                guard fm.fileExists(atPath: dll.path) else { continue }
                let target = windows.appendingPathComponent("\(module).dll")
                try? fm.removeItem(at: target)
                try fm.copyItem(at: dll, to: target)
                // D3DMetal's DLLs call into Metal through libd3dshared, which Wine loads as the module's unix side.
                let so = unix.appendingPathComponent("\(module).so")
                try? fm.removeItem(at: so)
                try fm.createSymbolicLink(atPath: so.path, withDestinationPath: "../../external/libd3dshared.dylib")
            }
            try info.version.write(to: marker, atomically: true, encoding: .utf8)
        } catch {
            throw D3DMetalError.copyFailed(error.localizedDescription)
        }
    }

    // MARK: Helpers

    private func copy(from source: URL, to staging: URL) throws -> StagedD3DMetal {
        let fm = FileManager.default
        guard let found = Self.locate(in: source) else { throw D3DMetalError.notFound }
        let windows = found.appendingPathComponent("wine/x86_64-windows")
        for module in Self.requiredModules where !fm.fileExists(atPath: windows.appendingPathComponent("\(module).dll").path) {
            throw D3DMetalError.missingModule("\(module).dll")
        }
        do {
            try fm.createDirectory(at: staging.appendingPathComponent("x86_64-windows"), withIntermediateDirectories: true)
            try fm.copyItem(at: found.appendingPathComponent("external"), to: staging.appendingPathComponent("external"))
            for module in Self.modules {
                let dll = windows.appendingPathComponent("\(module).dll")
                if fm.fileExists(atPath: dll.path) {
                    try fm.copyItem(at: dll, to: staging.appendingPathComponent("x86_64-windows/\(module).dll"))
                }
            }
        } catch {
            throw D3DMetalError.copyFailed(error.localizedDescription)
        }

        // Check the copies, not the source: these are the bytes that will run.
        let framework = staging.appendingPathComponent("external/D3DMetal.framework")
        for item in [framework, staging.appendingPathComponent("external/libd3dshared.dylib")] where !Self.isSignedByApple(item) {
            throw D3DMetalError.notSignedByApple(item.lastPathComponent)
        }
        // Copies from a downloaded disk image carry the quarantine flag; the signature check above replaces it.
        Self.removeQuarantine(staging)

        var license: URL?
        if let shipped = Self.findLicense(near: found, in: source) {
            let dest = staging.appendingPathComponent(shipped.pathExtension.lowercased() == "rtf" ? "LICENSE.rtf" : "LICENSE.txt")
            if (try? fm.copyItem(at: shipped, to: dest)) != nil { license = dest }
        }
        let bundle = Bundle(url: framework)
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let info = D3DMetalInfo(version: version, importedAt: Date())
        try JSONEncoder.iso.encode(info).write(to: staging.appendingPathComponent("D3DMETAL.json"))
        return StagedD3DMetal(directory: staging, info: info, license: license)
    }

    /// Finds the `lib` folder holding `external/libd3dshared.dylib` (Apple's image keeps it in `redist/lib`).
    static func locate(in source: URL) -> URL? {
        let fm = FileManager.default
        func isLib(_ dir: URL) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent("external/libd3dshared.dylib").path)
                && fm.fileExists(atPath: dir.appendingPathComponent("external/D3DMetal.framework").path)
        }
        if isLib(source) { return source }
        if isLib(source.appendingPathComponent("lib")) { return source.appendingPathComponent("lib") }
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return nil }
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if item.lastPathComponent == "lib", isLib(item) { return item }
            if walker.level >= 6 || item.pathExtension == "framework" { walker.skipDescendants() }
        }
        return nil
    }

    private static func findLicense(near lib: URL, in source: URL) -> URL? {
        let fm = FileManager.default
        var candidates = [lib.appendingPathComponent("external/D3DMetal.framework/Versions/A/Resources/LICENSE")]
        var dir = lib
        while dir.path.hasPrefix(source.path) {
            for name in ["License.rtf", "LICENSE.rtf", "License.txt", "LICENSE.txt", "LICENSE"] {
                candidates.append(dir.appendingPathComponent(name))
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// True only for code signed by Apple itself (not a third-party Developer ID), with every nested item intact.
    static func isSignedByApple(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    }

    private static func removeQuarantine(_ dir: URL) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", dir.path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    /// Mounts a disk image read-only, hidden from Finder, at a private mount point.
    static func attach(_ image: URL) async throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("macade-gptk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
            ["attach", image.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path])
        guard result.succeeded else {
            try? FileManager.default.removeItem(at: mountPoint)
            throw D3DMetalError.couldNotOpen
        }
        return mountPoint
    }

    static func detach(_ mountPoint: URL) async {
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        if (try? await ProcessRunner.run(hdiutil, ["detach", mountPoint.path]))?.succeeded != true {
            _ = try? await ProcessRunner.run(hdiutil, ["detach", mountPoint.path, "-force"])
        }
        try? FileManager.default.removeItem(at: mountPoint)
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
