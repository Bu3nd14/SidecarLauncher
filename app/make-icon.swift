#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO

private let master: CGFloat = 1024

enum IconVariant {
    case normal
    case switching
}

private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

private func drawIcon(size: Int, variant: IconVariant) -> CGImage? {
    let scale = CGFloat(size) / master
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.scaleBy(x: scale, y: scale)

    let inset: CGFloat = 34
    let rect = CGRect(x: inset, y: inset, width: master - inset * 2, height: master - inset * 2)
    let radius = rect.width * 0.224
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradientColors: [CGColor]
    switch variant {
    case .normal:
        gradientColors = [color(0.09, 0.33, 0.86), color(0.03, 0.70, 0.70)]
    case .switching:
        gradientColors = [color(0.98, 0.72, 0.24), color(0.98, 0.58, 0.12)]
    }
    let gradient = CGGradient(colorsSpace: space,
                              colors: gradientColors as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])
    let glow = CGGradient(colorsSpace: space,
                          colors: [color(1, 1, 1, 0.22), color(1, 1, 1, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.15),
                           startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.15),
                           endRadius: rect.width * 0.65,
                           options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.addPath(squircle)
    ctx.setStrokeColor(color(0, 0, 0, 0.18))
    ctx.setLineWidth(20)
    ctx.strokePath()
    ctx.restoreGState()

    let leftLaptop = CGPoint(x: rect.minX + rect.width * 0.20, y: rect.minY + rect.height * 0.30)
    let rightLaptop = CGPoint(x: rect.minX + rect.width * 0.80, y: rect.minY + rect.height * 0.30)
    drawLaptop(ctx, center: leftLaptop, width: rect.width * 0.15, alpha: 0.92)
    drawLaptop(ctx, center: rightLaptop, width: rect.width * 0.15, alpha: 0.92)

    let trackWidth = rect.width * 0.54
    let trackHeight = rect.height * 0.19
    let track = CGRect(x: rect.midX - trackWidth / 2,
                       y: rect.minY + rect.height * 0.47,
                       width: trackWidth, height: trackHeight)
    ctx.setFillColor(color(1, 1, 1, 0.90))
    ctx.addPath(CGPath(roundedRect: track, cornerWidth: trackHeight / 2, cornerHeight: trackHeight / 2, transform: nil))
    ctx.fillPath()

    let knobDiameter = trackHeight * 0.78
    let knob = CGRect(x: track.maxX - knobDiameter - trackHeight * 0.11,
                      y: track.midY - knobDiameter / 2,
                      width: knobDiameter, height: knobDiameter)
    ctx.setFillColor(color(1, 1, 1, 1))
    ctx.fillEllipse(in: knob)
    ctx.setFillColor(color(0.05, 0.52, 0.78, 1))
    ctx.fillEllipse(in: knob.insetBy(dx: knobDiameter * 0.30, dy: knobDiameter * 0.30))

    guard let image = ctx.makeImage() else { return nil }
    return image
}

private func drawLaptop(_ ctx: CGContext, center: CGPoint, width: CGFloat, alpha: CGFloat) {
    let screenHeight = width * 0.62
    let screen = CGRect(x: center.x - width / 2,
                        y: center.y - screenHeight / 2 + width * 0.06,
                        width: width, height: screenHeight)
    ctx.setFillColor(color(1, 1, 1, alpha))
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: width * 0.08, cornerHeight: width * 0.08, transform: nil))
    ctx.fillPath()

    let base = CGRect(x: center.x - width * 0.62,
                      y: screen.minY - width * 0.11,
                      width: width * 1.24, height: width * 0.11)
    ctx.addPath(CGPath(roundedRect: base, cornerWidth: width * 0.05, cornerHeight: width * 0.05, transform: nil))
    ctx.fillPath()
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "CGImageDestination fallita"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "scrittura PNG fallita"])
    }
}

private func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "make-icon", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(executable) ha fallito"])
    }
}

private func workDirectory() -> URL {
    let environment = ProcessInfo.processInfo.environment
    let base: String
    if let explicit = environment["SIDECAR_ICON_WORKDIR"], !explicit.isEmpty {
        base = explicit
    } else if let build = environment["BUILD_DIR"], !build.isEmpty {
        base = build
    } else {
        base = "/tmp"
    }
    return URL(fileURLWithPath: base).appendingPathComponent("AppIcon.iconset", isDirectory: true)
}

private func generate(_ output: URL, variant: IconVariant) throws {
    let iconset = workDirectory()
    let manager = FileManager.default
    try? manager.removeItem(at: iconset)
    try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: iconset) }

    let entries: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]
    for (name, size) in entries {
        guard let image = drawIcon(size: size, variant: variant) else {
            throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "render \(size) fallita"])
        }
        try writePNG(image, to: iconset.appendingPathComponent(name))
    }

    try? manager.removeItem(at: output)
    try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output.path])
}

private func rgba1024(_ input: URL, _ output: URL) throws {
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "make-icon", code: 4, userInfo: [NSLocalizedDescriptionKey: "immagine non leggibile"])
    }
    let size = 1024
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "make-icon", code: 5, userInfo: [NSLocalizedDescriptionKey: "contesto RGBA fallito"])
    }
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let data = ctx.data else {
        throw NSError(domain: "make-icon", code: 6, userInfo: [NSLocalizedDescriptionKey: "pixel non disponibili"])
    }
    let buffer = Data(bytes: data, count: size * size * 4)
    try buffer.write(to: output)
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
if arguments.count >= 4, arguments[1] == "--rgba-1024" {
    do {
        try rgba1024(URL(fileURLWithPath: arguments[2]), URL(fileURLWithPath: arguments[3]))
    } catch {
        fail("\(error)")
    }
    exit(0)
}

guard arguments.count >= 2 else {
    fail("usage: make-icon.swift <output.icns> [switching] | --rgba-1024 <input.png> <output.raw>")
}
let variant: IconVariant = arguments.count >= 3 && arguments[2] == "switching" ? .switching : .normal
do {
    try generate(URL(fileURLWithPath: arguments[1]), variant: variant)
} catch {
    fail("\(error)")
}
