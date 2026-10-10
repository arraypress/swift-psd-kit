//
//  PSDCodec.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  Bytes to PSDFile and back. Adobe's published layout, read with the
//  rules psd-tools and Photoshop agree on: section lengths are 4 bytes in a
//  PSD and 8 in a PSB; tagged blocks inside a layer record carry their own
//  even-padded length, while the document-wide ones are padded to four
//  after it; a handful of keys take an 8-byte length in a PSB.
//
//  The round trip is the first thing tested: every sample file comes back
//  byte for byte, which is what lets an edit promise it touched nothing else.
//

import Foundation

/// Reads and writes the PSD and PSB layout.
enum PSDCodec {

    /// Keys whose length is 8 bytes in a PSB.
    static let bigKeys: Set<String> = [
        "LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk",
        "lnk2", "lnk3", "lnkE", "FEid", "FXid", "PxSD", "pths", "extd", "cinf", "artd",
    ]

    // MARK: - Reading

    static func read(_ data: Data) throws -> PSDFile {
        var reader = ByteReader(data)
        guard data.count >= 26, try reader.fourCC() == "8BPS" else {
            throw PSDError.notPSD("it does not start with 8BPS")
        }
        let version = Int(try reader.u16())
        guard version == 1 || version == 2 else { throw PSDError.notPSD("version \(version)") }
        try reader.skip(6)
        let channels = Int(try reader.u16())
        let height = Int(try reader.u32())
        let width = Int(try reader.u32())
        let depth = Int(try reader.u16())
        let colorMode = Int(try reader.u16())
        let header = data.subdata(in: data.startIndex..<(data.startIndex + 26))
        let lengthWidth = version == 2 ? 8 : 4

        let colorModeData = try reader.block(lengthWidth: 4)
        let imageResources = try reader.block(lengthWidth: 4)
        let layerBytes = try reader.block(lengthWidth: lengthWidth)
        let layers = try readLayerSection(layerBytes, version: version)
        let imageData = try reader.bytes(reader.remaining)

        return PSDFile(header: header, version: version, channels: channels, height: height, width: width,
                       depth: depth, colorMode: colorMode, colorModeData: colorModeData,
                       imageResources: imageResources, layers: layers, imageData: imageData)
    }

    static func readLayerSection(_ data: Data, version: Int) throws -> LayerSection {
        let lengthWidth = version == 2 ? 8 : 4
        var section = LayerSection(layerCount: 0, records: [], channelData: [], layerInfoAlignment: 2,
                                   hasLayerInfo: false, globalMask: nil, blocks: [], trailing: Data())
        guard !data.isEmpty else { return section }
        var reader = ByteReader(data)

        let infoLength = Int(try reader.uint(lengthWidth))
        let info = try reader.bytes(infoLength)
        section.hasLayerInfo = true
        section.layerInfoAlignment = infoLength % 4 == 0 ? 4 : 2
        if infoLength > 0 {
            var layer = ByteReader(info)
            section.layerCount = try layer.i16()
            let count = Int(abs(Int(section.layerCount)))
            var lengths: [[UInt64]] = []
            for _ in 0..<count {
                let (record, channelLengths) = try readRecord(&layer, version: version)
                section.records.append(record)
                lengths.append(channelLengths)
            }
            for channelLengths in lengths {
                var channels: [ChannelData] = []
                for length in channelLengths {
                    guard length >= 2 else {
                        channels.append(ChannelData(compression: 0, data: try layer.bytes(Int(length))))
                        continue
                    }
                    let compression = try layer.u16()
                    channels.append(ChannelData(compression: compression, data: try layer.bytes(Int(length) - 2)))
                }
                section.channelData.append(channels)
            }
            // Whatever is left is the info section's own padding.
        }

        guard reader.remaining >= 4 else { section.trailing = try reader.bytes(reader.remaining); return section }
        section.globalMask = try reader.block(lengthWidth: 4)

        while reader.remaining >= 12 {
            let start = reader.position
            let signature = try reader.fourCC()
            guard signature == "8BIM" || signature == "8B64" else {
                reader = ByteReader(data, offset: start)
                break
            }
            let key = try reader.fourCC()
            let width = (version == 2 && bigKeys.contains(key)) ? 8 : 4
            let length = Int(try reader.uint(width))
            let body = try reader.bytes(length)
            try reader.skip(min(padding(length, to: 4), reader.remaining))
            section.blocks.append(TaggedBlock(signature: signature, key: key, data: body, lengthWidth: width))
        }
        section.trailing = try reader.bytes(reader.remaining)
        return section
    }

    static func readRecord(_ reader: inout ByteReader, version: Int) throws -> (LayerRecord, [UInt64]) {
        let top = try reader.i32(), left = try reader.i32(), bottom = try reader.i32(), right = try reader.i32()
        let channelCount = Int(try reader.u16())
        var ids: [Int16] = [], lengths: [UInt64] = []
        for _ in 0..<channelCount {
            ids.append(try reader.i16())
            lengths.append(try reader.uint(version == 2 ? 8 : 4))
        }
        let blendSignature = try reader.bytes(4)
        let blendMode = try reader.fourCC()
        let opacity = try reader.u8(), clipping = try reader.u8(), flags = try reader.u8(), filler = try reader.u8()
        let extra = try reader.block(lengthWidth: 4)

        var inner = ByteReader(extra)
        let maskData = try inner.block(lengthWidth: 4)
        let blendingRanges = try inner.block(lengthWidth: 4)
        let nameStart = inner.position
        let nameLength = Int(try inner.u8())
        try inner.skip(nameLength + padding(nameLength + 1, to: 4))
        let nameRaw = extra.subdata(in: (extra.startIndex + nameStart)..<(extra.startIndex + inner.position))

        var blocks: [TaggedBlock] = []
        while inner.remaining >= 12 {
            let signature = try inner.fourCC()
            guard signature == "8BIM" || signature == "8B64" else {
                throw PSDError.malformed("a layer's tagged block has signature \(signature)")
            }
            let key = try inner.fourCC()
            let width = (version == 2 && bigKeys.contains(key)) ? 8 : 4
            let body = try inner.block(lengthWidth: width)
            blocks.append(TaggedBlock(signature: signature, key: key, data: body, lengthWidth: width))
        }
        guard inner.remaining == 0 else {
            throw PSDError.malformed("\(inner.remaining) stray bytes after a layer's blocks")
        }
        let record = LayerRecord(top: top, left: left, bottom: bottom, right: right, channelIDs: ids,
                                 blendSignature: blendSignature, blendMode: blendMode, opacity: opacity,
                                 clipping: clipping, flags: flags, filler: filler, maskData: maskData,
                                 blendingRanges: blendingRanges, nameRaw: nameRaw, blocks: blocks)
        return (record, lengths)
    }

    // MARK: - Writing

    static func write(_ file: PSDFile) -> Data {
        var out = ByteWriter()
        out.append(file.header)
        out.u32(UInt32(file.colorModeData.count)); out.append(file.colorModeData)
        out.u32(UInt32(file.imageResources.count)); out.append(file.imageResources)
        let layers = writeLayerSection(file.layers, version: file.version)
        out.uint(UInt64(layers.count), file.lengthWidth)
        out.append(layers)
        out.append(file.imageData)
        return out.data
    }

    static func writeLayerSection(_ section: LayerSection, version: Int) -> Data {
        guard section.hasLayerInfo else { return Data() }
        let lengthWidth = version == 2 ? 8 : 4
        var info = ByteWriter()
        if !section.records.isEmpty || section.layerCount != 0 {
            info.i16(section.layerCount)
            for (record, channels) in zip(section.records, section.channelData) {
                writeRecord(record, channels: channels, version: version, into: &info)
            }
            for channels in section.channelData {
                for channel in channels {
                    if channel.data.isEmpty && channel.compression == 0 { info.u16(0); continue }
                    info.u16(channel.compression)
                    info.append(channel.data)
                }
            }
            info.zeros(padding(info.data.count, to: section.layerInfoAlignment))
        }
        var out = ByteWriter()
        out.uint(UInt64(info.data.count), lengthWidth)
        out.append(info.data)
        if let mask = section.globalMask { out.u32(UInt32(mask.count)); out.append(mask) }
        for block in section.blocks {
            out.fourCC(block.signature); out.fourCC(block.key)
            out.uint(UInt64(block.data.count), block.lengthWidth)
            out.append(block.data)
            out.zeros(padding(block.data.count, to: 4))
        }
        out.append(section.trailing)
        return out.data
    }

    static func writeRecord(_ record: LayerRecord, channels: [ChannelData], version: Int, into out: inout ByteWriter) {
        out.i32(record.top); out.i32(record.left); out.i32(record.bottom); out.i32(record.right)
        out.u16(UInt16(record.channelIDs.count))
        for (id, channel) in zip(record.channelIDs, channels) {
            out.i16(id)
            out.uint(UInt64(channel.data.count + 2), version == 2 ? 8 : 4)
        }
        out.append(record.blendSignature); out.fourCC(record.blendMode)
        out.u8(record.opacity); out.u8(record.clipping); out.u8(record.flags); out.u8(record.filler)
        var extra = ByteWriter()
        extra.u32(UInt32(record.maskData.count)); extra.append(record.maskData)
        extra.u32(UInt32(record.blendingRanges.count)); extra.append(record.blendingRanges)
        extra.append(record.nameRaw)
        for block in record.blocks {
            extra.fourCC(block.signature); extra.fourCC(block.key)
            extra.uint(UInt64(block.data.count), block.lengthWidth)
            extra.append(block.data)
        }
        out.u32(UInt32(extra.data.count)); out.append(extra.data)
    }
}
