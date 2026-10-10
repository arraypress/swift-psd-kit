//
//  ByteReader.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  Big-endian reading and writing over Data. Every length in a PSD is
//  big-endian, and half of them change width in a PSB, so the width is a
//  parameter rather than a guess.
//

import Foundation

/// Reads big-endian values from bytes, never past their end.
struct ByteReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = data.startIndex + offset
    }

    var position: Int { offset - data.startIndex }
    var remaining: Int { data.endIndex - offset }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else {
            throw PSDError.malformed("wanted \(count) bytes at \(position), \(remaining) left")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func skip(_ count: Int) throws { _ = try bytes(count) }

    mutating func uint(_ width: Int) throws -> UInt64 {
        let raw = try bytes(width)
        return raw.reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func u8() throws -> UInt8 { UInt8(try uint(1)) }
    mutating func u16() throws -> UInt16 { UInt16(try uint(2)) }
    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    mutating func u32() throws -> UInt32 { UInt32(try uint(4)) }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try uint(8)) }
    mutating func double() throws -> Double { Double(bitPattern: try uint(8)) }
    mutating func fourCC() throws -> String { String(decoding: try bytes(4), as: UTF8.self) }

    /// A length-prefixed block: the length's width is 4 or 8 bytes.
    mutating func block(lengthWidth: Int) throws -> Data {
        try bytes(Int(try uint(lengthWidth)))
    }
}

/// Builds big-endian bytes.
struct ByteWriter {
    private(set) var data = Data()

    mutating func append(_ bytes: Data) { data.append(bytes) }
    mutating func uint(_ value: UInt64, _ width: Int) {
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { uint(UInt64(value), 2) }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) { uint(UInt64(value), 4) }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func double(_ value: Double) { uint(value.bitPattern, 8) }
    mutating func fourCC(_ code: String) { data.append(contentsOf: Array(code.utf8.prefix(4))) }
    mutating func zeros(_ count: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: max(0, count))) }
}

/// Padding needed to bring a length to a multiple.
func padding(_ length: Int, to multiple: Int) -> Int {
    multiple <= 1 ? 0 : (multiple - length % multiple) % multiple
}
