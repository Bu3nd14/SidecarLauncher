import AppKit
import CoreGraphics
import Foundation
import SidecarSwitchCore

public enum IconRenderer {
    public static let runtimeFrameSize = 256
    public static let headroomFrameSize = 512
    public static let masterSize: CGFloat = 1024

    public static func renderCGImage(_ request: IconRenderRequest) -> CGImage? {
        let clampedSize = min(max(request.size, 16), 1024)
        assert(request.size >= 16 && request.size <= 1024)
        let side = CGFloat(clampedSize)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: clampedSize,
                                      height: clampedSize,
                                      bitsPerComponent: 8,
                                      bytesPerRow: clampedSize * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.saveGState()
        context.scaleBy(x: side / masterSize, y: side / masterSize)
        draw(request, size: clampedSize, space: space, in: context)
        context.restoreGState()
        return context.makeImage()
    }

    public static func renderNSImage(_ request: IconRenderRequest) -> NSImage? {
        guard let image = renderCGImage(request) else { return nil }
        let points = CGFloat(min(max(request.size, 16), 1024)) / 2
        return NSImage(cgImage: image, size: NSSize(width: points, height: points))
    }

    private static func draw(_ request: IconRenderRequest,
                             size: Int,
                             space: CGColorSpace,
                             in context: CGContext) {
        let inset: CGFloat = 34
        let squircleSide = masterSize - inset * 2
        let squircleRect = CGRect(x: inset, y: inset, width: squircleSide, height: squircleSide)
        let squircleRadius = squircleSide * 0.224
        let squircle = CGPath(roundedRect: squircleRect,
                              cornerWidth: squircleRadius,
                              cornerHeight: squircleRadius,
                              transform: nil)

        context.saveGState()
        context.addPath(squircle)
        context.clip()
        drawGradient(context,
                     space: space,
                     top: DockIconPalette.squircleTop,
                     bottom: DockIconPalette.squircleBottom,
                     rect: squircleRect)
        context.restoreGState()

        let pillWidth = squircleSide * 0.68
        let pillHeight = squircleSide * 0.34
        let pill = CGRect(x: squircleRect.midX - pillWidth / 2,
                          y: squircleRect.midY - pillHeight / 2,
                          width: pillWidth,
                          height: pillHeight)
        let pillPath = CGPath(roundedRect: pill,
                              cornerWidth: pillHeight / 2,
                              cornerHeight: pillHeight / 2,
                              transform: nil)

        context.saveGState()
        context.addPath(pillPath)
        context.clip()
        drawGradient(context,
                     space: space,
                     top: request.exposedTop,
                     bottom: request.exposedBottom,
                     rect: pill)
        context.restoreGState()

        if let letter = request.letter, size >= 32 {
            context.saveGState()
            context.addPath(pillPath)
            context.clip()
            drawLetter(letter, pill: pill, heightFactor: pillHeight, size: size, in: context, space: space)
            context.restoreGState()
        }

        let knobDiameter = pillHeight * 0.84
        let knobRadius = knobDiameter / 2
        let position = min(max(request.knobPosition, 0), 1)
        let knobCenterX = pill.minX + knobRadius + position * (pill.width - 2 * knobRadius)
        let knobCenter = CGPoint(x: knobCenterX, y: pill.midY)
        let knobRect = CGRect(x: knobCenterX - knobRadius,
                              y: pill.midY - knobRadius,
                              width: knobDiameter,
                              height: knobDiameter)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -pillHeight * 0.02),
                          blur: pillHeight * 0.08,
                          color: color(IconColor(r: 0, g: 0, b: 0, a: 0.35), space: space))
        context.setFillColor(color(DockIconPalette.knob, space: space))
        context.fillEllipse(in: knobRect)
        context.restoreGState()

        let emphasis = request.knobRing == .emphasis
        let minimumWidth = masterSize / CGFloat(size)
        let ringWidth = max(pillHeight * 0.84 * 0.012, minimumWidth) * (emphasis ? 1.6 : 1)
        let ringRadius = max(knobRadius - ringWidth / 2, 0)
        context.setStrokeColor(color(DockIconPalette.ring(emphasis: emphasis), space: space))
        context.setLineWidth(ringWidth)
        context.strokeEllipse(in: CGRect(x: knobCenter.x - ringRadius,
                                         y: knobCenter.y - ringRadius,
                                         width: ringRadius * 2,
                                         height: ringRadius * 2))
    }

    private static func drawGradient(_ context: CGContext,
                                     space: CGColorSpace,
                                     top: IconColor,
                                     bottom: IconColor,
                                     rect: CGRect) {
        guard let gradient = CGGradient(colorsSpace: space,
                                        colors: [color(top, space: space), color(bottom, space: space)] as CFArray,
                                        locations: [0, 1]) else {
            return
        }
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY),
                                   options: [])
    }

    private static func drawLetter(_ letter: IconLetter,
                                   pill: CGRect,
                                   heightFactor: CGFloat,
                                   size: Int,
                                   in context: CGContext,
                                   space: CGColorSpace) {
        let letterHeight = heightFactor * 0.48
        let widthFactor: CGFloat = letter == .w ? 1.08 : 0.86
        let letterWidth = letterHeight * widthFactor
        let centerX: CGFloat
        let holder: Holder?
        switch letter {
        case .w:
            centerX = pill.minX + pill.width * 0.25
            holder = .lavoro
        case .p:
            centerX = pill.minX + pill.width * 0.75
            holder = .personale
        }
        let center = CGPoint(x: centerX, y: pill.midY)
        let path = letterPath(letter, center: center, width: letterWidth, height: letterHeight)
        let base = DockIconPalette.exposedTop(for: holder)
        context.setLineWidth(letterHeight * 0.26)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color(base.scaled(1.30), space: space))
        context.saveGState()
        context.translateBy(x: 0, y: -masterSize / CGFloat(size))
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
        context.setStrokeColor(color(base.scaled(0.42), space: space))
        context.addPath(path)
        context.strokePath()
    }

    private static func letterPath(_ letter: IconLetter,
                                   center: CGPoint,
                                   width: CGFloat,
                                   height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let halfWidth = width / 2
        let halfHeight = height / 2
        switch letter {
        case .w:
            path.move(to: CGPoint(x: center.x - halfWidth, y: center.y + halfHeight))
            path.addLine(to: CGPoint(x: center.x - halfWidth * 0.45, y: center.y - halfHeight))
            path.addLine(to: CGPoint(x: center.x, y: center.y + halfHeight * 0.10))
            path.addLine(to: CGPoint(x: center.x + halfWidth * 0.45, y: center.y - halfHeight))
            path.addLine(to: CGPoint(x: center.x + halfWidth, y: center.y + halfHeight))
        case .p:
            path.move(to: CGPoint(x: center.x - halfWidth * 0.70, y: center.y - halfHeight))
            path.addLine(to: CGPoint(x: center.x - halfWidth * 0.70, y: center.y + halfHeight))
            path.addLine(to: CGPoint(x: center.x + halfWidth * 0.15, y: center.y + halfHeight))
            path.addQuadCurve(to: CGPoint(x: center.x + halfWidth * 0.15, y: center.y),
                              control: CGPoint(x: center.x + halfWidth * 1.25,
                                               y: center.y + halfHeight * 0.5))
            path.addLine(to: CGPoint(x: center.x - halfWidth * 0.70, y: center.y))
        }
        return path
    }

    private static func color(_ iconColor: IconColor, space: CGColorSpace) -> CGColor {
        let components: [CGFloat] = [CGFloat(iconColor.r), CGFloat(iconColor.g),
                                     CGFloat(iconColor.b), CGFloat(iconColor.a)]
        return CGColor(colorSpace: space, components: components)
            ?? CGColor(red: CGFloat(iconColor.r), green: CGFloat(iconColor.g),
                       blue: CGFloat(iconColor.b), alpha: CGFloat(iconColor.a))
    }
}
