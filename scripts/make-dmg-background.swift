#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Renders the installer window background for VoicePaste.dmg.
//
// Deliberately quiet: the two icons Finder draws on top are the content, so the
// background only has to give them a surface and point from one to the other.
// Anything louder competes with the thing the person is supposed to do.
//
// Emits a multi-representation TIFF (1x + 2x) so the panel stays crisp on
// Retina — a plain PNG at logical size renders visibly soft there.

let size = CGSize(width: 640, height: 420)

/// Icon centres, in Finder's coordinate space (origin top-left). The Finder
/// layout in `build-release.sh` must use these exact values.
let appIconCentre = CGPoint(x: 160, y: 200)
let applicationsIconCentre = CGPoint(x: 480, y: 200)

func render(scale: CGFloat) -> NSBitmapImageRep {
    let pixelWidth = Int(size.width * scale)
    let pixelHeight = Int(size.height * scale)
    guard let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("cannot create bitmap context") }

    context.scaleBy(x: scale, y: scale)

    // Vertical gradient, very shallow. A flat fill reads as "unfinished
    // window"; a strong one competes with the icons.
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(srgbRed: 0.980, green: 0.980, blue: 0.988, alpha: 1),
            CGColor(srgbRed: 0.929, green: 0.929, blue: 0.945, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size.height),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Convert Finder's top-left origin to Core Graphics' bottom-left one.
    func flipped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: size.height - point.y)
    }

    let from = flipped(appIconCentre)
    let to = flipped(applicationsIconCentre)
    let midpoint = CGPoint(x: (from.x + to.x) / 2, y: from.y)

    // A single chevron between the icons: the smallest mark that says "drag
    // that way" without an instruction line nobody reads.
    let armLength: CGFloat = 17
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: midpoint.x - armLength * 0.62, y: midpoint.y + armLength))
    arrow.addLine(to: CGPoint(x: midpoint.x + armLength * 0.62, y: midpoint.y))
    arrow.addLine(to: CGPoint(x: midpoint.x - armLength * 0.62, y: midpoint.y - armLength))

    context.setStrokeColor(CGColor(srgbRed: 0.706, green: 0.706, blue: 0.741, alpha: 1))
    context.setLineWidth(7)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(arrow)
    context.strokePath()

    guard let image = context.makeImage() else { fatalError("cannot render image") }
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = size // logical points, so the 2x rep is tagged as HiDPI
    return representation
}

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "background.tiff"

// LZW keeps the two representations around a hundred kilobytes instead of five
// megabytes — on a 5 MB installer the uncompressed version would dominate the
// download for a flat gradient and one chevron.
let data = NSBitmapImageRep.representationOfImageReps(
    in: [render(scale: 1), render(scale: 2)],
    using: .tiff,
    properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue]
)

guard let data else { fatalError("cannot encode TIFF") }
try data.write(to: URL(fileURLWithPath: outputPath))
print(outputPath)
