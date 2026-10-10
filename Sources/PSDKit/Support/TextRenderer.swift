//
//  TextRenderer.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  Draws a type layer's text with Core Text, where Photoshop would. The
//  text engine's own line breaking and anti-aliasing are not public, so this
//  is an approximation of them — measured, not assumed: each sample's
//  ORIGINAL text is redrawn and compared with the pixels Photoshop stored
//  before a changed one is trusted.
//

import CoreGraphics
import CoreText
import Foundation

/// Renders type layers.
enum TextRenderer {

    /// Faux bold: Photoshop thickens the outline AND widens each advance.
    /// MEASURED, by grid search against the eleven faux-bold 62.5 pt Arial
    /// Black layers in psd-tools' layer_effects.psd: an outline of 2% of
    /// the size and 0.026 em more advance per glyph raised the mean overlap
    /// with Photoshop's own pixels from 0.53 to 0.92 and brought the right
    /// edge within 1.0 px on average (it was 13 px short).
    static let fauxBoldStroke: Double = 2        // percent of the size, CoreText's unit
    static let fauxBoldAdvance: Double = 0.026   // em per glyph

    /// Reads a text model out of a type layer's block.
    static func model(of block: TypeToolBlock) throws -> TextModel {
        let root = try EngineData.parse(block.engineData)
        let text = root.at("EngineDict", "Editor", "Text")?.string ?? block.string
        var paragraphs = text.components(separatedBy: "\r")
        if paragraphs.last == "" { paragraphs.removeLast() }

        let run = root.at("EngineDict", "StyleRun", "RunArray", "0", "StyleSheet", "StyleSheetData")
        let normalIndex = Int(root.at("ResourceDict", "TheNormalStyleSheet")?.number ?? 0)
        let normal = root.at("ResourceDict", "StyleSheetSet", "\(normalIndex)", "StyleSheetData")
        func style(_ key: String) -> EngineNode? { run?[key] ?? normal?[key] }

        let paragraph = root.at("EngineDict", "ParagraphRun", "RunArray", "0", "ParagraphSheet", "Properties")
        let normalParagraphIndex = Int(root.at("ResourceDict", "TheNormalParagraphSheet")?.number ?? 0)
        let normalParagraph = root.at("ResourceDict", "ParagraphSheetSet", "\(normalParagraphIndex)", "Properties")
        func para(_ key: String) -> EngineNode? { paragraph?[key] ?? normalParagraph?[key] }

        let fonts = root.at("ResourceDict", "FontSet")?.items.compactMap { $0["Name"]?.string } ?? []
        let fontIndex = Int(style("Font")?.number ?? 0)
        let size = style("FontSize")?.number ?? 12
        let argb = style("FillColor")?["Values"]?.items.compactMap(\.number) ?? [1, 0, 0, 0]
        let autoLeading = style("AutoLeading")?.bool ?? true
        let leading = autoLeading ? size * (para("AutoLeading")?.number ?? 1.2) : (style("Leading")?.number ?? size * 1.2)

        let shape = root.at("EngineDict", "Rendered", "Shapes", "Children", "0")
        let isBox = (shape?["ShapeType"]?.number ?? 0) == 1
        let box = shape?.at("Cookie", "Photoshop", "BoxBounds")?.items.compactMap(\.number) ?? []

        let style = TextStyle(
            font: fontIndex < fonts.count ? fonts[fontIndex] : (fonts.first ?? "Helvetica"),
            size: size,
            color: argb.count == 4 ? [argb[1], argb[2], argb[3], argb[0]] : [0, 0, 0, 1],
            leading: leading,
            tracking: style("Tracking")?.number ?? 0,
            justification: Int(para("Justification")?.number ?? 0),
            isBox: isBox && box.count == 4, box: box,
            horizontalScale: style("HorizontalScale")?.number ?? 1,
            verticalScale: style("VerticalScale")?.number ?? 1,
            fauxBold: style("FauxBold")?.bool ?? false,
            baselineShift: style("BaselineShift")?.number ?? 0)
        return TextModel(paragraphs: paragraphs, style: style, transform: block.transform)
    }

    /// Whether a font is installed under its PostScript name.
    static func isInstalled(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        return (CTFontCopyPostScriptName(font) as String) == name
    }

    /// The text drawn over a transparent document-sized canvas, as straight
    /// (unpremultiplied) RGBA, top row first.
    static func render(_ model: TextModel, width: Int, height: Int) throws -> [UInt8] {
        guard isInstalled(model.style.font) else { throw PSDError.fontMissing(model.style.font) }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PSDError.malformed("no \(width)×\(height) canvas")
        }
        let style = model.style
        let font = CTFontCreateWithName(style.font as CFString, style.size, nil)
        let color = CGColor(srgbRed: style.color[0], green: style.color[1], blue: style.color[2], alpha: style.color[3])
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        if style.tracking != 0 {
            attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = style.tracking / 1000 * style.size
        }
        if style.fauxBold {
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -fauxBoldStroke
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color
            let kern = (attributes[NSAttributedString.Key(kCTKernAttributeName as String)] as? Double) ?? 0
            attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = kern + fauxBoldAdvance * style.size
        }

        // Document space, y down; then the layer's own text space.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let t = model.transform
        context.concatenate(CGAffineTransform(a: t[0], b: t[1], c: t[2], d: t[3], tx: t[4], ty: t[5]))
        context.scaleBy(x: style.horizontalScale, y: style.verticalScale)

        let lines = layoutLines(model, font: font, attributes: attributes)
        // Paragraph text's first baseline sits the height of a "d" below the
        // box top — Adobe's "Ascent" first-baseline rule — not the font's
        // full ascent, which put Arial 5.6 px low in the psd-tools sample.
        let ascent = glyphHeight("d", font: font)
        for (index, line) in lines.enumerated() {
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            var x: Double, y: Double
            if style.isBox {
                let (left, top, right) = (style.box[0], style.box[1], style.box[2])
                x = style.justification == 1 ? right - width : style.justification == 2 ? (left + right - width) / 2 : left
                y = top + ascent + Double(index) * style.leading
            } else {
                x = style.justification == 1 ? -width : style.justification == 2 ? -width / 2 : 0
                y = Double(index) * style.leading
            }
            context.saveGState()
            context.translateBy(x: x, y: y - style.baselineShift)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }

        guard let data = context.data else { return [] }
        let premultiplied = UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height * 4),
                                                count: width * height * 4)
        var straight = [UInt8](premultiplied)
        for pixel in stride(from: 0, to: straight.count, by: 4) {
            let alpha = Int(straight[pixel + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 { straight[pixel + channel] = UInt8(min(255, Int(straight[pixel + channel]) * 255 / alpha)) }
        }
        return straight
    }

    /// The height of a character's ink above the baseline.
    static func glyphHeight(_ character: Character, font: CTFont) -> Double {
        var unichars = Array(String(character).utf16)
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &unichars, &glyph, 1) else { return CTFontGetCapHeight(font) }
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bounds, 1)
        return bounds.maxY
    }

    /// The text broken into lines: one per paragraph for point text, wrapped
    /// to the box for paragraph text.
    static func layoutLines(_ model: TextModel, font: CTFont, attributes: [NSAttributedString.Key: Any]) -> [CTLine] {
        var lines: [CTLine] = []
        for paragraph in model.paragraphs {
            let string = NSAttributedString(string: paragraph, attributes: attributes)
            guard model.style.isBox else { lines.append(CTLineCreateWithAttributedString(string)); continue }
            let width = (model.style.box[2] - model.style.box[0]) / max(0.01, model.style.horizontalScale)
            let typesetter = CTTypesetterCreateWithAttributedString(string)
            var start = 0
            if string.length == 0 { lines.append(CTLineCreateWithAttributedString(string)) }
            while start < string.length {
                let count = CTTypesetterSuggestLineBreak(typesetter, start, width)
                lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: max(1, count))))
                start += max(1, count)
            }
        }
        return lines
    }
}
