import Foundation
import Testing
@testable import MacadeKit

@Suite struct EpicCloudSavesTests {
    let roots = SaveRoots(profile: URL(fileURLWithPath: "/b/drive_c/users/abdz"), install: URL(fileURLWithPath: "/g/AlanWake2"))

    @Test func resolvesAppDataToLocalAppData() {
        let url = EpicCloudSaves.resolve("{AppData}/Remedy/AlanWake2/{EpicID}/", roots: roots, epicID: "4d14")
        #expect(url?.path == "/b/drive_c/users/abdz/AppData/Local/Remedy/AlanWake2/4d14")
    }

    @Test func resolvesOtherRootsAndBackslashes() {
        #expect(EpicCloudSaves.resolve("{UserDir}\\My Games\\X", roots: roots, epicID: "e")?.path == "/b/drive_c/users/abdz/Documents/My Games/X")
        #expect(EpicCloudSaves.resolve("{usersavedgames}/X/{epicid}", roots: roots, epicID: "e")?.path == "/b/drive_c/users/abdz/Saved Games/X/e")
        #expect(EpicCloudSaves.resolve("{InstallDir}/Saves", roots: roots, epicID: "e")?.path == "/g/AlanWake2/Saves")
    }

    @Test func refusesUnknownOrUnsafePaths() {
        #expect(EpicCloudSaves.resolve("C:/Saves", roots: roots, epicID: "e") == nil)
        #expect(EpicCloudSaves.resolve("{Registry}/X", roots: roots, epicID: "e") == nil)
        #expect(EpicCloudSaves.resolve("{AppData}/../../X", roots: roots, epicID: "e") == nil)
        #expect(EpicCloudSaves.resolve("{AppData}/{Unknown}", roots: roots, epicID: "e") == nil)
        #expect(EpicCloudSaves.resolve("{InstallDir}/Saves", roots: SaveRoots(profile: roots.profile), epicID: "e") == nil)
    }

    @Test func readsLegendaryFiles() {
        let meta = #"{"app_name":"dc9d","metadata":{"customAttributes":{"CloudSaveFolder":{"type":"STRING","value":"{AppData}/Remedy/AlanWake2/{EpicID}/"}}}}"#
        #expect(EpicCloudSaves.cloudSaveFolder(metadataJSON: Data(meta.utf8)) == "{AppData}/Remedy/AlanWake2/{EpicID}/")
        #expect(EpicCloudSaves.cloudSaveFolder(metadataJSON: Data(#"{"metadata":{"customAttributes":{}}}"#.utf8)) == nil)
        #expect(EpicCloudSaves.accountID(userJSON: Data(#"{"account_id":"4d14","displayName":"x"}"#.utf8)) == "4d14")
        let installed = #"{"dc9d":{"app_name":"dc9d","save_path":null},"abc":{"app_name":"abc","save_path":"/s"}}"#
        #expect(EpicCloudSaves.hasSavePath(installedJSON: Data(installed.utf8), appName: "dc9d") == false)
        #expect(EpicCloudSaves.hasSavePath(installedJSON: Data(installed.utf8), appName: "abc") == true)
        #expect(EpicCloudSaves.hasSavePath(installedJSON: Data(installed.utf8), appName: "zzz") == nil)
    }
}
