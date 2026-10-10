//
//  ChannelCodec.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  Pixels in and out of a PSD's channel encodings: raw, PackBits run-length
//  (with a table of row byte counts first — two bytes a row in a PSD, four
//  in a PSB), ZIP, and ZIP with per-row prediction. Everything this library
//  writes is PackBits, which is what Photoshop itself writes for 8-bit.
//

import Compression
import Foundation

/// Decodes and encodes channel planes.
enum ChannelCodec {

    /// One channel's pixels as 8-bit samples, row by row.
    ///
    /// - Parameters:
    ///   - channel: The channel's compression and bytes.
    ///   - width: Pixels per row.
    ///   - height: Rows.
    ///   - depth: Bits per sample; 16 and 32 are reduced to 8.
    ///   - version: 1 PSD, 2 PSB — the width of the RLE row counts.
    static func decode(_ channel: ChannelData, width: Int, height: Int, depth: Int, version: Int) throws -> [UInt8] {
        let bytesPerSample = max(1, depth / 8)
        let rowBytes = width * bytesPerSample
        let count = rowBytes * height
        guard count > 0 else { return [] }
        var raw: [UInt8]
        switch channel.compression {
        case 0:
            raw = [UInt8](channel.data.prefix(count))
        case 1:
            raw = try unpackRLE(channel.data, rows: height, rowBytes: rowBytes, countWidth: version == 2 ? 4 : 2)
        case 2, 3:
            raw = try inflate(channel.data, expected: count)
            if channel.compression == 3 { unpredict(&raw, width: width, height: height, bytesPerSample: bytesPerSample) }
        default:
            throw PSDError.malformed("channel compression \(channel.compression)")
        }
        if raw.count < count { raw += [UInt8](repeating: 0, count: count - raw.count) }
        guard bytesPerSample > 1 else { return raw }
        // 16-bit: the high byte; 32-bit float: clamp 0–1.
        return (0..<(width * height)).map { index in
            let offset = index * bytesPerSample
            if bytesPerSample == 2 { return raw[offset] }
            let bits = UInt32(raw[offset]) << 24 | UInt32(raw[offset + 1]) << 16 | UInt32(raw[offset + 2]) << 8 | UInt32(raw[offset + 3])
            return UInt8(max(0, min(1, Float(bitPattern: bits))) * 255)
        }
    }

    /// PackBits rows after a table of their byte counts.
    static func unpackRLE(_ data: Data, rows: Int, rowBytes: Int, countWidth: Int) throws -> [UInt8] {
        var reader = ByteReader(data)
        let counts = try (0..<rows).map { _ in Int(try reader.uint(countWidth)) }
        var out: [UInt8] = []
        out.reserveCapacity(rows * rowBytes)
        for count in counts {
            let row = [UInt8](try reader.bytes(count))
            out += unpackBits(row, expected: rowBytes)
        }
        return out
    }

    static func unpackBits(_ row: [UInt8], expected: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(expected)
        var index = 0
        while index < row.count, out.count < expected {
            let header = Int(Int8(bitPattern: row[index])); index += 1
            if header >= 0 {
                let end = min(row.count, index + header + 1)
                out += row[index..<end]; index = end
            } else if header != -128, index < row.count {
                out += [UInt8](repeating: row[index], count: 1 - header); index += 1
            }
        }
        if out.count < expected { out += [UInt8](repeating: 0, count: expected - out.count) }
        return Array(out.prefix(expected))
    }

    static func packBits(_ row: ArraySlice<UInt8>) -> [UInt8] {
        let bytes = Array(row)
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            var run = 1
            while index + run < bytes.count, bytes[index + run] == bytes[index], run < 128 { run += 1 }
            if run >= 2 {
                out.append(UInt8(bitPattern: Int8(1 - run))); out.append(bytes[index]); index += run
                continue
            }
            var literal = 1
            while index + literal < bytes.count, literal < 128 {
                if index + literal + 1 < bytes.count, bytes[index + literal] == bytes[index + literal + 1] { break }
                literal += 1
            }
            out.append(UInt8(literal - 1)); out += bytes[index..<(index + literal)]; index += literal
        }
        return out
    }

    /// One plane as PackBits, its row-count table first.
    static func encodeRLE(_ plane: [UInt8], width: Int, height: Int, version: Int) -> Data {
        let rows = (0..<height).map { packBits(plane[($0 * width)..<(($0 + 1) * width)]) }
        var out = ByteWriter()
        rows.forEach { out.uint(UInt64($0.count), version == 2 ? 4 : 2) }
        rows.forEach { out.append(Data($0)) }
        return out.data
    }

    static func inflate(_ data: Data, expected: Int) throws -> [UInt8] {
        // zlib: skip the two-byte header; Compression's ZLIB is raw deflate.
        let body = [UInt8](data.dropFirst(2))
        var out = [UInt8](repeating: 0, count: max(expected, 1))
        let written = compression_decode_buffer(&out, out.count, body, body.count, nil, COMPRESSION_ZLIB)
        guard written > 0 else { throw PSDError.malformed("a ZIP channel would not inflate") }
        return Array(out.prefix(written))
    }

    static func unpredict(_ raw: inout [UInt8], width: Int, height: Int, bytesPerSample: Int) {
        guard bytesPerSample == 1 else { return }
        for row in 0..<height {
            for column in 1..<width {
                let index = row * width + column
                raw[index] = raw[index] &+ raw[index - 1]
            }
        }
    }
}
