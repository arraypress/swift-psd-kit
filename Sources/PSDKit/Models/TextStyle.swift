//
//  TextStyle.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  How a type layer's text looks, as the text engine stores it: the first
//  style run's font, size, colour, leading and tracking, and the first
//  paragraph's justification — with anything a run leaves out taken from
//  the document's normal style sheet, which is where the engine keeps it.
//

import CoreGraphics
import Foundation

/// The look of a type layer's text.
public struct TextStyle: Sendable, Codable, Equatable {
    /// The PostScript name of the font.
    public var font: String
    /// The size in points, in the layer's own text space.
    public var size: Double
    /// Red, green, blue and alpha, 0–1.
    public var color: [Double]
    /// The distance between baselines, in points.
    public var leading: Double
    /// Extra space between characters, in thousandths of an em.
    public var tracking: Double
    /// 0 left, 1 right, 2 centre.
    public var justification: Int
    /// True for paragraph (box) text, false for point text.
    public var isBox: Bool
    /// For box text: left, top, right, bottom in text space.
    public var box: [Double]
    public var horizontalScale: Double
    public var verticalScale: Double
    public var fauxBold: Bool
    /// Points up from the baseline.
    public var baselineShift: Double
}

/// One type layer's text and where it goes.
struct TextModel {
    var paragraphs: [String]
    var style: TextStyle
    /// xx, xy, yx, yy, tx, ty.
    var transform: [Double]
}
