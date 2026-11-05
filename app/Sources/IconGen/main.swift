import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SidecarIcon
import SidecarSwitchCore

private let entries: [(String, Int)] = [
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

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("IconGen: \(message)\n".utf8))
    exit(1)
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "IconGen", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "CGImageDestination fallita"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "IconGen", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "scrittura PNG fallita"])
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
        throw NSError(domain: "IconGen", code: Int(process.terminationStatus),
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

private func generate(_ output: URL) throws {
    let iconset = workDirectory()
    let manager = FileManager.default
    try? manager.removeItem(at: iconset)
    try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: iconset) }

    for (name, size) in entries {
        let request = DockIconStateMachine.frame(phase: .rest(holder: nil), elapsed: .zero, size: size).request
        guard let image = IconRenderer.renderCGImage(request) else {
            throw NSError(domain: "IconGen", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "render \(size) fallita"])
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
        throw NSError(domain: "IconGen", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "immagine non leggibile"])
    }
    let size = 1024
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "IconGen", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "contesto RGBA fallito"])
    }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let data = context.data else {
        throw NSError(domain: "IconGen", code: 6,
                      userInfo: [NSLocalizedDescriptionKey: "pixel non disponibili"])
    }
    try Data(bytes: data, count: size * size * 4).write(to: output)
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
    fail("usage: IconGen <output.icns> | --rgba-1024 <input.png> <output.raw>")
}
do {
    try generate(URL(fileURLWithPath: arguments[1]))
} catch {
    fail("\(error)")
}
