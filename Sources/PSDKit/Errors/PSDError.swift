//
//  PSDError.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  Failures a caller can act on, each naming what was wrong.
//

import Foundation

/// Why a PSD could not be read, changed or written.
public enum PSDError: Error, LocalizedError, Sendable, Equatable {
    /// The bytes are not a PSD or PSB this reader understands.
    case notPSD(String)
    /// A structure inside the file ran past its end or contradicted itself.
    case malformed(String)
    /// No layer has that name.
    case layerNotFound(String)
    /// The layer exists but is not the kind the operation needs.
    case wrongLayerKind(name: String, expected: String, actual: String)
    /// The document's colour mode or depth cannot be edited — only read.
    case unsupportedForEditing(String)
    /// A font the text uses is not installed, so its pixels cannot be redrawn.
    case fontMissing(String)
    /// The new image could not be read.
    case unreadableImage(String)
    /// A written file failed its own check and was not kept.
    case unverified(String)

    /// A lowercase phrase that reads inside a sentence, for a CLI or a log.
    public var errorDescription: String? {
        switch self {
        case .notPSD(let why): return "not a Photoshop file: \(why)"
        case .malformed(let why): return "the file is damaged or unusual: \(why)"
        case .layerNotFound(let name): return "no layer called \"\(name)\""
        case .wrongLayerKind(let name, let expected, let actual):
            func article(_ word: String) -> String { "aeiou".contains(word.lowercased().first ?? "x") ? "an" : "a" }
            return "\"\(name)\" is \(article(actual)) \(actual) layer, not \(article(expected)) \(expected) layer"
        case .unsupportedForEditing(let why): return "this file can be read but not edited: \(why)"
        case .fontMissing(let font): return "the font \(font) is not installed, so the text cannot be redrawn"
        case .unreadableImage(let name): return "\(name) is not an image this system can read"
        case .unverified(let why): return "the written file failed its check and was not kept: \(why)"
        }
    }
}
