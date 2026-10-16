//
//  WriterTests.swift
//  PSDKitTests
//
//  A layered PSD written from pictures and read back: by this library's
//  reader (names, order, groups, blend keys, opacity, visibility), its
//  compositor (the layers flatten to the merged image), and ImageIO (the
//  merged image is what Quick Look shows).
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PSDKit

struct WriterTests {

    static let size = 64

    /// A document-sized picture with one rectangle of colour.
    static func rect(_ color: (Double, Double, Double, Double), _ box: CGRect) -> CGImage {
        let s = size
        let c = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: color.3))
        c.fill(box)
        return c.makeImage()!
    }

    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return buf
    }

    @Test func aWrittenFileReadsBackLayerForLayer() throws {
        let full = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        let background = Self.rect((0.5, 0.5, 0.5, 1), full)
        let red = Self.rect((1, 0, 0, 1), CGRect(x: 8, y: 8, width: 24, height: 24))
        let blue = Self.rect((0, 0, 1, 0.5), CGRect(x: 20, y: 20, width: 30, height: 30))
        let layers = [
            PSDWriteLayer(name: "background", content: .pixels(background)),
            PSDWriteLayer(name: "group ✦", content: .group([
                PSDWriteLayer(name: "red", content: .pixels(red), blendKey: "mul "),
                PSDWriteLayer(name: "blue", content: .pixels(blue), opacity: 0.6, blendKey: "scrn"),
            ]), opacity: 0.8, blendKey: "pass"),
            PSDWriteLayer(name: "hidden", content: .pixels(red), visible: false),
        ]
        let data = try PSDWriter.data(width: Self.size, height: Self.size, layers: layers, composite: background, dpi: 300)
        let document = try PSDDocument(data: data)
        let read = document.layers
        #expect(read.map(\.name) == ["hidden", "group ✦", "blue", "red", "background"], "top first, Unicode names kept")
        #expect(read.first { $0.name == "red" }?.groups == ["group ✦"])
        #expect(read.first { $0.name == "red" }?.blendMode == "mul ")
        #expect(read.first { $0.name == "blue" }?.opacity == 60)
        #expect(read.first { $0.name == "group ✦" }?.opacity == 80)
        #expect(read.first { $0.name == "hidden" }?.visible == false)
        // Cropped to its pixels: left, top, right, bottom (top-left origin).
        #expect(read.first { $0.name == "red" }?.bounds == [8, 32, 32, 56])

        // The same bytes written again: the codec reads the file as written.
        #expect(PSDCodec.write(try PSDCodec.read(data)) == data)

        // ImageIO opens it and shows the merged image.
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let merged = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(merged.width == Self.size && Self.pixel(merged, 5, 5)[0] == 128)
        let file = try PSDCodec.read(data)
        #expect(file.imageResources.prefix(6) == Data("8BIM".utf8) + Data([0x03, 0xED]), "the resolution is recorded")

        // The compositor flattens the layers. A group is isolated, so the red
        // multiplies onto nothing inside it, and the group lies at 0.8 over grey.
        let (flat, skipped) = try document.renderedComposite()
        #expect(skipped.isEmpty)
        let red50 = Self.pixel(flat, 12, 50)
        #expect(abs(Int(red50[0]) - 230) <= 3 && abs(Int(red50[1]) - 26) <= 3, "\(red50)")
    }

    @Test func everyDesignBlendIsComposited() {
        // Each key's arithmetic at one sample: backdrop 0.5, source 0.25.
        let expected: [(String, Float)] = [("sLit", 0.375), ("hLit", 0.25), ("div ", 0.6666667), ("idiv", 0), ("lbrn", 0),
                                           ("smud", 0.5)]
        for (key, value) in expected {
            #expect(abs(Compositor.blendChannel(key, 0.5, 0.25) - value) < 0.02, "\(key)")
        }
        let lum = Compositor.blendColor("lum ", [1, 0, 0], [0.5, 0.5, 0.5])
        #expect(abs((0.3 * lum[0] + 0.59 * lum[1] + 0.11 * lum[2]) - 0.5) < 0.01, "luminosity takes the source's lightness")
        #expect(Compositor.supportedBlends.isSuperset(of: ["sLit", "hLit", "div ", "idiv", "lbrn", "smud", "hue ", "sat ", "colr", "lum "]))
    }

    @Test func anUnknownBlendKeyIsRefused() {
        let image = Self.rect((1, 1, 1, 1), CGRect(x: 0, y: 0, width: 4, height: 4))
        #expect(throws: PSDError.self) {
            try PSDWriter.data(width: Self.size, height: Self.size, layers: [PSDWriteLayer(name: "x", content: .pixels(image), blendKey: "nope")],
                               composite: image)
        }
    }
}
