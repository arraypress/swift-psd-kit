//
//  LayerKind.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  What a layer is, as far as editing it is concerned.
//

import Foundation

/// The kind of a layer.
public enum LayerKind: String, Sendable, Codable, CaseIterable {
    /// Ordinary pixels.
    case pixel
    /// Text: its words can be changed.
    case type
    /// A smart object whose file is embedded: its picture can be swapped.
    case smartObject
    /// A smart object pointing at a file outside the document.
    case linkedSmartObject
    /// A group (folder) of layers.
    case group
    /// A vector shape.
    case shape
    /// A solid, gradient or pattern fill.
    case fill
    /// An adjustment — levels, curves, hue — with no pixels of its own.
    case adjustment
}
