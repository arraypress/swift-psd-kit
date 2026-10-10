//
//  TypeToolBlock.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  A type layer's 'TySh' block: where the text sits (a 2×3 transform), the
//  text descriptor — the plain string under 'Txt ' and the text engine's
//  own PostScript-like data under 'EngineData' — the warp, and the text's
//  bounds. Laid out as psd-tools and Adobe's spec agree: the bounds are four
//  32-bit integers, not doubles.
//

import Foundation

/// A parsed 'TySh' block.
struct TypeToolBlock {
    var version: UInt16
    /// xx, xy, yx, yy, tx, ty — text space to document space.
    var transform: [Double]
    var textVersion: UInt16
    var descriptorVersion: UInt32
    var text: Descriptor
    /// The warp version, descriptor version and descriptor, verbatim.
    var warpRaw: Data
    var bounds: [Int32]
    /// Anything after the bounds, verbatim.
    var trailing: Data

    init(_ data: Data) throws {
        var reader = ByteReader(data)
        version = try reader.u16()
        transform = try (0..<6).map { _ in try reader.double() }
        textVersion = try reader.u16()
        descriptorVersion = try reader.u32()
        text = try DescriptorCodec.read(&reader)
        let warpStart = reader.position
        _ = try reader.u16()
        _ = try reader.u32()
        _ = try DescriptorCodec.read(&reader)
        warpRaw = data.subdata(in: (data.startIndex + warpStart)..<(data.startIndex + reader.position))
        bounds = try (0..<4).map { _ in try reader.i32() }
        trailing = try reader.bytes(reader.remaining)
    }

    func encoded() -> Data {
        var out = ByteWriter()
        out.u16(version)
        transform.forEach { out.double($0) }
        out.u16(textVersion)
        out.u32(descriptorVersion)
        out.append(text.encoded())
        out.append(warpRaw)
        bounds.forEach { out.i32($0) }
        out.append(trailing)
        return out.data
    }

    /// The plain text, with Photoshop's carriage returns as they are.
    var string: String { text["Txt "]?.text ?? "" }
    var engineData: Data { text["EngineData"]?.data ?? Data() }
}

/// A smart object's 'SoLd' block: which embedded file it shows and where.
struct SmartObjectBlock {
    var identifier: String     // 'soLD'
    var version: UInt32
    var descriptorVersion: UInt32
    var descriptor: Descriptor
    var trailing: Data

    init(_ data: Data) throws {
        var reader = ByteReader(data)
        identifier = try reader.fourCC()
        version = try reader.u32()
        descriptorVersion = try reader.u32()
        descriptor = try DescriptorCodec.read(&reader)
        trailing = try reader.bytes(reader.remaining)
    }

    func encoded() -> Data {
        var out = ByteWriter()
        out.fourCC(identifier); out.u32(version); out.u32(descriptorVersion)
        out.append(descriptor.encoded()); out.append(trailing)
        return out.data
    }

    /// The embedded file's id, matching a linked-file record's.
    var fileID: String? { descriptor["Idnt"]?.text }
    /// The placed content's corners in the document, TL TR BR BL as x,y.
    var corners: [Double] {
        (descriptor["nonAffineTransform"]?.list ?? descriptor["Trnf"]?.list ?? []).compactMap(\.double)
    }
    /// The placed content's size in its own pixels.
    var contentSize: (width: Double, height: Double)? {
        guard let size = descriptor["Sz  "]?.descriptor,
              let width = size["Wdth"]?.double, let height = size["Hght"]?.double else { return nil }
        return (width, height)
    }
    /// Whether a warp bends the content, which this library cannot redraw.
    ///
    /// Photoshop writes `warpCustom` with an even mesh for content that was
    /// only placed and scaled, so a custom warp counts as a warp only when
    /// its mesh points are not the plain lattice over its bounds.
    var isWarped: Bool {
        guard let warp = descriptor["warp"]?.descriptor,
              case .enumerated(_, let style) = warp["warpStyle"] ?? .opaque else { return false }
        if style == "warpNone" { return false }
        guard style == "warpCustom",
              let bounds = warp["bounds"]?.descriptor,
              let top = bounds["Top "]?.double, let left = bounds["Left"]?.double,
              let bottom = bounds["Btom"]?.double, let right = bounds["Rght"]?.double,
              let mesh = warp["customEnvelopeWarp"]?.descriptor?["meshPoints"]?.descriptor,
              let xs = mesh["Hrzn"]?.doubles, let ys = mesh["Vrtc"]?.doubles,
              xs.count == 16, ys.count == 16 else { return true }
        for row in 0..<4 {
            for column in 0..<4 {
                let x = left + (right - left) * Double(column) / 3
                let y = top + (bottom - top) * Double(row) / 3
                if abs(xs[row * 4 + column] - x) > 0.01 || abs(ys[row * 4 + column] - y) > 0.01 { return true }
            }
        }
        return false
    }
}

/// One file embedded in, or linked from, a document ('lnk2' / 'lnkD' / 'lnk3').
struct LinkedFileRecord {
    var kind: String           // liFD embedded, liFE external, liFA alias
    var version: UInt32
    var uuid: String
    var filename: String
    var fileType: String
    var creator: String
    /// The open-file flag and descriptor, verbatim.
    var openRaw: Data
    var payload: Data
    /// Everything after the payload, verbatim.
    var tail: Data
    /// The record's original bytes, for kinds this library does not rewrite.
    var original: Data
    var edited = false

    init(_ data: Data) throws {
        original = data
        var reader = ByteReader(data)
        kind = try reader.fourCC()
        version = try reader.u32()
        let uuidLength = Int(try reader.u8())
        uuid = String(decoding: try reader.bytes(uuidLength), as: UTF8.self)
        filename = try DescriptorCodec.unicode(&reader)
        fileType = try reader.fourCC()
        creator = try reader.fourCC()
        let size = Int(try reader.uint(8))
        let openStart = reader.position
        let open = try reader.u8()
        if open != 0 { _ = try reader.u32(); _ = try DescriptorCodec.read(&reader) }
        openRaw = data.subdata(in: (data.startIndex + openStart)..<(data.startIndex + reader.position))
        payload = kind == "liFD" ? try reader.bytes(size) : Data()
        tail = try reader.bytes(reader.remaining)
    }

    func encoded() -> Data {
        guard edited else { return original }
        var out = ByteWriter()
        out.fourCC(kind); out.u32(version)
        let uuidBytes = Data(uuid.utf8)
        out.u8(UInt8(uuidBytes.count)); out.append(uuidBytes)
        out.append(DescriptorCodec.encodeUnicode(filename))
        out.fourCC(fileType); out.fourCC(creator)
        out.uint(UInt64(payload.count), 8)
        out.append(openRaw)
        out.append(payload)
        out.append(tail)
        return out.data
    }

    static func records(in block: Data) throws -> [LinkedFileRecord] {
        var reader = ByteReader(block)
        var records: [LinkedFileRecord] = []
        while reader.remaining >= 8 {
            let length = Int(try reader.uint(8))
            records.append(try LinkedFileRecord(try reader.bytes(length)))
            try reader.skip(min(padding(length, to: 4), reader.remaining))
        }
        return records
    }

    static func encode(_ records: [LinkedFileRecord]) -> Data {
        var out = ByteWriter()
        for record in records {
            let bytes = record.encoded()
            out.uint(UInt64(bytes.count), 8)
            out.append(bytes)
            out.zeros(padding(bytes.count, to: 4))
        }
        return out.data
    }
}
