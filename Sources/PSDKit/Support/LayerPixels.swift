//
//  LayerPixels.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  A document-sized straight-RGBA buffer cut down to a layer: the rectangle
//  its ink covers, and one PackBits plane per channel in the order the
//  record already lists them — so a user mask (-2) keeps its own bytes.
//

import Foundation

/// A layer's new pixels, ready for its record.
struct LayerPixels {
    var top = 0, left = 0, bottom = 0, right = 0
    /// Channel id → compressed plane.
    var channels: [Int16: ChannelData] = [:]

    /// Cuts a document-sized straight RGBA buffer down to its ink.
    init(rgba: [UInt8], width: Int, height: Int, version: Int) {
        var x0 = width, y0 = height, x1 = -1, y1 = -1
        for y in 0..<height {
            for x in 0..<width where rgba[(y * width + x) * 4 + 3] > 0 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x1 >= x0 else {
            for id: Int16 in [-1, 0, 1, 2] { channels[id] = ChannelData(compression: 0, data: Data()) }
            return
        }
        (top, left, bottom, right) = (y0, x0, y1 + 1, x1 + 1)
        let w = right - left, h = bottom - top
        for (id, offset) in [(Int16(-1), 3), (0, 0), (1, 1), (2, 2)] {
            var plane = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w { plane[y * w + x] = rgba[((top + y) * width + left + x) * 4 + offset] }
            }
            channels[id] = ChannelData(compression: 1, data: ChannelCodec.encodeRLE(plane, width: w, height: h, version: version))
        }
    }
}

/// Changing what a type layer says, in its engine data.
enum TextEditing {

    /// The engine data with new text, one paragraph per line.
    ///
    /// The text engine counts in UTF-16 units and ends the text with a
    /// carriage return, and its paragraph and style runs must add up to
    /// exactly that length — so the runs are rebuilt: one paragraph run per
    /// line, each a copy of the first paragraph's, and one style run, a copy
    /// of the first style's. Mixed styling inside a layer becomes the first
    /// run's look; that is said in the README, not hidden.
    static func replacingText(in engine: Data, with text: String) throws -> Data {
        let root = try EngineData.parse(engine)
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let full = lines.joined(separator: "\r") + "\r"
        let lengths = lines.map { $0.utf16.count + 1 }

        guard let editorText = root.at("EngineDict", "Editor", "Text"),
              let paragraphLengths = root.at("EngineDict", "ParagraphRun", "RunLengthArray"),
              let paragraphRuns = root.at("EngineDict", "ParagraphRun", "RunArray"), let firstParagraph = paragraphRuns.items.first,
              let styleLengths = root.at("EngineDict", "StyleRun", "RunLengthArray"),
              let styleRuns = root.at("EngineDict", "StyleRun", "RunArray"), let firstStyle = styleRuns.items.first else {
            throw PSDError.malformed("the text engine data is missing its runs")
        }
        let bytes = [UInt8](engine)
        let paragraphBytes = Data(bytes[firstParagraph.range])
        let styleBytes = Data(bytes[firstStyle.range])
        func array(_ parts: [Data]) -> Data {
            var out = Data("[ ".utf8)
            for (index, part) in parts.enumerated() { if index > 0 { out += Data(" ".utf8) }; out += part }
            return out + Data(" ]".utf8)
        }
        return EngineData.splice(engine, [
            (editorText.range, EngineData.encodeString(full)),
            (paragraphLengths.range, array(lengths.map { Data(String($0).utf8) })),
            (paragraphRuns.range, array(Array(repeating: paragraphBytes, count: lengths.count))),
            (styleLengths.range, array([Data(String(full.utf16.count).utf8)])),
            (styleRuns.range, array([styleBytes])),
        ])
    }
}
