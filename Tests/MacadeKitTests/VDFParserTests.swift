import Foundation
import Testing
@testable import MacadeKit

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct VDFParserTests {
    @Test func parsesLibraryFolders() throws {
        let root = try VDFParser.parse(try fixture("libraryfolders.vdf"))
        let folder = try #require(root.value(at: "libraryfolders", "0"))
        #expect(folder["path"]?.string == #"C:\Program Files (x86)\Steam"#)
        #expect(folder.value(at: "apps", "268910")?.string == "4044947883")
        #expect(folder["apps"]?.entries?.count == 2)
    }

    @Test func parsesAppManifest() throws {
        let root = try VDFParser.parse(try fixture("appmanifest_268910.acf"))
        let state = try #require(root["AppState"])
        #expect(state["appid"]?.string == "268910")
        #expect(state["name"]?.string == "Cuphead")
        #expect(state["StateFlags"]?.string == "4")
        #expect(state.value(at: "InstalledDepots", "268911", "size")?.string == "4044947883")
    }

    @Test func keyLookupIsCaseInsensitive() throws {
        let root = try VDFParser.parse(#""A" { "Key" "v" }"#)
        #expect(root.value(at: "a", "KEY")?.string == "v")
    }

    @Test func handlesEscapesCommentsAndBareTokens() throws {
        let text = """
        // comment
        "root" {
            "path" "C:\\\\Games\\\\x"   // trailing
            "quote" "say \\"hi\\"\\n"
            bare value
        }
        """
        let root = try VDFParser.parse(text)
        #expect(root.value(at: "root", "path")?.string == #"C:\Games\x"#)
        #expect(root.value(at: "root", "quote")?.string == "say \"hi\"\n")
        #expect(root.value(at: "root", "bare")?.string == "value")
    }

    @Test func keepsDuplicateKeysInOrder() throws {
        let root = try VDFParser.parse(#""r" { "k" "1" "k" "2" }"#)
        #expect(root["r"]?.entries?.map { $0.value.string } == ["1", "2"])
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: VDFError.self) { try VDFParser.parse(#""r" { "k" "v""#) }
        #expect(throws: VDFError.self) { try VDFParser.parse(#""r" }"#) }
        #expect(throws: VDFError.self) { try VDFParser.parse(#""r" { "k" "unterminated }"#) }
    }

    @Test func emptyDocumentIsEmptyObject() throws {
        #expect(try VDFParser.parse("") == .object([]))
    }
}
