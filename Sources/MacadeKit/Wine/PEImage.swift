import Foundation

/// The parts of a Windows executable Macade cares about: its CPU and the DLLs it imports.
/// Only headers and the import tables are read, so multi-gigabyte game executables are cheap.
public struct PEImage: Sendable, Equatable {
    public enum Machine: Sendable, Equatable {
        case i386, x86_64, arm64, other(UInt16)

        init(_ raw: UInt16) {
            switch raw {
            case 0x014c: self = .i386
            case 0x8664: self = .x86_64
            case 0xaa64: self = .arm64
            default: self = .other(raw)
            }
        }
    }

    public let machine: Machine
    /// Lowercased DLL names from the import and delay-load import tables.
    public let imports: Set<String>

    public var is64Bit: Bool { machine == .x86_64 || machine == .arm64 }
    public func imports(_ dll: String) -> Bool { imports.contains(dll.lowercased()) }

    public init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        self.init(reader: { offset, count in
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
            return try? handle.read(upToCount: count)
        })
    }

    public init?(data: Data) {
        self.init(reader: { offset, count in
            guard offset >= 0, offset < data.count else { return nil }
            let start = data.startIndex + offset
            return data[start..<min(start + count, data.endIndex)]
        })
    }

    private init?(reader read: (Int, Int) -> Data?) {
        func u16(_ d: Data, _ o: Int) -> Int? { o + 2 <= d.count ? Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 : nil }
        func u32(_ d: Data, _ o: Int) -> Int? {
            guard let lo = u16(d, o), let hi = u16(d, o + 2) else { return nil }
            return lo | hi << 16
        }

        guard let dos = read(0, 64), dos.count == 64, dos.prefix(2) == Data("MZ".utf8),
              let peOffset = u32(dos, 0x3c), peOffset < 16 * 1024 * 1024,
              let headers = read(peOffset, 24 + 240), headers.prefix(4) == Data([0x50, 0x45, 0, 0]),
              let machine = u16(headers, 4), let sectionCount = u16(headers, 6),
              let optionalSize = u16(headers, 20), let magic = u16(headers, 24)
        else { return nil }

        let opt = 24                                           // optional header, relative to `headers`
        let is64 = magic == 0x20b
        guard is64 || magic == 0x10b else { return nil }
        let dirCountOffset = opt + (is64 ? 108 : 92)
        let dirsOffset = opt + (is64 ? 112 : 96)
        let imageBase: Int
        if is64 {
            guard let lo = u32(headers, opt + 24), let hi = u32(headers, opt + 28) else { return nil }
            imageBase = lo | hi << 32
        } else {
            guard let base = u32(headers, opt + 28) else { return nil }
            imageBase = base
        }
        let dirCount = u32(headers, dirCountOffset) ?? 0
        func directory(_ index: Int) -> Int? {
            guard index < dirCount, let rva = u32(headers, dirsOffset + index * 8), rva != 0 else { return nil }
            return rva
        }

        // Section table, for mapping RVAs to file offsets.
        guard sectionCount > 0, sectionCount < 200,
              let table = read(peOffset + 24 + optionalSize, sectionCount * 40), table.count == sectionCount * 40
        else { return nil }
        struct Section { let va, size, raw: Int }
        let sections: [Section] = (0..<sectionCount).compactMap { i in
            let b = i * 40
            guard let vsize = u32(table, b + 8), let va = u32(table, b + 12),
                  let rawSize = u32(table, b + 16), let raw = u32(table, b + 20) else { return nil }
            return Section(va: va, size: max(vsize, rawSize), raw: raw)
        }
        func offset(ofRVA rva: Int) -> Int? {
            sections.first { rva >= $0.va && rva < $0.va + $0.size }.map { rva - $0.va + $0.raw }
        }
        func string(atRVA rva: Int) -> String? {
            guard let o = offset(ofRVA: rva), let bytes = read(o, 256),
                  let end = bytes.firstIndex(of: 0), end > bytes.startIndex else { return nil }
            return String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self).lowercased()
        }

        var names = Set<String>()
        // Regular imports: 20-byte descriptors, name RVA at +12, ended by a zeroed entry.
        if let rva = directory(1), let start = offset(ofRVA: rva) {
            for i in 0..<1024 {
                guard let d = read(start + i * 20, 20), d.count == 20, let name = u32(d, 12), name != 0 else { break }
                if let s = string(atRVA: name) { names.insert(s) }
            }
        }
        // Delay-load imports: 32-byte descriptors, name at +4 (a VA instead of an RVA in old-style entries).
        if let rva = directory(13), let start = offset(ofRVA: rva) {
            for i in 0..<1024 {
                guard let d = read(start + i * 32, 32), d.count == 32, let attrs = u32(d, 0),
                      let name = u32(d, 4), name != 0 else { break }
                if let s = string(atRVA: attrs & 1 == 1 ? name : name - imageBase) { names.insert(s) }
            }
        }

        self.machine = Machine(UInt16(machine))
        self.imports = names
    }
}
