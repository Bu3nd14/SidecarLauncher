import AppKit
import XCTest
@testable import SidecarIcon
@testable import SidecarSwitch
@testable import SidecarSwitchCore

final class DockIconPaletteTests: XCTestCase {
    func testK66PaletteAndRestFrameMatrix() {
        XCTAssertEqual(DockIconPalette.knobPosition(for: .lavoro), 1)
        XCTAssertEqual(DockIconPalette.knobPosition(for: .personale), 0)
        XCTAssertEqual(DockIconPalette.knobPosition(for: nil), 0.5)
        XCTAssertEqual(DockIconPalette.letter(for: .lavoro), .w)
        XCTAssertEqual(DockIconPalette.letter(for: .personale), .p)
        XCTAssertNil(DockIconPalette.letter(for: nil))

        let lavoro = DockIconStateMachine.frame(phase: .rest(holder: .lavoro), elapsed: .zero, size: 256)
        XCTAssertEqual(lavoro.request.exposedTop, DockIconPalette.lavoroTop)
        XCTAssertEqual(lavoro.request.exposedBottom, DockIconPalette.lavoroBottom)
        XCTAssertEqual(lavoro.request.knobPosition, 1)
        XCTAssertEqual(lavoro.request.knobRing, .normal)
        XCTAssertEqual(lavoro.request.letter, .w)

        let personale = DockIconStateMachine.frame(phase: .rest(holder: .personale), elapsed: .zero, size: 256)
        XCTAssertEqual(personale.request.exposedTop, DockIconPalette.personaleTop)
        XCTAssertEqual(personale.request.knobPosition, 0)
        XCTAssertEqual(personale.request.letter, .p)

        let neutral = DockIconStateMachine.frame(phase: .rest(holder: nil), elapsed: .zero, size: 256)
        XCTAssertEqual(neutral.request.exposedTop, DockIconPalette.neutralTop)
        XCTAssertEqual(neutral.request.knobPosition, 0.5)
        XCTAssertNil(neutral.request.letter)
    }
}

final class DockIconAssetTests: XCTestCase {
    func testK67NeutralAssetRendersEveryIconsetSize() {
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            let request = DockIconStateMachine.frame(phase: .rest(holder: nil),
                                                     elapsed: .zero,
                                                     size: size).request
            guard let image = IconRenderer.renderCGImage(request) else {
                XCTFail("render neutro \(size) fallita")
                continue
            }
            XCTAssertEqual(image.width, size)
            XCTAssertEqual(image.height, size)
        }
        let sixteen = DockIconStateMachine.frame(phase: .rest(holder: nil), elapsed: .zero, size: 16).request
        let sixteenWithLetter = IconRenderRequest(knobPosition: sixteen.knobPosition,
                                                  exposedTop: sixteen.exposedTop,
                                                  exposedBottom: sixteen.exposedBottom,
                                                  knobRing: sixteen.knobRing,
                                                  letter: .w,
                                                  size: 16)
        guard let first = IconRenderer.renderCGImage(sixteen),
              let second = IconRenderer.renderCGImage(sixteenWithLetter),
              let firstBuffer = PixelBuffer(first),
              let secondBuffer = PixelBuffer(second) else {
            return XCTFail("render 16 fallita")
        }
        XCTAssertEqual(firstBuffer.maxChannelDifference(secondBuffer), 0)
    }
}

@MainActor
final class DockIconControllerK68Tests: XCTestCase {
    func testK68ControllerAppliesRestPulseAndRest() {
        let scheduler = ManualDockIconScheduler()
        let clock = Duration.zero
        var applied: [NSImage] = []
        let controller = DockIconController(dependencies: .init(
            scheduler: scheduler,
            now: { clock },
            reduceMotion: { false },
            applyImage: { applied.append($0) },
            render: { IconRenderer.renderCGImage($0) }
        ))

        controller.showRest(holder: .lavoro)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(scheduler.intervals.count, 0)

        controller.beginTransition(from: .lavoro)
        XCTAssertEqual(scheduler.intervals.count, 1)
        XCTAssertEqual(applied.count, 2)

        controller.finishTransition(TransitionOutcome(state: .failed(nil, .targetFailed),
                                                      persistence: .unchanged,
                                                      actual: nil),
                                    current: .lavoro,
                                    needsReconcile: false)
        XCTAssertTrue(scheduler.handles[0].invalidated)
        XCTAssertEqual(applied.count, 3)
        XCTAssertEqual(scheduler.intervals.count, 1)
        controller.invalidate()
    }
}
