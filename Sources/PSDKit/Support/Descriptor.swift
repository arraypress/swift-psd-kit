//
//  Descriptor.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  Photoshop's Action Descriptor: the key–value format inside type layers
//  ('TySh') and smart objects ('SoLd'). Every value type is parsed so the
//  structure can be walked, but each item also keeps the bytes it was read
//  from, and an unchanged item is written back as exactly those bytes —
//  descriptors carry undocumented types and key encodings (a four-byte key
//  written with a zero length, or the same key spelled out) that a
//  re-encoder would quietly normalise.
//

import Foundation

/// A parsed descriptor value.
indirect enum DescriptorValue {
    case descriptor(Descriptor)
    case list([DescriptorValue])
    case double(Double)
    case unitFloat(unit: String, value: Double)
    case text(String)
    case enumerated(type: String, value: String)
    case integer(Int32)
    case largeInteger(Int64)
    case bool(Bool)
    /// tdta, alis, Pth: length-prefixed bytes.
    case data(Data)
    /// 'UnFl': a unit and an array of doubles — a warp's mesh points.
    case doubles(unit: String, values: [Double])
    /// Anything only skipped over: references and classes.
    case opaque
}

/// One key and its value, with the bytes both were read from.
struct DescriptorItem {
    var keyRaw: Data
    var key: String
    var type: String
    var raw: Data
    var value: DescriptorValue
}

/// A descriptor: a name, a class and items.
struct Descriptor {
    var nameRaw: Data
    var classRaw: Data
    var items: [DescriptorItem]

    subscript(key: String) -> DescriptorValue? { items.first { $0.key == key }?.value }

    /// The descriptor as bytes: unchanged items as they were read.
    func encoded() -> Data {
        var out = ByteWriter()
        out.append(nameRaw)
        out.append(classRaw)
        out.u32(UInt32(items.count))
        for item in items {
            out.append(item.keyRaw)
            out.fourCC(item.type)
            out.append(item.raw)
        }
        return out.data
    }

    /// Replaces a TEXT item's value.
    mutating func setText(_ key: String, _ value: String) {
        guard let index = items.firstIndex(where: { $0.key == key }) else { return }
        items[index].raw = DescriptorCodec.encodeUnicode(value)
        items[index].value = .text(value)
    }

    /// Replaces a tdta item's bytes.
    mutating func setData(_ key: String, _ value: Data) {
        guard let index = items.firstIndex(where: { $0.key == key }) else { return }
        var out = ByteWriter()
        out.u32(UInt32(value.count)); out.append(value)
        items[index].raw = out.data
        items[index].value = .data(value)
    }
}

/// Reads descriptors.
enum DescriptorCodec {

    static func read(_ reader: inout ByteReader) throws -> Descriptor {
        let nameStart = reader.position
        let count = Int(try reader.u32())
        try reader.skip(count * 2)
        let nameRaw = reader.data.subdata(in: (reader.data.startIndex + nameStart)..<(reader.data.startIndex + reader.position))
        let classRaw = try keyRaw(&reader).raw
        let itemCount = Int(try reader.u32())
        var items: [DescriptorItem] = []
        for _ in 0..<itemCount {
            let key = try keyRaw(&reader)
            let type = try reader.fourCC()
            let start = reader.position
            let value = try readValue(type, &reader)
            let raw = reader.data.subdata(in: (reader.data.startIndex + start)..<(reader.data.startIndex + reader.position))
            items.append(DescriptorItem(keyRaw: key.raw, key: key.key, type: type, raw: raw, value: value))
        }
        return Descriptor(nameRaw: nameRaw, classRaw: classRaw, items: items)
    }

    /// A key: a length, then that many bytes — or four when the length is 0.
    static func keyRaw(_ reader: inout ByteReader) throws -> (raw: Data, key: String) {
        let start = reader.position
        let length = Int(try reader.u32())
        let bytes = try reader.bytes(length == 0 ? 4 : length)
        let raw = reader.data.subdata(in: (reader.data.startIndex + start)..<(reader.data.startIndex + reader.position))
        return (raw, String(decoding: bytes, as: UTF8.self))
    }

    static func unicode(_ reader: inout ByteReader) throws -> String {
        let count = Int(try reader.u32())
        let bytes = try reader.bytes(count * 2)
        var units: [UInt16] = []
        for index in stride(from: bytes.startIndex, to: bytes.endIndex, by: 2) {
            units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
        }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// A Photoshop unicode string: a count of UTF-16 units, the units, and a
    /// terminating zero — Photoshop writes the zero and counts it.
    static func encodeUnicode(_ value: String) -> Data {
        var out = ByteWriter()
        let units = Array(value.utf16) + [0]
        out.u32(UInt32(units.count))
        for unit in units { out.u16(unit) }
        return out.data
    }

    static func readValue(_ type: String, _ reader: inout ByteReader) throws -> DescriptorValue {
        switch type {
        case "Objc", "GlbO":
            return .descriptor(try read(&reader))
        case "ObAr":
            try reader.skip(4)
            return .descriptor(try read(&reader))
        case "VlLs":
            let count = Int(try reader.u32())
            var values: [DescriptorValue] = []
            for _ in 0..<count {
                let itemType = try reader.fourCC()
                values.append(try readValue(itemType, &reader))
            }
            return .list(values)
        case "obj ":
            let count = Int(try reader.u32())
            for _ in 0..<count {
                let itemType = try reader.fourCC()
                try skipReference(itemType, &reader)
            }
            return .opaque
        case "doub": return .double(try reader.double())
        case "UntF":
            let unit = try reader.fourCC()
            return .unitFloat(unit: unit, value: try reader.double())
        case "UnFl":
            let unit = try reader.fourCC()
            let count = Int(try reader.u32())
            return .doubles(unit: unit, values: try (0..<count).map { _ in try reader.double() })
        case "TEXT": return .text(try unicode(&reader))
        case "enum":
            let type = try keyRaw(&reader).key
            return .enumerated(type: type, value: try keyRaw(&reader).key)
        case "long": return .integer(try reader.i32())
        case "comp": return .largeInteger(try reader.i64())
        case "bool": return .bool(try reader.u8() != 0)
        case "type", "GlbC", "Clss":
            _ = try unicode(&reader); _ = try keyRaw(&reader)
            return .opaque
        case "alis", "tdta", "Pth ":
            return .data(try reader.block(lengthWidth: 4))
        default:
            throw PSDError.malformed("unknown descriptor type '\(type)'")
        }
    }

    static func skipReference(_ type: String, _ reader: inout ByteReader) throws {
        switch type {
        case "prop": _ = try unicode(&reader); _ = try keyRaw(&reader); _ = try keyRaw(&reader)
        case "Clss": _ = try unicode(&reader); _ = try keyRaw(&reader)
        case "Enmr": _ = try unicode(&reader); _ = try keyRaw(&reader); _ = try keyRaw(&reader); _ = try keyRaw(&reader)
        case "rele": _ = try unicode(&reader); _ = try keyRaw(&reader); try reader.skip(4)
        case "Idnt", "indx": try reader.skip(4)
        case "name": _ = try unicode(&reader); _ = try keyRaw(&reader); _ = try unicode(&reader)
        default: throw PSDError.malformed("unknown reference type '\(type)'")
        }
    }
}

extension DescriptorValue {
    var double: Double? {
        switch self {
        case .double(let value), .unitFloat(_, let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }
    var text: String? { if case .text(let value) = self { return value } else { return nil } }
    var descriptor: Descriptor? { if case .descriptor(let value) = self { return value } else { return nil } }
    var list: [DescriptorValue]? { if case .list(let value) = self { return value } else { return nil } }
    var data: Data? { if case .data(let value) = self { return value } else { return nil } }
    var doubles: [Double]? { if case .doubles(_, let values) = self { return values } else { return nil } }
}
