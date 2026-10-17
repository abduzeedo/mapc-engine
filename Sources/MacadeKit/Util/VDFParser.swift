import Foundation

/// A node in Valve's text KeyValues format (`libraryfolders.vdf`, `appmanifest_*.acf`).
public indirect enum VDFValue: Equatable, Sendable {
    case string(String)
    case object([(key: String, value: VDFValue)])

    public static func == (lhs: VDFValue, rhs: VDFValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    public var string: String? { if case let .string(s) = self { return s } else { return nil } }
    public var entries: [(key: String, value: VDFValue)]? {
        if case let .object(o) = self { return o } else { return nil }
    }

    /// First child with this key (case-insensitive, as Steam is).
    public subscript(key: String) -> VDFValue? {
        entries?.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    public func value(at path: String...) -> VDFValue? {
        var node: VDFValue? = self
        for key in path { node = node?[key] }
        return node
    }
}

public enum VDFError: Error, Equatable {
    case unexpectedEnd
    case unexpectedToken(String, offset: Int)
    case unterminatedString(offset: Int)
}

/// Parser for the text KeyValues format: quoted strings, nested `{}`, `//` comments, escapes.
public enum VDFParser {
    /// Parses a document. The top level is an object of its entries.
    public static func parse(_ text: String) throws -> VDFValue {
        var lexer = Lexer(Array(text.unicodeScalars))
        let entries = try parseEntries(&lexer, nested: false)
        return .object(entries)
    }

    private static func parseEntries(_ lx: inout Lexer, nested: Bool) throws -> [(key: String, value: VDFValue)] {
        var out: [(key: String, value: VDFValue)] = []
        while true {
            guard let token = try lx.next() else {
                if nested { throw VDFError.unexpectedEnd }
                return out
            }
            switch token {
            case .close:
                if nested { return out }
                throw VDFError.unexpectedToken("}", offset: lx.position)
            case .open:
                throw VDFError.unexpectedToken("{", offset: lx.position)
            case let .string(key):
                guard let next = try lx.next() else { throw VDFError.unexpectedEnd }
                switch next {
                case let .string(value): out.append((key, .string(value)))
                case .open: out.append((key, .object(try parseEntries(&lx, nested: true))))
                case .close: throw VDFError.unexpectedToken("}", offset: lx.position)
                }
            }
        }
    }

    private enum Token { case string(String), open, close }

    private struct Lexer {
        let s: [Unicode.Scalar]
        var i = 0
        var position: Int { i }
        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func next() throws -> Token? {
            skipTrivia()
            guard i < s.count else { return nil }
            switch s[i] {
            case "{": i += 1; return .open
            case "}": i += 1; return .close
            case "\"": return .string(try quoted())
            default: return .string(bare())
            }
        }

        mutating func skipTrivia() {
            while i < s.count {
                if s[i].properties.isWhitespace || s[i] == "\u{FEFF}" { i += 1 }
                else if s[i] == "/", i + 1 < s.count, s[i + 1] == "/" {
                    while i < s.count, s[i] != "\n" { i += 1 }
                } else { break }
            }
        }

        mutating func quoted() throws -> String {
            let start = i
            i += 1
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]
                if c == "\"" { i += 1; return String(out) }
                if c == "\\", i + 1 < s.count {
                    i += 1
                    switch s[i] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\\": out.append("\\")
                    case "\"": out.append("\"")
                    default: out.append("\\"); out.append(s[i])
                    }
                } else { out.append(c) }
                i += 1
            }
            throw VDFError.unterminatedString(offset: start)
        }

        mutating func bare() -> String {
            var out = String.UnicodeScalarView()
            while i < s.count, !s[i].properties.isWhitespace, s[i] != "{", s[i] != "}", s[i] != "\"" {
                out.append(s[i]); i += 1
            }
            return String(out)
        }
    }
}
