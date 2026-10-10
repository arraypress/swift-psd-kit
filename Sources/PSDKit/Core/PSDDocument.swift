//
//  PSDDocument.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  The front door: open a Photoshop file, list its layers, change what a
//  type layer says or what a smart object shows, and write it back — with
//  everything not named left byte for byte as it was.
//
//  Three kinds of reader see a PSD, and an edit has to satisfy each:
//
//  - Photoshop reads the layer's own data. The text and the embedded file
//    are changed there exactly, and for text the document-wide engine data
//    ('Txt2') is dropped so Photoshop offers to redraw text layers on open,
//    which is what ag-psd's `invalidateTextLayers` does.
//  - Anything reading layers' pixels — psd-tools, Photopea, this library —
//    sees the layer redrawn: Core Text for text, the stored placement for a
//    picture. Measured against Photoshop's own pixels; see the README.
//  - Quick Look, ImageIO and the web read only the merged image. It is
//    rewritten inside the changed rectangle, and only where this library's
//    compositor reproduced the saved merged image there before the change;
//    otherwise it is left alone and the report says why.
//

import CoreGraphics
import Foundation
import ImageIO

/// A Photoshop document, open for reading and editing.
///
/// ```swift
/// var poster = try PSDDocument(contentsOf: template)
/// poster.layers.map(\.name)                       // ["Background", "Title", "Photo"]
/// let report = try poster.setText("Summer Sale", layer: "Title")
/// report.compositeUpdated                          // true when Quick Look will show it
/// try poster.replaceContents(of: "Photo", with: picture)
/// try poster.write(to: output)                     // re-read and checked before it is kept
/// ```
public struct PSDDocument: @unchecked Sendable {

    var file: PSDFile
    private let original: PSDFile
    /// Record indices this document has changed.
    private(set) var editedRecords: Set<Int> = []
    private var editedLinkedFiles = false

    public init(contentsOf url: URL) throws {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw PSDError.notPSD("\(url.lastPathComponent) could not be read")
        }
        try self.init(data: data)
    }

    public init(data: Data) throws {
        file = try PSDCodec.read(data)
        original = file
    }

    public var width: Int { file.width }
    public var height: Int { file.height }
    public var depth: Int { file.depth }
    /// "psd" or "psb".
    public var format: String { file.version == 2 ? "psb" : "psd" }
    public var colorMode: String {
        [0: "bitmap", 1: "grayscale", 2: "indexed", 3: "rgb", 4: "cmyk", 7: "multichannel", 8: "duotone", 9: "lab"][file.colorMode] ?? "unknown"
    }
    /// Whether text and pictures can be changed: 8-bit RGB.
    public var isEditable: Bool { file.depth == 8 && file.colorMode == 3 }

    // MARK: - Layers

    /// Every layer, top of the stack first — the order Photoshop's panel
    /// shows — each with the groups it sits in. A group's closing marker
    /// (an empty record at its bottom) is not listed.
    public var layers: [PSDLayer] {
        // Records run bottom to top and a group's name is on its TOP record,
        // so membership is worked out walking down from the top.
        var stack: [String] = []
        var result: [PSDLayer] = []
        for (index, record) in file.layers.records.enumerated().reversed() {
            let divider = record.block("lsct").flatMap { try? Compositor.sectionType($0.data) } ?? 0
            if divider == 3 {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            if divider == 1 || divider == 2 {
                result.append(describe(record, index: index, kind: .group, groups: stack))
                stack.append(Compositor.name(of: record))
                continue
            }
            result.append(describe(record, index: index, kind: kind(of: record), groups: stack))
        }
        return result
    }

    func kind(of record: LayerRecord) -> LayerKind {
        let keys = Set(record.blocks.map(\.key))
        if keys.contains("TySh") { return .type }
        if keys.contains("SoLE") { return .linkedSmartObject }
        if keys.contains("SoLd") || keys.contains("PlLd") {
            if let block = record.block("SoLd"), let smart = try? SmartObjectBlock(block.data), let id = smart.fileID,
               linkedFile(id)?.kind == "liFD" { return .smartObject }
            return .linkedSmartObject
        }
        if !keys.isDisjoint(with: ["SoCo", "GdFl", "PtFl"]) {
            return keys.contains("vmsk") || keys.contains("vsms") || keys.contains("vogk") ? .shape : .fill
        }
        if !keys.isDisjoint(with: Compositor.adjustmentKeys) { return .adjustment }
        if keys.contains("vmsk") || keys.contains("vsms") || keys.contains("vogk") { return .shape }
        return .pixel
    }

    private func describe(_ record: LayerRecord, index: Int, kind: LayerKind, groups: [String]) -> PSDLayer {
        var text: String?, style: TextStyle?, smart: SmartObjectInfo?
        if kind == .type, let block = record.block("TySh"), let tool = try? TypeToolBlock(block.data) {
            text = tool.string.replacingOccurrences(of: "\r", with: "\n")
            style = (try? TextRenderer.model(of: tool))?.style
        }
        if (kind == .smartObject || kind == .linkedSmartObject), let block = record.block("SoLd") ?? record.block("SoLE"),
           let object = try? SmartObjectBlock(block.data) {
            let linked = object.fileID.flatMap(linkedFile)
            smart = SmartObjectInfo(fileName: linked?.filename ?? "", fileType: linked?.fileType ?? "",
                                    embedded: linked?.kind == "liFD",
                                    contentWidth: object.contentSize?.width ?? 0, contentHeight: object.contentSize?.height ?? 0,
                                    corners: object.corners, warped: object.isWarped)
        }
        return PSDLayer(index: index, name: Compositor.name(of: record), kind: kind, visible: !record.isHidden,
                        opacity: Int((Double(record.opacity) / 255 * 100).rounded()), blendMode: record.blendMode,
                        bounds: [Int(record.left), Int(record.top), Int(record.right), Int(record.bottom)],
                        groups: groups, text: text, textStyle: style, smartObject: smart)
    }

    /// The record index of the layer with this name, topmost first, or a
    /// "#index" as `layers` reports it.
    /// The record a name or `#index` refers to.
    ///
    /// Layer names repeat — a group called "blur" holding a smart object
    /// called "blur", in a published sample — so a lookup that needs one
    /// kind takes the one layer of that kind with the name, and refuses
    /// when there is more than one rather than guess.
    ///
    /// - Parameters:
    ///   - name: The layer's name, or "#index".
    ///   - wanted: The kind the caller needs, when it needs one.
    func recordIndex(_ name: String, wanted: LayerKind? = nil) throws -> Int {
        if name.hasPrefix("#"), let index = Int(name.dropFirst()), index >= 0, index < file.layers.records.count {
            return index
        }
        let named = file.layers.records.indices.reversed().filter { Compositor.name(of: file.layers.records[$0]) == name }
        guard let first = named.first else { throw PSDError.layerNotFound(name) }
        guard named.count > 1, let wanted else { return first }
        let fitting = named.filter { kind(of: file.layers.records[$0]) == wanted }
        if fitting.count == 1 { return fitting[0] }
        if fitting.count > 1 { throw PSDError.ambiguousLayer(name, indices: fitting) }
        return first
    }

    func linkedFile(_ id: String) -> LinkedFileRecord? {
        for block in file.layers.blocks where ["lnk2", "lnk3", "lnkD", "lnkE"].contains(block.key) {
            if let match = (try? LinkedFileRecord.records(in: block.data))?.first(where: { $0.uuid == id }) { return match }
        }
        return nil
    }

    // MARK: - Pictures

    /// The merged image the file carries — what Quick Look shows.
    public func storedComposite() throws -> CGImage { try image(of: MergedImage.decode(file)) }

    /// This library's own flattening of the layers, and what it could not draw.
    public func renderedComposite() throws -> (image: CGImage, unrendered: [String]) {
        var notes = CompositeNotes()
        let canvas = try Compositor.composite(file, notes: &notes)
        return (try image(of: canvas), notes.unrendered)
    }

    func image(of canvas: Canvas) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: canvas.width * canvas.height * 4)
        for pixel in 0..<(canvas.width * canvas.height) {
            let alpha = canvas.pixels[pixel * 4 + 3]
            for channel in 0..<3 { bytes[pixel * 4 + channel] = UInt8(max(0, min(255, (canvas.pixels[pixel * 4 + channel] * alpha * 255).rounded()))) }
            bytes[pixel * 4 + 3] = UInt8(max(0, min(255, (alpha * 255).rounded())))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: canvas.width, height: canvas.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: canvas.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw PSDError.malformed("no image from the composite")
        }
        return image
    }

    // MARK: - Editing

    /// Changes what a type layer says.
    ///
    /// The layer's pixels are redrawn with Core Text in the layer's own font.
    /// Most real templates are set in Adobe's fonts — 17 of 20 text layers in
    /// ag-psd's published samples were Myriad Pro, Calibri or Microsoft YaHei,
    /// none of which a Mac has without Adobe's apps — so two ways past a
    /// missing font are offered rather than drawing in the wrong face
    /// unasked: `substituteFont` draws with a named stand-in (the file keeps
    /// the original font, and Photoshop redraws with it on update), and
    /// `redraw: false` changes the words only, leaving the old pixels for
    /// Photoshop to redraw when it opens the file.
    ///
    /// - Parameters:
    ///   - text: The new words; "\n" starts a new paragraph.
    ///   - name: The layer's name, or "#index".
    ///   - substituteFont: A PostScript name to draw with instead of the layer's font.
    ///   - redraw: Whether to redraw the pixels at all.
    /// - Returns: What was changed, and whether Quick Look will show it.
    /// - Throws: ``PSDError/layerNotFound(_:)``, ``PSDError/wrongLayerKind(name:expected:actual:)``,
    ///   ``PSDError/fontMissing(_:)``, ``PSDError/unsupportedForEditing(_:)``,
    ///   ``PSDError/ambiguousLayer(_:indices:)``.
    @discardableResult
    public mutating func setText(_ text: String, layer name: String, substituteFont: String? = nil,
                                 redraw: Bool = true) throws -> EditReport {
        try requireEditable()
        let index = try recordIndex(name, wanted: .type)
        let record = file.layers.records[index]
        guard let block = record.block("TySh") else {
            throw PSDError.wrongLayerKind(name: name, expected: "text", actual: kind(of: record).rawValue)
        }
        var tool = try TypeToolBlock(block.data)
        let engine = try TextEditing.replacingText(in: tool.engineData, with: text)
        tool.text.setData("EngineData", engine)
        tool.text.setText("Txt ", text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r"))
        var model = try TextRenderer.model(of: tool)
        let original = model.style.font
        if let substituteFont { model.style.font = substituteFont }

        var edited = record
        edited.blocks = edited.blocks.map { $0.key == "TySh" ? TaggedBlock(signature: $0.signature, key: "TySh", data: evenPadded(tool.encoded()), lengthWidth: $0.lengthWidth) : $0 }
        // A type layer Photoshop named after its text ('lnsr' = 'rend') is
        // renamed to the new text, as Photoshop itself would; one a person
        // renamed keeps its name.
        if let source = record.block("lnsr"), String(decoding: source.data, as: UTF8.self) == "rend" {
            rename(&edited, to: text.components(separatedBy: .newlines).joined(separator: " "))
        }
        file.layers.blocks.removeAll { $0.key == "Txt2" }

        guard redraw else {
            file.layers.records[index] = edited
            editedRecords.insert(index)
            let bounds = [Int(record.left), Int(record.top), Int(record.right), Int(record.bottom)]
            return EditReport(layer: Compositor.name(of: edited), change: "text", boundsBefore: bounds, boundsAfter: bounds,
                              pixelsRedrawn: false, compositeUpdated: false,
                              compositeNote: "the old pixels were kept — Photoshop redraws the text when it opens the file",
                              photoshopWillAskToUpdateText: true, drawnWith: nil)
        }
        let rgba = try TextRenderer.render(model, width: file.width, height: file.height)
        let report = try replacePixels(index: index, record: edited, rgba: rgba, change: "text")
        return substituteFont == nil ? report : report.drawn(with: "\(substituteFont!) standing in for \(original)")
    }

    /// Swaps the picture an embedded smart object shows.
    ///
    /// The picture is resized to the smart object's own content size first,
    /// so its placement in the document — position, scale, rotation,
    /// perspective — is untouched, and embedded as PNG.
    @discardableResult
    public mutating func replaceContents(of name: String, with image: CGImage, fit: ContentFit = .fill) throws -> EditReport {
        try requireEditable()
        let index = try recordIndex(name, wanted: .smartObject)
        let record = file.layers.records[index]
        let layerKind = kind(of: record)
        guard layerKind == .smartObject, let block = record.block("SoLd") else {
            if layerKind == .linkedSmartObject {
                throw PSDError.wrongLayerKind(name: name, expected: "embedded smart object", actual: "linked smart object")
            }
            throw PSDError.wrongLayerKind(name: name, expected: "smart object", actual: layerKind.rawValue)
        }
        let smart = try SmartObjectBlock(block.data)
        guard !smart.isWarped else {
            throw PSDError.unsupportedForEditing("\"\(name)\" is warped, and a warp mesh cannot be redrawn here")
        }
        guard let size = smart.contentSize, let id = smart.fileID else { throw PSDError.malformed("\"\(name)\" has no content size") }
        let content = try SmartObjectRenderer.fitted(image, width: Int(size.width.rounded()), height: Int(size.height.rounded()), fit: fit)
        let payload = try SmartObjectRenderer.png(content)

        for (blockIndex, linked) in file.layers.blocks.enumerated() where ["lnk2", "lnk3", "lnkD"].contains(linked.key) {
            var records = try LinkedFileRecord.records(in: linked.data)
            guard let position = records.firstIndex(where: { $0.uuid == id }) else { continue }
            records[position].payload = payload
            records[position].fileType = "png "
            let stem = (records[position].filename as NSString).deletingPathExtension
            records[position].filename = (stem.isEmpty ? "content" : stem) + ".png"
            records[position].edited = true
            file.layers.blocks[blockIndex].data = LinkedFileRecord.encode(records)
            editedLinkedFiles = true
        }
        let rgba = try SmartObjectRenderer.render(content, corners: smart.corners, width: file.width, height: file.height)
        return try replacePixels(index: index, record: record, rgba: rgba, change: "image")
    }

    /// Puts new pixels on a record, and updates the merged image where it can be trusted.
    private mutating func replacePixels(index: Int, record: LayerRecord, rgba: [UInt8], change: String) throws -> EditReport {
        let before = file.layers.records[index]
        let pixels = LayerPixels(rgba: rgba, width: file.width, height: file.height, version: file.version)
        var edited = record
        edited.top = Int32(pixels.top); edited.left = Int32(pixels.left)
        edited.bottom = Int32(pixels.bottom); edited.right = Int32(pixels.right)
        var channels = file.layers.channelData[index]
        for (position, id) in edited.channelIDs.enumerated() {
            if let replacement = pixels.channels[id] { channels[position] = replacement }
        }
        // A layer that had no transparency channel gets one: text has edges.
        for id: Int16 in [-1, 0, 1, 2] where !edited.channelIDs.contains(id) {
            edited.channelIDs.insert(id, at: 0)
            channels.insert(pixels.channels[id] ?? ChannelData(compression: 0, data: Data()), at: 0)
        }

        // The merged image: trusted only where the compositor reproduces it now.
        var notes = CompositeNotes()
        let region = (x0: min(Int(before.left), pixels.left) - 2, y0: min(Int(before.top), pixels.top) - 2,
                      x1: max(Int(before.right), pixels.right) + 2, y1: max(Int(before.bottom), pixels.bottom) + 2)
        var compositeUpdated = false
        var compositeNote: String?
        let mineBefore = try Compositor.composite(file, notes: &notes)
        let stored = try? MergedImage.decode(file)
        if let stored {
            let agreement = MergedImage.agreement(mineBefore, stored, in: region)
            if agreement.mean <= MergedImage.trustedMean && agreement.p99 <= MergedImage.trustedP99 {
                file.layers.records[index] = edited
                file.layers.channelData[index] = channels
                var after = CompositeNotes()
                let mineAfter = try Compositor.composite(file, notes: &after)
                file.imageData = try MergedImage.encode(file, replacing: region, from: mineAfter)
                compositeUpdated = true
            } else {
                let nearby = notes.within(region)
                compositeNote = nearby.isEmpty
                    ? String(format: "the saved merged image could not be reproduced here (mean difference %.0f/255) — it may have been saved without Maximize Compatibility", agreement.mean)
                    : "the merged image there includes what this library cannot draw: \(nearby.joined(separator: ", "))"
            }
        }
        if !compositeUpdated {
            file.layers.records[index] = edited
            file.layers.channelData[index] = channels
        }
        editedRecords.insert(index)
        return EditReport(layer: Compositor.name(of: edited), change: change,
                          boundsBefore: [Int(before.left), Int(before.top), Int(before.right), Int(before.bottom)],
                          boundsAfter: [pixels.left, pixels.top, pixels.right, pixels.bottom],
                          pixelsRedrawn: true, compositeUpdated: compositeUpdated, compositeNote: compositeNote,
                          photoshopWillAskToUpdateText: change == "text" && !file.layers.blocks.contains { $0.key == "Txt2" },
                          drawnWith: nil)
    }

    /// Writes a layer's name both ways a PSD keeps it: the Pascal name (Mac
    /// Roman, padded to four) and the 'luni' block (UTF-16, padded to four).
    func rename(_ record: inout LayerRecord, to name: String) {
        var pascal = name.data(using: .macOSRoman, allowLossyConversion: true) ?? Data()
        if pascal.count > 255 { pascal = pascal.prefix(255) }
        var raw = Data([UInt8(pascal.count)]) + pascal
        raw += Data(repeating: 0, count: padding(raw.count, to: 4))
        record.nameRaw = raw
        var luni = ByteWriter()
        let units = Array(name.utf16)
        luni.u32(UInt32(units.count))
        units.forEach { luni.u16($0) }
        luni.zeros(padding(luni.data.count, to: 4))
        record.blocks = record.blocks.map { $0.key == "luni" ? TaggedBlock(signature: $0.signature, key: "luni", data: luni.data, lengthWidth: $0.lengthWidth) : $0 }
    }

    private func requireEditable() throws {
        guard isEditable else { throw PSDError.unsupportedForEditing("it is \(depth)-bit \(colorMode); only 8-bit RGB is edited") }
    }

    private func evenPadded(_ data: Data) -> Data { data.count % 2 == 0 ? data : data + Data([0]) }

    // MARK: - Writing

    /// The document as bytes.
    public func data() -> Data { PSDCodec.write(file) }

    /// Writes the document, then reads it back and refuses to keep it unless
    /// every layer not edited is byte for byte the original, every edited
    /// layer says or shows what was asked, and the file parses.
    public func write(to url: URL) throws {
        let bytes = data()
        try bytes.write(to: url, options: .atomic)
        do {
            try verify(bytes)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func verify(_ bytes: Data) throws {
        let back: PSDFile
        do { back = try PSDCodec.read(bytes) } catch { throw PSDError.unverified("it does not parse: \(error.localizedDescription)") }
        guard back.layers.records.count == original.layers.records.count else {
            throw PSDError.unverified("it has \(back.layers.records.count) layers, not \(original.layers.records.count)")
        }
        for index in 0..<back.layers.records.count where !editedRecords.contains(index) {
            var a = ByteWriter(), b = ByteWriter()
            PSDCodec.writeRecord(back.layers.records[index], channels: back.layers.channelData[index], version: back.version, into: &a)
            PSDCodec.writeRecord(original.layers.records[index], channels: original.layers.channelData[index], version: original.version, into: &b)
            guard a.data == b.data, back.layers.channelData[index].map(\.data) == original.layers.channelData[index].map(\.data) else {
                throw PSDError.unverified("layer \"\(Compositor.name(of: back.layers.records[index]))\" changed though it was not edited")
            }
        }
        for index in editedRecords {
            let wanted = file.layers.records[index]
            if let block = wanted.block("TySh"), let readBack = back.layers.records[index].block("TySh") {
                guard try TypeToolBlock(readBack.data).string == TypeToolBlock(block.data).string else {
                    throw PSDError.unverified("the text of \"\(Compositor.name(of: wanted))\" did not survive")
                }
            }
        }
        let untouchedBlocks = original.layers.blocks.filter { !["Txt2", "lnk2", "lnk3", "lnkD"].contains($0.key) || (!editedLinkedFiles && $0.key != "Txt2") }
        for block in untouchedBlocks {
            guard back.layers.blocks.contains(where: { $0.key == block.key && $0.data == block.data }) else {
                throw PSDError.unverified("the document's '\(block.key)' data changed though nothing asked for it")
            }
        }
    }
}

extension MergedImage {
    /// The agreement the compositor must reach with the saved merged image,
    /// inside the edited rectangle, before rewriting it. MEASURED: on every
    /// psd-tools sample it could draw, the agreement was a mean of 0.00–0.12
    /// and a 99th percentile of 0.0–1.0 out of 255; where it met effects or
    /// a missing merged image it was 20–135 mean. The line sits well clear
    /// of both.
    static let trustedMean = 1.5
    static let trustedP99 = 8.0
}
