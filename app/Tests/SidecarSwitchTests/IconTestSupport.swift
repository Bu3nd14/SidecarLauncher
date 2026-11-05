import AppKit
import CoreGraphics
import XCTest
@testable import SidecarIcon
@testable import SidecarSwitchCore

enum IconGeometry {
    static let master: Double = 1024
    static let inset: Double = 34
    static let squircleSide: Double = 956
    static let pillWidth: Double = 956 * 0.68
    static let pillHeight: Double = 956 * 0.34
    static let pillMinX: Double = 512 - pillWidth / 2
    static let pillMaxX: Double = 512 + pillWidth / 2
    static let pillMidY: Double = 512
    static let knobDiameter: Double = pillHeight * 0.84
    static let knobRadius: Double = knobDiameter / 2

    static func knobCenterX(position: Double) -> Double {
        pillMinX + knobRadius + position * (pillWidth - 2 * knobRadius)
    }

    static func scale(_ size: Int) -> Double {
        Double(size) / master
    }
}

struct PixelBuffer {
    struct Pixel {
        var r: Double
        var g: Double
        var b: Double
        var a: Double
    }

    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                          count: width * height * 4))
    }

    func pixel(x: Int, yFromBottom: Int) -> Pixel {
        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(yFromBottom, 0), height - 1)
        let row = height - 1 - clampedY
        let offset = (row * width + clampedX) * 4
        return Pixel(r: Double(bytes[offset]) / 255,
                     g: Double(bytes[offset + 1]) / 255,
                     b: Double(bytes[offset + 2]) / 255,
                     a: Double(bytes[offset + 3]) / 255)
    }

    func pixel(masterX: Double, masterY: Double, size: Int) -> Pixel {
        let scale = IconGeometry.scale(size)
        return pixel(x: Int((masterX * scale).rounded()),
                     yFromBottom: Int((masterY * scale).rounded()))
    }

    func whiteCentroid(threshold: Double = 0.85) -> (x: Double, y: Double, count: Int) {
        var sumX = 0.0
        var sumY = 0.0
        var count = 0
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                let r = Double(bytes[offset]) / 255
                let g = Double(bytes[offset + 1]) / 255
                let b = Double(bytes[offset + 2]) / 255
                if r >= threshold && g >= threshold && b >= threshold {
                    sumX += Double(column)
                    sumY += Double(height - 1 - row)
                    count += 1
                }
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (sumX / Double(count), sumY / Double(count), count)
    }

    func maxChannelDifference(_ other: PixelBuffer) -> Int {
        guard width == other.width, height == other.height else { return .max }
        var maximum = 0
        for index in 0..<bytes.count {
            maximum = max(maximum, abs(Int(bytes[index]) - Int(other.bytes[index])))
        }
        return maximum
    }
}

func renderRequest(_ phase: DockIconPhase, elapsed: Duration = .zero, size: Int) -> IconRenderRequest {
    DockIconStateMachine.frame(phase: phase, elapsed: elapsed, size: size).request
}

func rendered(_ request: IconRenderRequest) -> CGImage? {
    IconRenderer.renderCGImage(request)
}

func renderedBuffer(_ request: IconRenderRequest) -> PixelBuffer? {
    rendered(request).flatMap(PixelBuffer.init)
}

func assertColor(_ sampled: PixelBuffer.Pixel,
                 _ expected: IconColor,
                 tolerance: Double = 6.0 / 255.0,
                 file: StaticString = #filePath,
                 line: UInt = #line) {
    XCTAssertEqual(sampled.r, expected.r, accuracy: tolerance, "canale R", file: file, line: line)
    XCTAssertEqual(sampled.g, expected.g, accuracy: tolerance, "canale G", file: file, line: line)
    XCTAssertEqual(sampled.b, expected.b, accuracy: tolerance, "canale B", file: file, line: line)
}

func exposedSampleX(for holder: Holder?) -> Double {
    switch holder {
    case .lavoro?: return IconGeometry.pillMinX + IconGeometry.pillWidth * 0.25
    case .personale?: return IconGeometry.pillMinX + IconGeometry.pillWidth * 0.75
    case nil: return IconGeometry.pillMinX + IconGeometry.pillWidth * 0.25
    }
}

func sampleExposedPair(_ buffer: PixelBuffer, holder: Holder?, size: Int) -> (top: PixelBuffer.Pixel, bottom: PixelBuffer.Pixel) {
    let x = exposedSampleX(for: holder)
    let topY = IconGeometry.pillMidY + IconGeometry.pillHeight * 0.42
    let bottomY = IconGeometry.pillMidY - IconGeometry.pillHeight * 0.42
    return (buffer.pixel(masterX: x, masterY: topY, size: size),
            buffer.pixel(masterX: x, masterY: bottomY, size: size))
}

func cgImageSize(_ image: NSImage) -> (width: Int, height: Int)? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return (cg.width, cg.height)
}

func appliedPixel(_ image: NSImage, masterX: Double, masterY: Double) -> PixelBuffer.Pixel? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let buffer = PixelBuffer(cg) else { return nil }
    return buffer.pixel(masterX: masterX, masterY: masterY, size: IconRenderer.runtimeFrameSize)
}
