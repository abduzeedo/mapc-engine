import Foundation
import Testing
@testable import MacadeKit

@Suite struct GOGParserTests {
    @Test func ownedWindowsGamesOnly() throws {
        let json = #"""
        {"totalPages":2,"products":[
          {"id":1207658924,"title":"Unreal Tournament 2004","isGame":true,"worksOn":{"Windows":true,"Mac":false}},
          {"id":1,"title":"A Movie","isGame":false,"worksOn":{"Windows":true}},
          {"id":2,"title":"Mac Only","isGame":true,"worksOn":{"Windows":false,"Mac":true}}]}
        """#
        let result = try GOGParser.products(Data(json.utf8))
        #expect(result.totalPages == 2)
        #expect(result.games.map(\.id) == ["1207658924"])
    }

    @Test func artworkFromGamesDB() {
        let json = #"{"game":{"vertical_cover":{"url_format":"https://images.gog.com/abc{formatter}.{ext}?namespace=gamesdb"},"background":{"url_format":"https://images.gog.com/def{formatter}.{ext}"}}}"#
        let art = GOGParser.artwork(Data(json.utf8))
        #expect(art.cover?.absoluteString == "https://images.gog.com/abc.jpg?namespace=gamesdb")
        #expect(art.background?.absoluteString == "https://images.gog.com/def.jpg")
        #expect(art.logo == nil)
    }

    @Test func progressLine() {
        #expect(GOGParser.progress(from: "[PROGRESS] INFO: = Progress: 42.50 1048576/8388608, Running for 00:00:10") == 0.425)
        #expect(GOGParser.progress(from: "[PROGRESS] INFO: = Downloaded: 12.00 MiB") == nil)
    }

    @Test func credentials() {
        #expect(GOGParser.credentials(Data(#"{"access_token":"t","user_id":"1","expires_in":3600}"#.utf8))?.access_token == "t")
        #expect(GOGParser.credentials(Data(#"{"error":true}"#.utf8)) == nil)
        #expect(GOGParser.credentials(Data("null".utf8)) == nil)
    }

    @Test func primaryPlayTask() {
        let json = #"""
        {"playTasks":[
          {"category":"tool","type":"FileTask","path":"Tools\\Editor.exe"},
          {"isPrimary":true,"type":"FileTask","path":"System\\UT2004.exe","workingDir":"System","arguments":"-windowed \"some arg\""},
          {"type":"URLTask","link":"https://example.com"}]}
        """#
        let task = GOGParser.playTask(infoJSON: Data(json.utf8))
        #expect(task == .init(path: #"System\UT2004.exe"#, arguments: ["-windowed", "some arg"], workingDirectory: "System"))
    }

    /// Mafia: Definitive Edition: the primary task is a .NET launcher that Wine can't run without Mono.
    @Test func launcherPrimaryFallsBackToGameTask() {
        let json = #"""
        {"playTasks":[
          {"category":"launcher","isPrimary":true,"type":"FileTask","path":"launcher.exe"},
          {"category":"game","isHidden":true,"type":"FileTask","path":"mafiadefinitiveedition.exe"}]}
        """#
        #expect(GOGParser.playTask(infoJSON: Data(json.utf8))?.path == "mafiadefinitiveedition.exe")
    }

    @Test func launcherPrimaryWithoutGameTaskStays() {
        let json = #"{"playTasks":[{"category":"launcher","isPrimary":true,"type":"FileTask","path":"launcher.exe"}]}"#
        #expect(GOGParser.playTask(infoJSON: Data(json.utf8))?.path == "launcher.exe")
    }
}

@Suite struct LauncherStoreTests {
    @Test func ubisoftInstallsFromRegistry() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-ubi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bottle = Bottle(kind: .ubisoft, paths: Paths(home: home))
        let game = bottle.driveC.appendingPathComponent("Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Far Cry 3")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let reg = #"""
        WINE REGISTRY Version 2

        [Software\\Wow6432Node\\Ubisoft\\Launcher] 1700000000
        "InstallDir"="C:/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/"

        [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\46] 1700000001
        #time=1d9
        "InstallDir"="C:/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Far Cry 3/"

        [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\99] 1700000002
        "InstallDir"="C:/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Removed Game/"
        """#
        let games = LauncherStore.ubisoftGames(systemReg: reg, bottle: bottle)
        #expect(games.map(\.id) == ["ubisoft:46"])
        #expect(games.first?.title == "Far Cry 3")
    }

    @Test func eaContentID() {
        let xml = "<DiPManifest><contentIDs><contentID>71173</contentID><contentID>1035052</contentID></contentIDs></DiPManifest>"
        #expect(LauncherStore.eaContentID(installerXML: xml) == "71173")
        #expect(LauncherStore.eaContentID(installerXML: "<x/>") == nil)
    }
}

@Suite struct RuntimeProvisioningTests {
    @Test func copiesMFCFromAnotherBottleWithoutOverwriting() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-rt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let fm = FileManager.default
        func put(_ kind: BottleKind, _ file: String, _ text: String) throws {
            let url = Bottle(kind: kind, paths: paths).driveC.appendingPathComponent("windows/\(file)")
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try put(.steam, "system32/mfc140u.dll", "steam")
        try put(.steam, "syswow64/mfc140u.dll", "steam32")
        try put(.gog, "system32/kernel32.dll", "x")           // makes the gog bottle "exist"
        try put(.gog, "syswow64/mfc140u.dll", "mine")          // must survive

        let copied = BottleManager(paths: paths).provisionRuntime(in: .gog)
        #expect(copied == ["system32/mfc140u.dll"])
        let gog = Bottle(kind: .gog, paths: paths).driveC
        #expect(try String(contentsOf: gog.appendingPathComponent("windows/system32/mfc140u.dll"), encoding: .utf8) == "steam")
        #expect(try String(contentsOf: gog.appendingPathComponent("windows/syswow64/mfc140u.dll"), encoding: .utf8) == "mine")
    }
}

@Suite struct EAAppAndMonoTests {
    private func tempPaths() -> (Paths, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-ea-\(UUID().uuidString)")
        return (Paths(home: home), home)
    }

    /// The real layout after Wine installs the EA app: versioned folders, an empty `EA Desktop?` where the junction failed.
    @Test func findsTheNewestVersionedEADesktop() throws {
        let (paths, home) = tempPaths()
        defer { try? FileManager.default.removeItem(at: home) }
        let bottle = Bottle(kind: .ea, paths: paths)
        let root = bottle.driveC.appendingPathComponent("Program Files/Electronic Arts/EA Desktop")
        for v in ["13.796.0.6309", "13.1000.0.1"] {
            let dir = root.appendingPathComponent("\(v)/EA Desktop")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent("EADesktop.exe"))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("EA Desktop?"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("VC"), withIntermediateDirectories: true)

        let store = LauncherStore(kind: .ea, paths: paths)
        #expect(store.launcherExecutable.path.hasSuffix("EA Desktop/13.1000.0.1/EA Desktop/EADesktop.exe"))
        #expect(store.isLauncherInstalled)
    }

    @Test func notInstalledWhenNoVersionFolderHasTheExe() {
        let (paths, home) = tempPaths()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!LauncherStore(kind: .ea, paths: paths).isLauncherInstalled)
    }

    @Test func monoOnlyUnblocksMscoreeWhenInstalled() throws {
        let (paths, home) = tempPaths()
        defer { try? FileManager.default.removeItem(at: home) }
        let bottle = Bottle(kind: .ea, paths: paths)
        var profile = LaunchProfile()
        profile.backend = .wined3d     // adds no DLL overrides of its own
        #expect(!bottle.hasMono)
        #expect(WineRunner.environment(bottle: bottle, profile: profile)["WINEDLLOVERRIDES"] == "mscoree,mshtml=;winemenubuilder.exe=d")
        try FileManager.default.createDirectory(at: bottle.driveC.appendingPathComponent("windows/mono/mono-2.0"), withIntermediateDirectories: true)
        #expect(bottle.hasMono)
        #expect(WineRunner.environment(bottle: bottle, profile: profile)["WINEDLLOVERRIDES"] == "mshtml=;winemenubuilder.exe=d")
    }

    @Test func monoPinMatchesWinesOwn() {
        #expect(WineMono.sha256.count == 64)
        #expect(WineMono.downloadURL.absoluteString == "https://dl.winehq.org/wine/wine-mono/10.4.1/wine-mono-10.4.1-x86.msi")
    }
}

@Suite struct BottleOnPlayTests {
    /// An engine whose `wine` builds a minimal prefix for `wineboot --init`, like the real one.
    private func engineWithFakeWine(in root: URL) throws -> Engine {
        let engine = try makeTestEngine(root, version: "1.0.0", backends: ["dxvk"], d3dMetal: false)
        try """
        #!/bin/sh
        [ "$1" = wineboot ] && mkdir -p "$WINEPREFIX/drive_c/windows"
        exit 0
        """.write(to: engine.wine, atomically: true, encoding: .utf8)
        return engine
    }

    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("macade-bp-\(UUID().uuidString)")
    }

    @Test func epicAndGogBuildTheirEnvironmentOnFirstPlay() async throws {
        let home = temp()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let engine = try engineWithFakeWine(in: home)
        for store in [StoreKind.epic, .gog] {
            #expect(!Bottle(kind: store.bottleKind, paths: paths).exists)
            let bottle = try await BottleManager(paths: paths).prepareForPlay(store, engine: engine)
            #expect(bottle?.exists == true)
            #expect(Bottle(kind: store.bottleKind, paths: paths).exists)
        }
    }

    @Test func epicIsRebuiltAfterAReset() async throws {
        let home = temp()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let engine = try engineWithFakeWine(in: home)
        let manager = BottleManager(paths: paths)
        try await manager.prepareForPlay(.epic, engine: engine)
        try FileManager.default.removeItem(at: Bottle(kind: .epic, paths: paths).url)   // what Reset does
        #expect(!Bottle(kind: .epic, paths: paths).exists)
        try await manager.prepareForPlay(.epic, engine: engine)
        #expect(Bottle(kind: .epic, paths: paths).exists)
    }

    @Test func anExistingEnvironmentIsLeftAlone() async throws {
        let home = temp()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let engine = try engineWithFakeWine(in: home)
        let marker = Bottle(kind: .epic, paths: paths).driveC.appendingPathComponent("windows/keep.txt")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: marker)
        try await BottleManager(paths: paths).prepareForPlay(.epic, engine: engine)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func launcherStoresKeepTheirOwnSetup() async throws {
        let home = temp()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let engine = try engineWithFakeWine(in: home)
        for store in [StoreKind.steam, .ubisoft, .ea] {
            let bottle = try await BottleManager(paths: paths).prepareForPlay(store, engine: engine)
            #expect(bottle == nil)
            #expect(!Bottle(kind: store.bottleKind, paths: paths).exists)
        }
    }
}
