//
//  SmartObjectRenderer.swift
//  PSDKit
//
//  Created by David Sherlock on 2026.
//
//  A smart object's picture drawn where the document places it: its four
//  stored corners, any affine or perspective placement (not a warp mesh).
//  Validated the same way as text — the ORIGINAL embedded picture is drawn
//  and compared with the pixels Photoshop stored before a swap is trusted.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How a new picture fills a smart object's frame.
public enum ContentFit: String, Sendable, Codable, CaseIterable {
    /// Cover the frame, cropping the overflow from the centre. The default:
    /// a template's photo slot should be full.
    case fill
    /// Fit inside the frame, leaving transparent margins.
    case fit
    /// Stretch to the frame, ignoring the picture's shape.
    case stretch
}

/// Draws smart-object content.
enum SmartObjectRenderer {

    /// A picture resized to exactly the content size the smart object expects.
    static func fitted(_ image: CGImage, width: Int, height: Int, fit: ContentFit) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PSDError.malformed("no \(width)×\(height) canvas")
        }
        context.interpolationQuality = .high
        let source = CGSize(width: image.width, height: image.height)
        let frame = CGSize(width: width, height: height)
        var rect = CGRect(origin: .zero, size: frame)
        if fit != .stretch {
            let scale = fit == .fill ? max(frame.width / source.width, frame.height / source.height)
                                     : min(frame.width / source.width, frame.height / source.height)
            let size = CGSize(width: source.width * scale, height: source.height * scale)
            rect = CGRect(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2,
                          width: size.width, height: size.height)
        }
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw PSDError.malformed("the fitted picture came out empty") }
        return result
    }

    /// A picture as PNG bytes — the payload a swapped smart object embeds.
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PSDError.malformed("no PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PSDError.malformed("the PNG would not encode") }
        return data as Data
    }

    /// Content drawn into its corners on a transparent document-sized
    /// canvas, as straight RGBA, top row first.
    static func render(_ content: CGImage, corners: [Double], width: Int, height: Int) throws -> [UInt8] {
        guard corners.count == 8 else { throw PSDError.malformed("a smart object without four corners") }
        let flip = { (x: Double, y: Double) in CGPoint(x: x, y: Double(height) - y) }
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = CIImage(cgImage: content)
        filter.topLeft = flip(corners[0], corners[1])
        filter.topRight = flip(corners[2], corners[3])
        filter.bottomRight = flip(corners[4], corners[5])
        filter.bottomLeft = flip(corners[6], corners[7])
        guard let placed = filter.outputImage else { throw PSDError.malformed("the placement failed") }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
            .render(placed, toBitmap: &rgba, rowBytes: width * 4,
                    bounds: CGRect(x: 0, y: 0, width: width, height: height),
                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        // Core Image hands back premultiplied rows, top row first (MEASURED
        // with a picture red only in its top-left quarter — the first
        // version flipped them, and the psd-tools sample's payload was
        // symmetric enough to hide it); the layer wants straight alpha.
        var out = rgba
        for pixel in stride(from: 0, to: out.count, by: 4) {
            let alpha = Int(out[pixel + 3])
            guard alpha > 0, alpha < 255 else { if alpha == 0 { out[pixel] = 0; out[pixel + 1] = 0; out[pixel + 2] = 0 }; continue }
            for c in 0..<3 { out[pixel + c] = UInt8(min(255, Int(out[pixel + c]) * 255 / alpha)) }
        }
        return out
    }
}
