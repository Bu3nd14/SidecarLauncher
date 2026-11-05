import CoreGraphics
import XCTest
@testable import SidecarIcon
@testable import SidecarSwitchCore

final class IconRendererTests: XCTestCase {
    private let size = 256

    func testK95RestFramesKnobPositionColorsAndLetterNormalization() {
        for holder in [Holder.lavoro, .personale, nil] as [Holder?] {
            let request = renderRequest(.rest(holder: holder), size: size)
            guard let buffer = renderedBuffer(request) else {
                XCTFail("render rest \(String(describing: holder)) fallita")
                continue
            }
            let expectedX = IconGeometry.knobCenterX(position: DockIconPalette.knobPosition(for: holder))
                * IconGeometry.scale(size)
            let centroid = buffer.whiteCentroid()
            XCTAssertGreaterThan(centroid.count, 0)
            XCTAssertEqual(centroid.x, expectedX, accuracy: 2, "centro manopola \(String(describing: holder))")

            let center = buffer.pixel(masterX: IconGeometry.knobCenterX(position: DockIconPalette.knobPosition(for: holder)),
                                      masterY: IconGeometry.pillMidY,
                                      size: size)
            XCTAssertGreaterThan(center.r, 0.9)
            XCTAssertGreaterThan(center.g, 0.9)
            XCTAssertGreaterThan(center.b, 0.9)

            let pair = sampleExposedPair(buffer, holder: holder, size: size)
            assertColor(pair.top, DockIconPalette.exposedTop(for: holder))
            assertColor(pair.bottom, DockIconPalette.exposedBottom(for: holder))
            XCTAssertEqual(request.letter, DockIconPalette.letter(for: holder))
        }

        XCTAssertNil(renderRequest(.rest(holder: nil), size: 16).letter)
        XCTAssertNil(renderRequest(.rest(holder: .lavoro), size: 16).letter)
        XCTAssertEqual(renderRequest(.rest(holder: .lavoro), size: 32).letter, .w)
        XCTAssertEqual(renderRequest(.rest(holder: .personale), size: 32).letter, .p)

        let withoutLetter = IconRenderRequest(knobPosition: 1,
                                              exposedTop: DockIconPalette.lavoroTop,
                                              exposedBottom: DockIconPalette.lavoroBottom,
                                              knobRing: .normal,
                                              letter: nil,
                                              size: 16)
        let withLetter = IconRenderRequest(knobPosition: 1,
                                           exposedTop: DockIconPalette.lavoroTop,
                                           exposedBottom: DockIconPalette.lavoroBottom,
                                           knobRing: .normal,
                                           letter: .w,
                                           size: 16)
        guard let first = renderedBuffer(withoutLetter), let second = renderedBuffer(withLetter) else {
            return XCTFail("render 16 fallita")
        }
        XCTAssertEqual(first.maxChannelDifference(second), 0,
                       "sotto 32 px la lettera deve essere omessa dal renderer")
    }

    func testK95LetterBevelIsVisibleAt256() {
        let cases: [(Holder, ClosedRange<Int>, ClosedRange<Int>)] = [
            (.lavoro, 63...112, 114...124),
            (.personale, 146...190, 192...205)
        ]
        for (holder, letterRange, backgroundRange) in cases {
            let request = renderRequest(.rest(holder: holder), size: size)
            guard let buffer = renderedBuffer(request) else {
                XCTFail("render rest \(holder) fallita")
                continue
            }
            var letterMaximum = 0.0
            var backgroundMaximum = 0.0
            for y in 96..<112 {
                for x in letterRange {
                    letterMaximum = max(letterMaximum, buffer.pixel(x: x, yFromBottom: y).g)
                }
                for x in backgroundRange {
                    backgroundMaximum = max(backgroundMaximum, buffer.pixel(x: x, yFromBottom: y).g)
                }
            }
            XCTAssertGreaterThan(letterMaximum, backgroundMaximum + 0.1,
                                 "bevel chiaro non visibile sul bordo della lettera \(holder)")
        }
    }

    func testK96PulseInterpolatesBothStopsAndKeepsKnobFixed() {
        let pulse = DockIconPhase.pulsing(from: .lavoro)
        let start = renderRequest(pulse, elapsed: .zero, size: size)
        XCTAssertEqual(start.exposedTop, DockIconPalette.lavoroTop)
        XCTAssertEqual(start.exposedBottom, DockIconPalette.lavoroBottom)

        let half = renderRequest(pulse, elapsed: .seconds(1.0 / 3.0), size: size)
        XCTAssertEqual(half.exposedTop.r, DockIconPalette.personaleTop.r, accuracy: 1e-9)
        XCTAssertEqual(half.exposedTop.g, DockIconPalette.personaleTop.g, accuracy: 1e-9)
        XCTAssertEqual(half.exposedBottom.r, DockIconPalette.personaleBottom.r, accuracy: 1e-9)

        let full = renderRequest(pulse, elapsed: .seconds(2.0 / 3.0), size: size)
        XCTAssertEqual(full.exposedTop.r, DockIconPalette.lavoroTop.r, accuracy: 1e-9)
        XCTAssertEqual(full.exposedTop.g, DockIconPalette.lavoroTop.g, accuracy: 1e-9)
        XCTAssertEqual(full.exposedBottom.b, DockIconPalette.lavoroBottom.b, accuracy: 1e-9)

        for elapsed in [Duration.zero, .milliseconds(100), .milliseconds(250), .milliseconds(400)] {
            let request = renderRequest(pulse, elapsed: elapsed, size: size)
            XCTAssertEqual(request.knobPosition, 1, accuracy: 1e-12)
            XCTAssertEqual(request.letter, .w)
            XCTAssertEqual(request.knobRing, .normal)
        }

        guard let first = renderedBuffer(half), let second = renderedBuffer(half) else {
            return XCTFail("render pulse fallita")
        }
        XCTAssertEqual(first.maxChannelDifference(second), 0)
    }

    func testK97SlideDeterminismAndEqualityWithRestTarget() {
        let sliding = DockIconPhase.sliding(from: .personale, to: .lavoro)
        let first = renderRequest(sliding, elapsed: .zero, size: size)
        XCTAssertEqual(first.knobPosition, 0, accuracy: 1e-12)
        XCTAssertEqual(first.exposedTop, DockIconPalette.lavoroTop)
        XCTAssertEqual(first.exposedBottom, DockIconPalette.lavoroBottom)
        XCTAssertEqual(first.letter, .w)

        let middle = renderRequest(sliding, elapsed: .milliseconds(175), size: size)
        XCTAssertEqual(middle.knobPosition, 0.5, accuracy: 1e-9)

        let last = renderRequest(sliding, elapsed: .milliseconds(350), size: size)
        XCTAssertEqual(last.knobPosition, 1, accuracy: 1e-12)
        XCTAssertEqual(last.knobRing, .normal)

        let rest = renderRequest(.rest(holder: .lavoro), size: size)
        guard let lastBuffer = renderedBuffer(last), let restBuffer = renderedBuffer(rest) else {
            return XCTFail("render slide/rest fallita")
        }
        XCTAssertLessThanOrEqual(lastBuffer.maxChannelDifference(restBuffer), 2)
    }

    func testK99StaticSwitchingFrameIsAmberWithEmphasisRing() {
        let request = renderRequest(.staticSwitching(from: .personale), size: size)
        XCTAssertEqual(request.knobPosition, 0)
        XCTAssertEqual(request.exposedTop, DockIconPalette.busyTop)
        XCTAssertEqual(request.exposedBottom, DockIconPalette.busyBottom)
        XCTAssertEqual(request.knobRing, .emphasis)
        XCTAssertEqual(request.letter, .p)
        XCTAssertNil(renderRequest(.staticSwitching(from: .personale), size: 16).letter)
    }

    func testK104SixteenPixelKnobCentroidAndTint() {
        let pixelSize = 16
        let scale = IconGeometry.scale(pixelSize)
        let states: [(Holder?, Double)] = [(.lavoro, 1), (.personale, 0), (nil, 0.5)]
        for (holder, position) in states {
            let request = renderRequest(.rest(holder: holder), size: pixelSize)
            guard let buffer = renderedBuffer(request) else {
                XCTFail("render 16 fallita")
                continue
            }
            let expectedX = IconGeometry.knobCenterX(position: position) * scale
            let centroid = buffer.whiteCentroid(threshold: 0.8)
            XCTAssertGreaterThan(centroid.count, 0)
            XCTAssertEqual(centroid.x, expectedX, accuracy: 1,
                           "centroide manopola 16 px \(String(describing: holder))")
            switch holder {
            case .personale?:
                XCTAssertLessThan(centroid.x, Double(pixelSize) / 2 - 0.5)
            case .lavoro?:
                XCTAssertGreaterThan(centroid.x, Double(pixelSize) / 2 + 0.5)
            case nil:
                XCTAssertEqual(centroid.x, Double(pixelSize) / 2, accuracy: 1.5)
            }
        }

        let lavoro = renderedBuffer(renderRequest(.rest(holder: .lavoro), size: pixelSize))!
        let lavoroPixel = lavoro.pixel(masterX: exposedSampleX(for: .lavoro),
                                       masterY: IconGeometry.pillMidY,
                                       size: pixelSize)
        XCTAssertGreaterThan(lavoroPixel.g, lavoroPixel.r)

        let personale = renderedBuffer(renderRequest(.rest(holder: .personale), size: pixelSize))!
        let personalePixel = personale.pixel(masterX: exposedSampleX(for: .personale),
                                             masterY: IconGeometry.pillMidY,
                                             size: pixelSize)
        XCTAssertGreaterThan(personalePixel.r, personalePixel.g)

        let busy = renderedBuffer(renderRequest(.staticSwitching(from: .personale), size: pixelSize))!
        let busyPixel = busy.pixel(masterX: exposedSampleX(for: .personale),
                                   masterY: IconGeometry.pillMidY,
                                   size: pixelSize)
        XCTAssertGreaterThan(busyPixel.r, busyPixel.g)
    }

    func testK105BusyVersusPersonaleMinimumDeltaE() {
        let minimum = Self.minimumDeltaE(busyTop: DockIconPalette.busyTop,
                                         busyBottom: DockIconPalette.busyBottom,
                                         personaleTop: DockIconPalette.personaleTop,
                                         personaleBottom: DockIconPalette.personaleBottom)
        XCTAssertGreaterThanOrEqual(minimum, 4.5)
    }

    private static func minimumDeltaE(busyTop: IconColor,
                                      busyBottom: IconColor,
                                      personaleTop: IconColor,
                                      personaleBottom: IconColor) -> Double {
        var minimum = Double.infinity
        for row in 0..<5 {
            for column in 0..<5 {
                let busy = linearGradient(busyTop, busyBottom, Double(row) / 4)
                let personale = linearGradient(personaleTop, personaleBottom, Double(column) / 4)
                minimum = min(minimum, deltaE00(lab(busy), lab(personale)))
            }
        }
        return minimum
    }

    private static func linearGradient(_ top: IconColor, _ bottom: IconColor, _ t: Double) -> IconColor {
        IconColor(r: top.r + (bottom.r - top.r) * t,
                  g: top.g + (bottom.g - top.g) * t,
                  b: top.b + (bottom.b - top.b) * t)
    }

    private static func lab(_ color: IconColor) -> (Double, Double, Double) {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear(color.r)
        let g = linear(color.g)
        let b = linear(color.b)
        let x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375
        let y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
        let z = r * 0.0193339 + g * 0.1191920 + b * 0.9503041
        let xn = 0.95047
        let yn = 1.0
        let zn = 1.08883
        func f(_ t: Double) -> Double {
            t > 216.0 / 24389.0 ? pow(t, 1.0 / 3.0) : (24389.0 / 27.0 * t + 16) / 116
        }
        let fx = f(x / xn)
        let fy = f(y / yn)
        let fz = f(z / zn)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    private static func deltaE00(_ first: (Double, Double, Double),
                                 _ second: (Double, Double, Double)) -> Double {
        let (l1, a1, b1) = first
        let (l2, a2, b2) = second
        let c1 = hypot(a1, b1)
        let c2 = hypot(a2, b2)
        let averageC = (c1 + c2) / 2
        let g = 0.5 * (1 - sqrt(pow(averageC, 7) / (pow(averageC, 7) + pow(25, 7))))
        let a1p = (1 + g) * a1
        let a2p = (1 + g) * a2
        let c1p = hypot(a1p, b1)
        let c2p = hypot(a2p, b2)
        let h1p = atan2(b1, a1p) * 180 / .pi
        let h2p = atan2(b2, a2p) * 180 / .pi
        let h1 = h1p >= 0 ? h1p : h1p + 360
        let h2 = h2p >= 0 ? h2p : h2p + 360
        let deltaL = l2 - l1
        let deltaC = c2p - c1p
        var deltaHAngle = 0.0
        if c1p * c2p != 0 {
            deltaHAngle = h2 - h1
            if deltaHAngle > 180 { deltaHAngle -= 360 }
            if deltaHAngle < -180 { deltaHAngle += 360 }
        }
        let deltaH = 2 * sqrt(c1p * c2p) * sin(deltaHAngle * .pi / 360)
        let averageL = (l1 + l2) / 2
        let averageCp = (c1p + c2p) / 2
        var averageH = h1 + h2
        if c1p * c2p != 0 {
            if abs(h1 - h2) <= 180 {
                averageH = (h1 + h2) / 2
            } else if h1 + h2 < 360 {
                averageH = (h1 + h2 + 360) / 2
            } else {
                averageH = (h1 + h2 - 360) / 2
            }
        }
        let t = 1 - 0.17 * cos((averageH - 30) * .pi / 180)
            + 0.24 * cos(2 * averageH * .pi / 180)
            + 0.32 * cos((3 * averageH + 6) * .pi / 180)
            - 0.20 * cos((4 * averageH - 63) * .pi / 180)
        let deltaTheta = 30 * exp(-pow((averageH - 275) / 25, 2))
        let rc = 2 * sqrt(pow(averageCp, 7) / (pow(averageCp, 7) + pow(25, 7)))
        let sl = 1 + 0.015 * pow(averageL - 50, 2) / sqrt(20 + pow(averageL - 50, 2))
        let sc = 1 + 0.045 * averageCp
        let sh = 1 + 0.015 * averageCp * t
        let rt = -sin(2 * deltaTheta * .pi / 180) * rc
        return sqrt(pow(deltaL / sl, 2)
                    + pow(deltaC / sc, 2)
                    + pow(deltaH / sh, 2)
                    + rt * (deltaC / sc) * (deltaH / sh))
    }
}
