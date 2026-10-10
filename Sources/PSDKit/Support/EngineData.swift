//
//  EngineData.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  The text engine's own data inside a type layer: PostScript-like
//  dictionaries (`<< /Key value >>`), arrays, numbers, names and strings
//  that are UTF-16 behind a FE FF mark with `( ) \` escaped. Parsed into a
//  tree that remembers where every value sits in the bytes, so a change is
//  a splice — the rest stays exactly as Photoshop wrote it, whitespace and
//  all, rather than being re-serialised into something only nearly the same.
//

import Foundation

/// One value in engine data, and the bytes it spans.
struct EngineNode {
    enum Kind {
        case dictionary([(String, EngineNode)])
        case array([EngineNode])
        case string(String)
        case number(Double)
        case name(String)
        case bool(Bool)
    }
    var kind: Kind
    var range: Range<Int>

    subscript(key: String) -> EngineNode? {
        guard case .dictionary(let entries) = kind else { return nil }
        return entries.first { $0.0 == key }?.1
    }

    /// Follows a path of dictionary keys and array indices ("FontSet", "0", "Name").
    func at(_ path: String...) -> EngineNode? { at(path) }
    func at(_ path: [String]) -> EngineNode? {
        var node: EngineNode? = self
        for step in path {
            if let index = Int(step), case .array(let items) = node?.kind {
                node = index < items.count ? items[index] : nil
            } else {
                node = node?[step]
            }
        }
        return node
    }

    var number: Double? {
        switch kind {
        case .number(let value): return value
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }
    var bool: Bool? { if case .bool(let value) = kind { return value }; return number.map { $0 != 0 } }
    var string: String? { if case .string(let value) = kind { return value } else { return nil } }
    var items: [EngineNode] { if case .array(let value) = kind { return value } else { return [] } }
}

/// Parses engine data and splices changes into it.
enum EngineData {

    static func parse(_ data: Data) throws -> EngineNode {
        let bytes = [UInt8](data)
        var index = 0
        skipSpace(bytes, &index)
        // The root is a dictionary without being told so on some files.
        return try value(bytes, &index)
    }

    private static func skipSpace(_ b: [UInt8], _ i: inout Int) {
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x00 { i += 1 }
    }

    private static func value(_ b: [UInt8], _ i: inout Int) throws -> EngineNode {
        skipSpace(b, &i)
        guard i < b.count else { throw PSDError.malformed("engine data ends early") }
        let start = i
        switch b[i] {
        case UInt8(ascii: "<") where i + 1 < b.count && b[i + 1] == UInt8(ascii: "<"):
            i += 2
            var entries: [(String, EngineNode)] = []
            while true {
                skipSpace(b, &i)
                guard i < b.count else { throw PSDError.malformed("an engine dictionary never closes") }
                if b[i] == UInt8(ascii: ">"), i + 1 < b.count, b[i + 1] == UInt8(ascii: ">") { i += 2; break }
                guard b[i] == UInt8(ascii: "/") else { throw PSDError.malformed("an engine key does not start with /") }
                let key = name(b, &i)
                entries.append((key, try value(b, &i)))
            }
            return EngineNode(kind: .dictionary(entries), range: start..<i)
        case UInt8(ascii: "["):
            i += 1
            var items: [EngineNode] = []
            while true {
                skipSpace(b, &i)
                guard i < b.count else { throw PSDError.malformed("an engine array never closes") }
                if b[i] == UInt8(ascii: "]") { i += 1; break }
                items.append(try value(b, &i))
            }
            return EngineNode(kind: .array(items), range: start..<i)
        case UInt8(ascii: "("):
            i += 1
            var raw: [UInt8] = []
            while i < b.count, b[i] != UInt8(ascii: ")") {
                if b[i] == UInt8(ascii: "\\"), i + 1 < b.count { i += 1 }
                raw.append(b[i]); i += 1
            }
            i += 1
            return EngineNode(kind: .string(decode(raw)), range: start..<i)
        case UInt8(ascii: "/"):
            return EngineNode(kind: .name(name(b, &i)), range: start..<i)
        default:
            let tokenStart = i
            while i < b.count, !(b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D
                                 || b[i] == UInt8(ascii: "]") || b[i] == UInt8(ascii: ">") || b[i] == UInt8(ascii: "/")) { i += 1 }
            let token = String(decoding: b[tokenStart..<i], as: UTF8.self)
            if token == "true" || token == "false" { return EngineNode(kind: .bool(token == "true"), range: start..<i) }
            guard let number = Double(token) else { throw PSDError.malformed("engine token '\(token)'") }
            return EngineNode(kind: .number(number), range: start..<i)
        }
    }

    private static func name(_ b: [UInt8], _ i: inout Int) -> String {
        i += 1
        let start = i
        while i < b.count, !(b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D
                             || b[i] == UInt8(ascii: "[") || b[i] == UInt8(ascii: "(") || b[i] == UInt8(ascii: "<")
                             || b[i] == UInt8(ascii: "/") || b[i] == UInt8(ascii: "]") || b[i] == UInt8(ascii: ">")) { i += 1 }
        return String(decoding: b[start..<i], as: UTF8.self)
    }

    /// A string's bytes: UTF-16BE after FE FF, otherwise Latin-1.
    static func decode(_ raw: [UInt8]) -> String {
        guard raw.count >= 2, raw[0] == 0xFE, raw[1] == 0xFF else { return String(decoding: raw, as: UTF8.self) }
        var units: [UInt16] = []
        var index = 2
        while index + 1 < raw.count { units.append(UInt16(raw[index]) << 8 | UInt16(raw[index + 1])); index += 2 }
        return String(decoding: units, as: UTF16.self)
    }

    /// A string as engine data writes it: `(`, FE FF, UTF-16BE with `( ) \`
    /// escaped — they turn up as bytes inside two-byte characters — `)`.
    static func encodeString(_ value: String) -> Data {
        var out: [UInt8] = [UInt8(ascii: "("), 0xFE, 0xFF]
        for unit in value.utf16 {
            for byte in [UInt8(unit >> 8), UInt8(unit & 0xFF)] {
                if byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") || byte == UInt8(ascii: "\\") {
                    out.append(UInt8(ascii: "\\"))
                }
                out.append(byte)
            }
        }
        out.append(UInt8(ascii: ")"))
        return Data(out)
    }

    /// Applies replacements (ranges of the original bytes) all at once.
    static func splice(_ data: Data, _ edits: [(Range<Int>, Data)]) -> Data {
        var bytes = [UInt8](data)
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            bytes.replaceSubrange(range, with: [UInt8](replacement))
        }
        return Data(bytes)
    }
}
