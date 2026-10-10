//
//  PSDKitTests.swift
//  PSDKitTests
//
//  Created by David Sherlock on 2026.
//
//  The promises, each checked against psd-tools' sample files: a file
//  written with no change comes back byte for byte; an edit changes only
//  the layer it names; the redrawn text and pictures match Photoshop's own
//  pixels to the measured tolerance; the merged image is rewritten only
//  where it could be reproduced first; and a write that breaks any of that
//  is refused.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PSDKit

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
}
private func load(_ name: String) throws -> PSDDocument { try PSDDocument(contentsOf: fixture(name)) }

/// A picture red only in its top-left quarter, so a flip cannot hide.
private func asymmetric(width: Int = 64, height: Int = 64) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
    return context.makeImage()!
}

@Suite("Reading and writing")
struct RoundTripTests {

    @Test("A file written unchanged comes back byte for byte",
          arguments: ["text.psd", "text.psb", "placedLayer.psd", "layer_effects.psd",
                      "layers-minimal_type-layer.psd", "2layers.psd", "group.psd", "16bit5x5.psd"])
    func identical(name: String) throws {
        let original = try Data(contentsOf: fixture(name))
        #expect(try PSDDocument(data: original).data() == original)
    }

    @Test("Layers are listed top first, with kinds and groups")
    func layers() throws {
        let placed = try load("placedLayer.psd").layers
        #expect(placed.map(\.name) == ["embedded-png", "linked-psd", "linked-png", "Background"])
        #expect(placed.map(\.kind) == [.smartObject, .linkedSmartObject, .linkedSmartObject, .pixel])
        #expect(placed[0].smartObject?.embedded == true)
        #expect(placed[0].smartObject?.warped == false, "Photoshop's even custom mesh is not a warp")

        let grouped = try load("group.psd").layers
        let shape = try #require(grouped.first { $0.name == "Shape 1" })
        #expect(shape.groups == ["Group 1"])
        #expect(grouped.contains { $0.name == "Group 1" && $0.kind == .group })
    }

    @Test("A type layer's text and look are read from its engine data")
    func textAndStyle() throws {
        let layer = try #require(try load("text.psd").layers.first { $0.kind == .type })
        #expect(layer.text == "Line 1\nLine 2\nLine 3 and text")
        #expect(layer.textStyle?.font == "ArialMT")
        #expect(layer.textStyle?.size == 13)
    }

    @Test("A 16-bit file is read but not edited")
    func sixteenBit() throws {
        var document = try load("16bit5x5.psd")
        #expect(!document.isEditable)
        #expect(throws: PSDError.self) { try document.setText("x", layer: "#0") }
    }
}

@Suite("Changing text")
struct TextTests {

    @Test("The new text is in the layer, the engine data's runs add up, and nothing else moved")
    func setText() throws {
        var document = try load("text.psd")
        let report = try document.setText("Hello Wörld (test)\nSecond line", layer: "#1")
        #expect(report.compositeUpdated, "text.psd's merged image is reproduced exactly, so it is rewritten")
        #expect(report.photoshopWillAskToUpdateText)

        let back = try PSDDocument(data: document.data())
        let layer = try #require(back.layers.first { $0.kind == .type })
        #expect(layer.text == "Hello Wörld (test)\nSecond line")
        #expect(layer.name == "Hello Wörld (test) Second line", "an auto-named type layer takes its new text")

        let tool = try TypeToolBlock(back.file.layers.records[1].block("TySh")!.data)
        let root = try EngineData.parse(tool.engineData)
        #expect(root.at("EngineDict", "Editor", "Text")?.string == "Hello Wörld (test)\rSecond line\r")
        #expect(root.at("EngineDict", "ParagraphRun", "RunLengthArray")?.items.compactMap(\.number) == [19, 12])
        #expect(root.at("EngineDict", "StyleRun", "RunLengthArray")?.items.compactMap(\.number) == [31])
        #expect(!back.file.layers.blocks.contains { $0.key == "Txt2" })

        // The background layer is untouched, byte for byte.
        let original = try load("text.psd")
        #expect(back.file.layers.channelData[0].map(\.data) == original.file.layers.channelData[0].map(\.data))
    }

    @Test("Outside the changed rectangle the merged image is untouched")
    func compositeOnlyInRegion() throws {
        var document = try load("text.psd")
        let report = try document.setText("Hi", layer: "#1")
        let before = try MergedImage.decode(try load("text.psd").file)
        let after = try MergedImage.decode(document.file)
        let x0 = min(report.boundsBefore[0], report.boundsAfter[0]) - 2, y0 = min(report.boundsBefore[1], report.boundsAfter[1]) - 2
        let x1 = max(report.boundsBefore[2], report.boundsAfter[2]) + 2, y1 = max(report.boundsBefore[3], report.boundsAfter[3]) + 2
        var changedOutside = 0, changedInside = 0
        for y in 0..<before.height { for x in 0..<before.width {
            let p = (y * before.width + x) * 4
            let differs = (0..<4).contains { before.pixels[p + $0] != after.pixels[p + $0] }
            if differs { if x >= x0 && x < x1 && y >= y0 && y < y1 { changedInside += 1 } else { changedOutside += 1 } }
        } }
        #expect(changedOutside == 0)
        #expect(changedInside > 0)
    }

    @Test("Where effects are drawn the merged image is left, and the report says why")
    func effectsLeaveComposite() throws {
        var document = try load("layer_effects.psd")
        let report = try document.setText("Changed", layer: "Bevel")
        #expect(!report.compositeUpdated)
        #expect(report.compositeNote?.contains("effects") == true)
        #expect(report.pixelsRedrawn)
    }

    @Test("Redrawn text matches Photoshop's own pixels to the measured tolerance")
    func fidelity() throws {
        // The README's numbers: ArialMT 13 pt lands on the same box; faux-bold
        // Arial Black at 62.5 pt overlaps Photoshop's pixels by 0.83–0.96.
        for (name, minimumOverlap) in [("text.psd", 0.6), ("layer_effects.psd", 0.8)] {
            let document = try load(name)
            for (index, record) in document.file.layers.records.enumerated() {
                guard let block = record.block("TySh"), let alphaIndex = record.channelIDs.firstIndex(of: -1) else { continue }
                let model = try TextRenderer.model(of: try TypeToolBlock(block.data))
                let mine = try TextRenderer.render(model, width: document.width, height: document.height)
                let stored = try ChannelCodec.decode(document.file.layers.channelData[index][alphaIndex], width: record.width,
                                                     height: record.height, depth: 8, version: document.file.version)
                var inter = 0, union = 0
                for y in 0..<document.height { for x in 0..<document.width {
                    let lx = x - Int(record.left), ly = y - Int(record.top)
                    let s = lx >= 0 && ly >= 0 && lx < record.width && ly < record.height && stored[ly * record.width + lx] > 127
                    let m = mine[(y * document.width + x) * 4 + 3] > 127
                    if s && m { inter += 1 }; if s || m { union += 1 }
                } }
                let overlap = Double(inter) / Double(max(1, union))
                #expect(overlap >= minimumOverlap, "\(name) layer \(index): \(overlap)")
            }
        }
    }

    @Test("A missing font is refused rather than drawn in the wrong face")
    func missingFont() throws {
        var model = try TextRenderer.model(of: TypeToolBlock(load("text.psd").file.layers.records[1].block("TySh")!.data))
        model.style.font = "NoSuchFont-Regular"
        #expect(throws: PSDError.fontMissing("NoSuchFont-Regular")) { try TextRenderer.render(model, width: 10, height: 10) }
    }

    @Test("Characters the engine data must escape survive")
    func escaping() throws {
        let encoded = EngineData.encodeString("a(b)c\\d — 東京")
        let node = try EngineData.parse(Data("<< /T ".utf8) + encoded + Data(" >>".utf8))
        #expect(node["T"]?.string == "a(b)c\\d — 東京")
    }

    @Test("Only a type layer takes text")
    func wrongKind() throws {
        var document = try load("text.psd")
        #expect(throws: PSDError.self) { try document.setText("x", layer: "Background") }
        #expect(throws: PSDError.layerNotFound("Nope")) { try document.setText("x", layer: "Nope") }
    }
}

@Suite("Swapping pictures")
struct SmartObjectTests {

    @Test("The original embedded picture redraws exactly where Photoshop put it")
    func placementFidelity() throws {
        let document = try load("placedLayer.psd")
        let index = try document.recordIndex("embedded-png")
        let record = document.file.layers.records[index]
        let smart = try SmartObjectBlock(record.block("SoLd")!.data)
        let payload = try #require(document.linkedFile(smart.fileID!)?.payload)
        let original = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(payload as CFData, nil)!, 0, nil)!
        let rgba = try SmartObjectRenderer.render(original, corners: smart.corners, width: document.width, height: document.height)
        var drawn = Canvas(width: document.width, height: document.height)
        for i in 0..<(document.width * document.height) { for c in 0..<4 { drawn.pixels[i * 4 + c] = Float(rgba[i * 4 + c]) / 255 } }
        let stored = try Compositor.pixels(of: record, index: index, in: document.file)
        let agreement = MergedImage.agreement(stored, drawn, in: (Int(record.left), Int(record.top), Int(record.right), Int(record.bottom)))
        #expect(agreement.mean < 0.5)
    }

    @Test("A swapped picture is embedded, drawn the right way up, and the merged image follows")
    func swap() throws {
        var document = try load("placedLayer.psd")
        let report = try document.replaceContents(of: "embedded-png", with: asymmetric(width: 128, height: 128))
        #expect(report.compositeUpdated)
        let back = try PSDDocument(data: document.data())
        let info = try #require(back.layers.first { $0.name == "embedded-png" }?.smartObject)
        #expect(info.fileType == "png ")
        #expect(info.fileName == "linked-layer.png")

        // The layer's top-left pixel is red, its bottom-left blue.
        let index = try back.recordIndex("embedded-png")
        let layer = try Compositor.pixels(of: back.file.records(index), index: index, in: back.file)
        let record = back.file.layers.records[index]
        let topLeft = (Int(record.top) * back.width + Int(record.left)) * 4
        let bottomLeft = ((Int(record.bottom) - 1) * back.width + Int(record.left)) * 4
        #expect(layer.pixels[topLeft] > 0.9 && layer.pixels[topLeft + 2] < 0.1)
        #expect(layer.pixels[bottomLeft + 2] > 0.9 && layer.pixels[bottomLeft] < 0.1)
    }

    @Test("A linked smart object and a pixel layer are refused")
    func refusals() throws {
        var document = try load("placedLayer.psd")
        #expect(throws: PSDError.self) { try document.replaceContents(of: "linked-png", with: asymmetric()) }
        #expect(throws: PSDError.self) { try document.replaceContents(of: "Background", with: asymmetric()) }
    }
}

@Suite("Compositing and checking")
struct CheckTests {

    @Test("The compositor reproduces the saved merged image where it can draw everything",
          arguments: ["text.psd", "placedLayer.psd", "group.psd"])
    func exact(name: String) throws {
        let file = try load(name).file
        var notes = CompositeNotes()
        let mine = try Compositor.composite(file, notes: &notes)
        let agreement = MergedImage.agreement(mine, try MergedImage.decode(file), in: (0, 0, file.width, file.height))
        #expect(notes.unrendered.isEmpty)
        #expect(agreement.mean < MergedImage.trustedMean)
        #expect(agreement.p99 < MergedImage.trustedP99)
    }

    @Test("Effects are reported, not drawn")
    func effects() throws {
        var notes = CompositeNotes()
        _ = try Compositor.composite(try load("layer_effects.psd").file, notes: &notes)
        #expect(notes.unrendered.contains("Bevel (effects)"))
    }

    @Test("A write that changed a layer nobody named is refused and deleted")
    func refusesCollateral() throws {
        var document = try load("text.psd")
        try document.setText("Hi", layer: "#1")
        document.file.layers.channelData[0][0].data.append(0)   // tamper with the background
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("psdkit-\(UUID().uuidString).psd")
        #expect(throws: PSDError.self) { try document.write(to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

private extension PSDFile {
    func records(_ index: Int) -> LayerRecord { layers.records[index] }
}
