//
//  PSDWriter.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  A new layered Photoshop file from pictures: one pixel layer per picture,
//  groups as Photoshop's folders, each with its name (as Unicode, `luni`),
//  opacity, blend key and visibility, and the flattened picture as the
//  merged image Quick Look and the web show. 8-bit RGB, PackBits.
//
//  Layers are given bottom first — the order they are drawn — which is the
//  order a PSD stores its records. A group is written as Photoshop writes
//  one: a closing marker record (`lsct` type 3) below its children and the
//  group's own record (`lsct` type 1, carrying its blend key) above them.
//  Text arrives as pixels: an editable type layer needs Photoshop's text
//  engine data, which this writer does not make.
//

import CoreGraphics
import Foundation

/// One layer to write.
public struct PSDWriteLayer: Sendable {

    public enum Content: Sendable {
        /// A picture the size of the document (RGBA; transparent where the layer is not).
        case pixels(CGImage)
        /// A folder of layers, bottom first.
        case group([PSDWriteLayer])
    }

    public var name: String
    public var content: Content
    /// `0…1`.
    public var opacity: Double
    /// Photoshop's four-letter blend key (`norm`, `mul `, `scrn`…; `pass` for a group).
    public var blendKey: String
    public var visible: Bool

    public init(name: String, content: Content, opacity: Double = 1, blendKey: String = "norm", visible: Bool = true) {
        self.name = name
        self.content = content
        self.opacity = opacity
        self.blendKey = blendKey
        self.visible = visible
    }
}

/// Writes a layered PSD.
public enum PSDWriter {

    /// The blend keys Photoshop knows.
    public static let blendKeys: Set<String> = ["pass", "norm", "diss", "dark", "mul ", "idiv", "lbrn", "dkCl", "lite", "scrn",
                                                "div ", "lddg", "lgCl", "over", "sLit", "hLit", "vLit", "lLit", "pLit",
                                                "hMix", "diff", "smud", "fsub", "fdiv", "hue ", "sat ", "colr", "lum "]

    /// The file's bytes.
    ///
    /// - Parameters:
    ///   - width: The document's width in pixels.
    ///   - height: Its height.
    ///   - layers: The layers, bottom first.
    ///   - composite: The flattened picture, the document's size.
    ///   - dpi: The resolution to record (72 when `nil`).
    public static func data(width: Int, height: Int, layers: [PSDWriteLayer], composite: CGImage,
                            dpi: Double? = nil) throws -> Data {
        guard width > 0, height > 0, width <= 30000, height <= 30000 else {
            throw PSDError.malformed("a PSD is 1…30000 pixels a side; this is \(width)×\(height)")
        }
        var records: [LayerRecord] = []
        var channels: [[ChannelData]] = []
        try append(layers, width: width, height: height, records: &records, channels: &channels)

        var header = ByteWriter()
        header.fourCC("8BPS"); header.u16(1); header.zeros(6)
        let merged = try planes(of: composite, width: width, height: height)
        let opaque = merged[3].allSatisfy { $0 == 255 }
        header.u16(opaque ? 3 : 4); header.u32(UInt32(height)); header.u32(UInt32(width))
        header.u16(8); header.u16(3)

        let file = PSDFile(header: header.data, version: 1, channels: opaque ? 3 : 4, height: height, width: width,
                           depth: 8, colorMode: 3, colorModeData: Data(), imageResources: resources(dpi: dpi ?? 72),
                           layers: LayerSection(layerCount: Int16(records.count), records: records, channelData: channels,
                                                layerInfoAlignment: 2, hasLayerInfo: true, globalMask: Data(), blocks: [],
                                                trailing: Data()),
                           imageData: mergedData(opaque ? Array(merged.prefix(3)) : merged, width: width, height: height))
        return PSDCodec.write(file)
    }

    // MARK: Records

    static func append(_ layers: [PSDWriteLayer], width: Int, height: Int, records: inout [LayerRecord],
                       channels: inout [[ChannelData]]) throws {
        for layer in layers {
            guard blendKeys.contains(layer.blendKey) else { throw PSDError.malformed("\"\(layer.blendKey)\" is not a Photoshop blend key") }
            switch layer.content {
            case .pixels(let image):
                let (record, data) = try pixelRecord(layer, image: image, width: width, height: height)
                records.append(record)
                channels.append(data)
            case .group(let children):
                records.append(record(name: "</Layer group>", bounds: (0, 0, 0, 0), channelIDs: [-1, 0, 1, 2], blendKey: "norm",
                                      opacity: 1, visible: true, extra: [block("lsct", sectionDivider(3, blend: nil))]))
                channels.append(Array(repeating: ChannelData(compression: 0, data: Data()), count: 4))
                try append(children, width: width, height: height, records: &records, channels: &channels)
                // The group's own record: its look, and the blend that composites it.
                records.append(record(name: layer.name, bounds: (0, 0, 0, 0), channelIDs: [-1, 0, 1, 2],
                                      blendKey: layer.blendKey == "pass" ? "norm" : layer.blendKey,
                                      opacity: layer.opacity, visible: layer.visible,
                                      extra: [block("lsct", sectionDivider(1, blend: layer.blendKey))]))
                channels.append(Array(repeating: ChannelData(compression: 0, data: Data()), count: 4))
            }
        }
    }

    /// A pixel layer, cropped to where it has any alpha.
    static func pixelRecord(_ layer: PSDWriteLayer, image: CGImage, width: Int, height: Int) throws -> (LayerRecord, [ChannelData]) {
        let planes = try planes(of: image, width: width, height: height)
        var top = height, left = width, bottom = 0, right = 0
        for y in 0..<height {
            for x in 0..<width where planes[3][y * width + x] > 0 {
                top = min(top, y); bottom = max(bottom, y + 1); left = min(left, x); right = max(right, x + 1)
            }
        }
        if bottom <= top { top = 0; left = 0; bottom = 0; right = 0 }
        let w = right - left, h = bottom - top
        var data: [ChannelData] = []
        for plane in [planes[3], planes[0], planes[1], planes[2]] {
            guard w > 0, h > 0 else { data.append(ChannelData(compression: 0, data: Data())); continue }
            var cropped = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { cropped[y * w + x] = plane[(top + y) * width + left + x] } }
            data.append(ChannelData(compression: 1, data: ChannelCodec.encodeRLE(cropped, width: w, height: h, version: 1)))
        }
        let record = record(name: layer.name, bounds: (top, left, bottom, right), channelIDs: [-1, 0, 1, 2],
                            blendKey: layer.blendKey, opacity: layer.opacity, visible: layer.visible, extra: [])
        return (record, data)
    }

    static func record(name: String, bounds: (Int, Int, Int, Int), channelIDs: [Int16], blendKey: String, opacity: Double,
                       visible: Bool, extra: [TaggedBlock]) -> LayerRecord {
        LayerRecord(top: Int32(bounds.0), left: Int32(bounds.1), bottom: Int32(bounds.2), right: Int32(bounds.3),
                    channelIDs: channelIDs, blendSignature: Data("8BIM".utf8), blendMode: blendKey,
                    opacity: UInt8((min(1, max(0, opacity)) * 255).rounded()), clipping: 0,
                    flags: visible ? 0x08 : 0x0A, filler: 0, maskData: Data(), blendingRanges: Data(),
                    nameRaw: pascalName(name), blocks: [block("luni", unicodeName(name))] + extra)
    }

    static func block(_ key: String, _ data: Data) -> TaggedBlock {
        TaggedBlock(signature: "8BIM", key: key, data: data, lengthWidth: 4)
    }

    /// The name as a Pascal string in Mac Roman (ASCII kept, others `?`), padded to four.
    static func pascalName(_ name: String) -> Data {
        let bytes = Array(name.unicodeScalars.prefix(255).map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") })
        var data = Data([UInt8(bytes.count)] + bytes)
        data.append(contentsOf: [UInt8](repeating: 0, count: padding(data.count, to: 4)))
        return data
    }

    /// The name as Photoshop's Unicode string: a count, then UTF-16 big-endian.
    static func unicodeName(_ name: String) -> Data {
        let units = Array(name.utf16)
        var out = ByteWriter()
        out.u32(UInt32(units.count))
        for unit in units { out.u16(unit) }
        return out.data
    }

    /// A section divider: 1 an open folder, 3 the folder's closing marker.
    static func sectionDivider(_ type: UInt32, blend: String?) -> Data {
        var out = ByteWriter()
        out.u32(type)
        if let blend {
            out.fourCC("8BIM")
            out.fourCC(blend)
        }
        return out.data
    }

    // MARK: Pixels

    /// The picture as four straight-colour planes (R, G, B, A), the document's size.
    static func planes(of image: CGImage, width: Int, height: Int) throws -> [[UInt8]] {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PSDError.malformed("could not read a \(image.width)×\(image.height) picture")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: width * height), count: 4)
        for i in 0..<(width * height) {
            let a = buffer[i * 4 + 3]
            planes[3][i] = a
            guard a > 0 else { continue }
            for c in 0..<3 {
                planes[c][i] = a == 255 ? buffer[i * 4 + c]
                    : UInt8(min(255, (Double(buffer[i * 4 + c]) * 255 / Double(a)).rounded()))
            }
        }
        return planes
    }

    /// The merged image: PackBits, every plane's row counts first, then every plane's rows.
    static func mergedData(_ planes: [[UInt8]], width: Int, height: Int) -> Data {
        var counts = ByteWriter(), rows = ByteWriter()
        for plane in planes {
            for y in 0..<height {
                let packed = ChannelCodec.packBits(plane[(y * width)..<((y + 1) * width)])
                counts.u16(UInt16(packed.count))
                rows.append(Data(packed))
            }
        }
        var out = ByteWriter()
        out.u16(1)
        out.append(counts.data)
        out.append(rows.data)
        return out.data
    }

    /// Image resources: the resolution (1005), pixels per inch both ways.
    static func resources(dpi: Double) -> Data {
        var info = ByteWriter()
        let fixed = UInt32((dpi * 65536).rounded())
        info.u32(fixed); info.u16(1); info.u16(1)      // horizontal, per inch, shown in inches
        info.u32(fixed); info.u16(1); info.u16(1)      // vertical
        var out = ByteWriter()
        out.fourCC("8BIM"); out.u16(1005); out.u16(0)   // empty Pascal name, padded
        out.u32(UInt32(info.data.count)); out.append(info.data)
        return out.data
    }
}
