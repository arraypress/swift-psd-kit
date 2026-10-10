//
//  PSDLayer.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  A layer as a caller sees it: its name, kind, where it is and, for the
//  kinds this library edits, what it says or shows.
//

import Foundation

/// One layer of a document.
public struct PSDLayer: Sendable, Codable, Equatable {
    /// The record's position in the file, bottom layer first.
    public let index: Int
    public let name: String
    public let kind: LayerKind
    public let visible: Bool
    /// 0–100.
    public let opacity: Int
    /// Photoshop's four-letter blend key: "norm", "mul ", "pass"…
    public let blendMode: String
    /// Left, top, right, bottom in document pixels.
    public let bounds: [Int]
    /// The groups it sits in, outermost first.
    public let groups: [String]
    /// A type layer's text, with line breaks as "\n".
    public let text: String?
    /// A type layer's look.
    public let textStyle: TextStyle?
    /// A smart object's content.
    public let smartObject: SmartObjectInfo?
}

/// What a smart object shows.
public struct SmartObjectInfo: Sendable, Codable, Equatable {
    public let fileName: String
    /// The four-character type: "png ", "JPEG", "8BPS", "8BPB"…
    public let fileType: String
    public let embedded: Bool
    /// The content's own size in pixels.
    public let contentWidth: Double
    public let contentHeight: Double
    /// Corners in the document: top-left, top-right, bottom-right, bottom-left, as x,y.
    public let corners: [Double]
    public let warped: Bool
}

/// What an edit did, so a caller can tell a full success from a partial one.
public struct EditReport: Sendable, Codable, Equatable {
    public let layer: String
    /// "text" or "image".
    public let change: String
    /// Left, top, right, bottom before and after.
    public let boundsBefore: [Int]
    public let boundsAfter: [Int]
    /// Whether the layer's own pixels were redrawn (always, when the edit succeeds).
    public let pixelsRedrawn: Bool
    /// Whether the merged image — what Quick Look, ImageIO and the web show
    /// — was updated. False when it could not be trusted; see `compositeNote`.
    public let compositeUpdated: Bool
    public let compositeNote: String?
    /// For text: the document-wide text engine data was dropped, so
    /// Photoshop offers to update the text layers when the file is opened.
    public let photoshopWillAskToUpdateText: Bool
    /// For text drawn with a stand-in font: which, and for what.
    public let drawnWith: String?

    /// The same report, noting the stand-in font the pixels were drawn with.
    func drawn(with note: String) -> EditReport {
        EditReport(layer: layer, change: change, boundsBefore: boundsBefore, boundsAfter: boundsAfter,
                   pixelsRedrawn: pixelsRedrawn, compositeUpdated: compositeUpdated, compositeNote: compositeNote,
                   photoshopWillAskToUpdateText: photoshopWillAskToUpdateText, drawnWith: note)
    }
}
