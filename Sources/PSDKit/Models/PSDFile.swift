//
//  PSDFile.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  A PSD or PSB as the bytes lay it out — the shape the reader fills and
//  the writer empties. Everything this library does not edit is kept as the
//  bytes it arrived as, so a file opened and written with no change comes
//  back byte for byte, and an edit touches only the layer it names.
//

import Foundation

/// The sections of a Photoshop file.
struct PSDFile {
    /// The 26-byte header, verbatim.
    var header: Data
    var version: Int          // 1 PSD, 2 PSB
    var channels: Int
    var height: Int
    var width: Int
    var depth: Int
    var colorMode: Int
    /// Colour-mode data (palette, duotone), without its length.
    var colorModeData: Data
    /// Image resources, without their length.
    var imageResources: Data
    /// The layer and mask information.
    var layers: LayerSection
    /// The merged composite: compression and planes, verbatim.
    var imageData: Data

    /// How wide most section lengths are: 8 bytes in a PSB.
    var lengthWidth: Int { version == 2 ? 8 : 4 }
}

/// Layers, the global mask, and the document-wide tagged blocks.
struct LayerSection {
    var layerCount: Int16
    var records: [LayerRecord]
    /// One entry per record: its channels' compression and data, in record order.
    var channelData: [[ChannelData]]
    /// The multiple the layer-info length was rounded to.
    var layerInfoAlignment: Int
    /// Whether the file had a layer-info section at all.
    var hasLayerInfo: Bool
    /// The global layer mask, without its length — nil when the file has no
    /// such field at all, as old files end their section after the layers.
    var globalMask: Data?
    /// Document-wide tagged blocks — 'Txt2', 'lnk2', 'Patt' and the rest.
    var blocks: [TaggedBlock]
    /// Bytes after the last block that belong to no block (padding).
    var trailing: Data
}

/// One layer record, its variable parts kept raw.
struct LayerRecord {
    var top: Int32, left: Int32, bottom: Int32, right: Int32
    /// Channel ids: 0 red, 1 green, 2 blue, -1 transparency, -2 user mask.
    var channelIDs: [Int16]
    var blendSignature: Data
    var blendMode: String
    var opacity: UInt8
    var clipping: UInt8
    var flags: UInt8
    var filler: UInt8
    var maskData: Data
    var blendingRanges: Data
    /// The Pascal name with its padding, verbatim.
    var nameRaw: Data
    var blocks: [TaggedBlock]

    var bounds: (top: Int, left: Int, bottom: Int, right: Int) {
        (Int(top), Int(left), Int(bottom), Int(right))
    }
    var width: Int { max(0, Int(right) - Int(left)) }
    var height: Int { max(0, Int(bottom) - Int(top)) }
    var isHidden: Bool { flags & 0x02 != 0 }

    func block(_ key: String) -> TaggedBlock? { blocks.first { $0.key == key } }
}

/// A key, a length and some bytes.
struct TaggedBlock {
    var signature: String    // "8BIM" or "8B64"
    var key: String
    var data: Data
    /// The width of the length field: 4, or 8 for some keys in a PSB.
    var lengthWidth: Int
}

/// One channel's compressed pixels.
struct ChannelData {
    /// 0 raw, 1 RLE (PackBits), 2 ZIP, 3 ZIP with prediction.
    var compression: UInt16
    var data: Data
}
