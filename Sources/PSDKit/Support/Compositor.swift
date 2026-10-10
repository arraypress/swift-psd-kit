//
//  Compositor.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  Flattening layers into one picture, for the viewers that never read
//  layers — Quick Look, ImageIO, a web preview — which show only the
//  merged image a PSD carries. Normal and the common separable blend
//  modes, opacity and fill, groups, clipping and user masks. NOT layer
//  effects, adjustment layers or smart filters: Photoshop renders those at
//  composite time and stores no pixels for them, so this reports where it
//  meets one rather than drawing a wrong picture.
//
//  It is trusted per file and per region, never in general: before an edit
//  rewrites part of the merged image, the same compositor runs on the
//  original layers and its result is compared with the merged image
//  Photoshop saved. See ``MergedImage/agreement(_:_:in:)``.
//

import Foundation

/// A straight-alpha RGBA picture as floats, 0–1, top row first.
struct Canvas {
    let width: Int, height: Int
    var pixels: [Float]

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        pixels = [Float](repeating: 0, count: width * height * 4)
    }
}

/// What the compositor could and could not draw.
struct CompositeNotes {
    /// Layer names whose effects, adjustments or blend modes were skipped.
    var unrendered: [String] = []
    /// The same, with the bounds each covers (left, top, right, bottom).
    var unrenderedBounds: [(String, [Int])] = []

    mutating func skip(_ note: String, _ record: LayerRecord?) {
        unrendered.append(note)
        if let record { unrenderedBounds.append((note, [Int(record.left), Int(record.top), Int(record.right), Int(record.bottom)])) }
        else { unrenderedBounds.append((note, [Int.min / 2, Int.min / 2, Int.max / 2, Int.max / 2])) }
    }

    /// The skipped layers that overlap a rectangle.
    func within(_ rect: (x0: Int, y0: Int, x1: Int, y1: Int)) -> [String] {
        unrenderedBounds.filter { _, b in b[0] < rect.x1 && b[2] > rect.x0 && b[1] < rect.y1 && b[3] > rect.y0 }.map(\.0)
    }
}

/// Flattens a file's layers.
enum Compositor {

    static let supportedBlends: Set<String> = ["norm", "pass", "mul ", "scrn", "dark", "lite", "lddg", "diff", "over"]
    static let adjustmentKeys: Set<String> = ["levl", "curv", "brit", "hue2", "hue ", "blnc", "blwh", "phfl", "mixr",
                                              "clrL", "nvrt", "post", "thrs", "grdm", "selc", "expA", "vibA"]

    /// The file's layers flattened over transparency.
    static func composite(_ file: PSDFile, notes: inout CompositeNotes) throws -> Canvas {
        var stack: [(canvas: Canvas, record: LayerRecord?)] = [(Canvas(width: file.width, height: file.height), nil)]
        var hiddenDepth = 0
        var clipBase: [Float]? = nil

        for (index, record) in file.layers.records.enumerated() {
            let divider = record.block("lsct").flatMap { try? sectionType($0.data) } ?? 0
            if divider == 3 {
                // The bottom of a group: open an isolated canvas for it.
                stack.append((Canvas(width: file.width, height: file.height), nil))
                continue
            }
            if divider == 1 || divider == 2 {
                // The top of a group: its record carries the group's look.
                guard stack.count > 1 else { continue }
                let group = stack.removeLast().canvas
                if !record.isHidden {
                    let mode = record.block("lsct").flatMap { blendFromDivider($0.data) } ?? record.blendMode
                    blend(group, into: &stack[stack.count - 1].canvas,
                          mode: mode == "pass" ? "norm" : mode, opacity: Float(record.opacity) / 255, notes: &notes,
                          name: name(of: record))
                }
                clipBase = nil
                continue
            }
            _ = hiddenDepth
            guard !record.isHidden else { continue }
            if record.blocks.contains(where: { adjustmentKeys.contains($0.key) }) {
                notes.skip("\(name(of: record)) (adjustment)", nil)
                continue
            }
            if hasEnabledEffects(record) { notes.skip("\(name(of: record)) (effects)", record) }

            var layer = try pixels(of: record, index: index, in: file)
            if record.clipping == 1, let base = clipBase {
                for pixel in 0..<(layer.width * layer.height) { layer.pixels[pixel * 4 + 3] *= base[pixel] }
            } else {
                clipBase = stride(from: 3, to: layer.pixels.count, by: 4).map { layer.pixels[$0] }
            }
            let fill = record.block("iOpa").flatMap { $0.data.first }.map { Float($0) / 255 } ?? 1
            blend(layer, into: &stack[stack.count - 1].canvas, mode: record.blendMode,
                  opacity: Float(record.opacity) / 255 * fill, notes: &notes, name: name(of: record))
        }
        while stack.count > 1 {
            let group = stack.removeLast().canvas
            blend(group, into: &stack[stack.count - 1].canvas, mode: "norm", opacity: 1, notes: &notes, name: "group")
        }
        return stack[0].canvas
    }

    /// A layer's pixels placed on a document-sized canvas.
    static func pixels(of record: LayerRecord, index: Int, in file: PSDFile) throws -> Canvas {
        var canvas = Canvas(width: file.width, height: file.height)
        guard record.width > 0, record.height > 0 else { return canvas }
        let channels = file.layers.channelData[index]
        var planes: [Int16: [UInt8]] = [:]
        for (position, id) in record.channelIDs.enumerated() where id >= -1 && id <= 2 {
            planes[id] = try ChannelCodec.decode(channels[position], width: record.width, height: record.height,
                                                 depth: file.depth, version: file.version)
        }
        let gray = file.colorMode == 1
        for y in 0..<record.height {
            let docY = Int(record.top) + y
            guard docY >= 0, docY < file.height else { continue }
            for x in 0..<record.width {
                let docX = Int(record.left) + x
                guard docX >= 0, docX < file.width else { continue }
                let source = y * record.width + x
                let target = (docY * file.width + docX) * 4
                let red = Float(planes[0]?[source] ?? 0) / 255
                canvas.pixels[target] = red
                canvas.pixels[target + 1] = gray ? red : Float(planes[1]?[source] ?? 0) / 255
                canvas.pixels[target + 2] = gray ? red : Float(planes[2]?[source] ?? 0) / 255
                canvas.pixels[target + 3] = planes[-1].map { Float($0[source]) / 255 } ?? 1
            }
        }
        try applyMask(record, index: index, file: file, to: &canvas)
        return canvas
    }

    /// Multiplies a layer's alpha by its user mask, where it has one.
    static func applyMask(_ record: LayerRecord, index: Int, file: PSDFile, to canvas: inout Canvas) throws {
        guard let position = record.channelIDs.firstIndex(of: -2), record.maskData.count >= 18 else { return }
        var reader = ByteReader(record.maskData)
        let top = Int(try reader.i32()), left = Int(try reader.i32()), bottom = Int(try reader.i32()), right = Int(try reader.i32())
        let defaultColor = Float(try reader.u8()) / 255
        let flags = try reader.u8()
        guard flags & 0x02 == 0 else { return }   // mask disabled
        let width = right - left, height = bottom - top
        let plane = width > 0 && height > 0
            ? try ChannelCodec.decode(file.layers.channelData[index][position], width: width, height: height,
                                      depth: file.depth, version: file.version) : []
        for docY in 0..<file.height {
            for docX in 0..<file.width {
                let x = docX - left, y = docY - top
                let value = (x >= 0 && y >= 0 && x < width && y < height) ? Float(plane[y * width + x]) / 255 : defaultColor
                canvas.pixels[(docY * file.width + docX) * 4 + 3] *= value
            }
        }
    }

    /// Source over destination with a blend mode, straight alpha.
    static func blend(_ source: Canvas, into target: inout Canvas, mode: String, opacity: Float,
                      notes: inout CompositeNotes, name: String) {
        if !supportedBlends.contains(mode) { notes.skip("\(name) (blend \(mode))", nil) }
        for pixel in 0..<(source.width * source.height) {
            let s = pixel * 4
            let alpha = source.pixels[s + 3] * opacity
            guard alpha > 0 else { continue }
            let backAlpha = target.pixels[s + 3]
            let outAlpha = alpha + backAlpha * (1 - alpha)
            for channel in 0..<3 {
                let cs = source.pixels[s + channel], cb = target.pixels[s + channel]
                let mixed = backAlpha > 0 ? blendChannel(mode, cb, cs) : cs
                // The blended colour where both exist, the source alone where the backdrop is empty.
                let color = (1 - backAlpha) * cs + backAlpha * mixed
                target.pixels[s + channel] = outAlpha > 0
                    ? (alpha * color + backAlpha * (1 - alpha) * cb) / outAlpha : 0
            }
            target.pixels[s + 3] = outAlpha
        }
    }

    static func blendChannel(_ mode: String, _ b: Float, _ s: Float) -> Float {
        switch mode {
        case "mul ": return b * s
        case "scrn": return b + s - b * s
        case "dark": return min(b, s)
        case "lite": return max(b, s)
        case "lddg": return min(1, b + s)
        case "diff": return abs(b - s)
        case "over": return b <= 0.5 ? 2 * b * s : 1 - 2 * (1 - b) * (1 - s)
        default: return s
        }
    }

    static func sectionType(_ data: Data) throws -> Int {
        var reader = ByteReader(data)
        return Int(try reader.u32())
    }

    static func blendFromDivider(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        return String(decoding: data[(data.startIndex + 8)..<(data.startIndex + 12)], as: UTF8.self)
    }

    /// Whether a layer has an effect switched on — drawn by Photoshop at
    /// composite time and stored nowhere as pixels.
    static func hasEnabledEffects(_ record: LayerRecord) -> Bool {
        guard let block = record.block("lfx2") ?? record.block("lmfx") else { return false }
        var reader = ByteReader(block.data)
        guard (try? reader.skip(8)) != nil, let descriptor = try? DescriptorCodec.read(&reader) else { return true }
        if case .bool(false) = descriptor["masterFXSwitch"] ?? .bool(true) { return false }
        return descriptor.items.contains { item in
            guard let effect = item.value.descriptor else {
                return item.value.list?.contains { $0.descriptor.map(isEnabled) ?? false } ?? false
            }
            return isEnabled(effect)
        }
    }

    static func isEnabled(_ effect: Descriptor) -> Bool {
        if case .bool(let enabled) = effect["enab"] ?? .bool(false) { return enabled }
        return false
    }

    static func name(of record: LayerRecord) -> String {
        if let unicode = record.block("luni") {
            var reader = ByteReader(unicode.data)
            if let name = try? DescriptorCodec.unicode(&reader) { return name }
        }
        let length = Int(record.nameRaw.first ?? 0)
        return String(decoding: record.nameRaw.dropFirst().prefix(length), as: UTF8.self)
    }
}

/// The merged image a file carries: decoded, compared and rewritten.
enum MergedImage {

    /// The stored merged image as straight RGBA, with whatever transparency
    /// it carries (opaque when it has none).
    static func decode(_ file: PSDFile) throws -> Canvas {
        var canvas = Canvas(width: file.width, height: file.height)
        var reader = ByteReader(file.imageData)
        let compression = try reader.u16()
        let planeCount = file.channels
        let rowBytes = file.width * max(1, file.depth / 8)
        var planes: [[UInt8]] = []
        switch compression {
        case 0:
            for _ in 0..<planeCount {
                let raw = ChannelData(compression: 0, data: try reader.bytes(min(rowBytes * file.height, reader.remaining)))
                planes.append(try ChannelCodec.decode(raw, width: file.width, height: file.height, depth: file.depth, version: file.version))
            }
        case 1:
            let width = file.version == 2 ? 4 : 2
            let counts = try (0..<(planeCount * file.height)).map { _ in Int(try reader.uint(width)) }
            for plane in 0..<planeCount {
                var out: [UInt8] = []
                for row in 0..<file.height {
                    out += ChannelCodec.unpackBits([UInt8](try reader.bytes(counts[plane * file.height + row])), expected: rowBytes)
                }
                planes.append(file.depth == 8 ? out : try ChannelCodec.decode(ChannelData(compression: 0, data: Data(out)),
                                                                             width: file.width, height: file.height,
                                                                             depth: file.depth, version: file.version))
            }
        default:
            throw PSDError.unsupportedForEditing("its merged image uses compression \(compression)")
        }
        let gray = file.colorMode == 1
        let colorPlanes = gray ? 1 : 3
        for pixel in 0..<(file.width * file.height) {
            let red = Float(planes[0][pixel]) / 255
            canvas.pixels[pixel * 4] = red
            canvas.pixels[pixel * 4 + 1] = gray ? red : Float(planes[1][pixel]) / 255
            canvas.pixels[pixel * 4 + 2] = gray ? red : Float(planes[2][pixel]) / 255
            canvas.pixels[pixel * 4 + 3] = planes.count > colorPlanes ? Float(planes[colorPlanes][pixel]) / 255 : 1
        }
        return canvas
    }

    /// How closely two canvases agree inside a rectangle, as 0–255 colour
    /// differences over opaque-ish pixels: the mean, and the 99th percentile.
    static func agreement(_ a: Canvas, _ b: Canvas, in rect: (x0: Int, y0: Int, x1: Int, y1: Int)) -> (mean: Double, p99: Double) {
        var diffs: [Double] = []
        for y in max(0, rect.y0)..<min(a.height, rect.y1) {
            for x in max(0, rect.x0)..<min(a.width, rect.x1) {
                let p = (y * a.width + x) * 4
                // Compare as colour over white, which is how both show on screen.
                var worst = 0.0
                for channel in 0..<3 {
                    let ca = Double(a.pixels[p + channel] * a.pixels[p + 3] + (1 - a.pixels[p + 3]))
                    let cb = Double(b.pixels[p + channel] * b.pixels[p + 3] + (1 - b.pixels[p + 3]))
                    worst = max(worst, abs(ca - cb) * 255)
                }
                diffs.append(worst)
            }
        }
        guard !diffs.isEmpty else { return (0, 0) }
        diffs.sort()
        return (diffs.reduce(0, +) / Double(diffs.count), diffs[min(diffs.count - 1, Int(Double(diffs.count) * 0.99))])
    }

    /// The merged image with a rectangle replaced from a canvas, as PackBits,
    /// keeping every plane the file had beyond the colour ones untouched.
    static func encode(_ file: PSDFile, replacing rect: (x0: Int, y0: Int, x1: Int, y1: Int), from canvas: Canvas) throws -> Data {
        guard file.depth == 8 else { throw PSDError.unsupportedForEditing("its depth is \(file.depth)-bit") }
        var reader = ByteReader(file.imageData)
        let compression = try reader.u16()
        let planeCount = file.channels
        var planes: [[UInt8]] = []
        if compression == 1 {
            let width = file.version == 2 ? 4 : 2
            let counts = try (0..<(planeCount * file.height)).map { _ in Int(try reader.uint(width)) }
            for plane in 0..<planeCount {
                var out: [UInt8] = []
                for row in 0..<file.height { out += ChannelCodec.unpackBits([UInt8](try reader.bytes(counts[plane * file.height + row])), expected: file.width) }
                planes.append(out)
            }
        } else if compression == 0 {
            for _ in 0..<planeCount { planes.append([UInt8](try reader.bytes(file.width * file.height))) }
        } else {
            throw PSDError.unsupportedForEditing("its merged image uses compression \(compression)")
        }
        let colorPlanes = file.colorMode == 1 ? 1 : 3
        for y in max(0, rect.y0)..<min(file.height, rect.y1) {
            for x in max(0, rect.x0)..<min(file.width, rect.x1) {
                let pixel = y * file.width + x
                let alpha = canvas.pixels[pixel * 4 + 3]
                let hasAlphaPlane = planeCount > colorPlanes
                for channel in 0..<colorPlanes {
                    var value = canvas.pixels[pixel * 4 + channel]
                    // With no transparency plane the merged image is matted on white.
                    if !hasAlphaPlane { value = value * alpha + (1 - alpha) }
                    planes[channel][pixel] = UInt8(max(0, min(255, (value * 255).rounded())))
                }
                if planeCount > colorPlanes { planes[colorPlanes][pixel] = UInt8(max(0, min(255, (alpha * 255).rounded()))) }
            }
        }
        var out = ByteWriter()
        out.u16(1)
        var rows: [[UInt8]] = []
        for plane in planes { for row in 0..<file.height { rows.append(ChannelCodec.packBits(plane[(row * file.width)..<((row + 1) * file.width)])) } }
        rows.forEach { out.uint(UInt64($0.count), file.version == 2 ? 4 : 2) }
        rows.forEach { out.append(Data($0)) }
        return out.data
    }
}
