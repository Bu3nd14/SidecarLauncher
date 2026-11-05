import AppKit
import XCTest
@testable import SidecarIcon
@testable import SidecarSwitch
@testable import SidecarSwitchCore

@MainActor
final class ManualDockIconScheduler: DockIconScheduler {
    private(set) var intervals: [Duration] = []
    private(set) var handlers: [@MainActor () -> Void] = []
    private(set) var handles: [ManualDockIconHandle] = []

    func schedule(interval: Duration, handler: @escaping @MainActor () -> Void) -> DockIconScheduleHandle {
        intervals.append(interval)
        handlers.append(handler)
        let handle = ManualDockIconHandle()
        handles.append(handle)
        return handle
    }

    func fire(_ index: Int) {
        guard index < handlers.count else { return }
        handlers[index]()
    }
}

final class ManualDockIconHandle: DockIconScheduleHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var invalidatedFlag = false

    var invalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidatedFlag
    }

    nonisolated func invalidate() {
        lock.lock()
        invalidatedFlag = true
        lock.unlock()
    }
}

@MainActor
final class DockIconControllerTests: XCTestCase {
    private func done(_ holder: Holder) -> TransitionOutcome {
        TransitionOutcome(state: .done(holder), persistence: .success(holder.location), actual: holder.location)
    }

    private func failure(_ reason: Reason) -> TransitionOutcome {
        TransitionOutcome(state: .failed(nil, reason), persistence: .unchanged, actual: nil)
    }

    private func makeController(scheduler: ManualDockIconScheduler,
                                now: @escaping () -> Duration,
                                reduceMotion: @escaping () -> Bool = { false },
                                applied: @escaping (NSImage) -> Void,
                                requests: @escaping (IconRenderRequest) -> Void = { _ in },
                                render: @escaping (IconRenderRequest) -> CGImage? = {
                                    IconRenderer.renderCGImage($0)
                                }) -> DockIconController {
        DockIconController(dependencies: .init(
            scheduler: scheduler,
            now: now,
            reduceMotion: reduceMotion,
            applyImage: applied,
            render: { request in
                requests(request)
                return render(request)
            }
        ))
    }

    func testK98TimerStopsOnEveryOutcomeAndGenerationCounter() {
        let scheduler = ManualDockIconScheduler()
        var clock = Duration.zero
        var applied: [NSImage] = []
        let controller = makeController(scheduler: scheduler,
                                        now: { clock },
                                        applied: { applied.append($0) })

        controller.showRest(holder: .personale)
        XCTAssertEqual(applied.count, 1)
        controller.beginTransition(from: .personale)
        XCTAssertEqual(scheduler.intervals.count, 1)
        XCTAssertEqual(applied.count, 2)

        clock += .milliseconds(200)
        scheduler.fire(0)
        XCTAssertEqual(applied.count, 3)

        controller.finishTransition(done(.lavoro), current: .personale, needsReconcile: false)
        XCTAssertEqual(scheduler.intervals.count, 2)
        XCTAssertTrue(scheduler.handles[0].invalidated)
        let afterFinish = applied.count

        scheduler.fire(0)
        XCTAssertEqual(applied.count, afterFinish, "tick in coda della fase pulse scartato")

        clock += .milliseconds(400)
        scheduler.fire(1)
        XCTAssertEqual(applied.count, afterFinish + 1)
        XCTAssertTrue(scheduler.handles[1].invalidated)
        let afterRest = applied.count

        scheduler.fire(1)
        XCTAssertEqual(applied.count, afterRest, "tick in coda della fase slide scartato")

        for image in applied {
            XCTAssertEqual(cgImageSize(image)?.width, IconRenderer.runtimeFrameSize)
            XCTAssertEqual(cgImageSize(image)?.height, IconRenderer.runtimeFrameSize)
        }
        controller.invalidate()
    }

    func testK98LazySlidePrecomputeDuringPulseAndNoRenderOnDone() {
        let scheduler = ManualDockIconScheduler()
        var clock = Duration.zero
        var applied: [NSImage] = []
        var renderCalls = 0
        let controller = makeController(scheduler: scheduler,
                                        now: { clock },
                                        applied: { applied.append($0) },
                                        render: { request in
                                            renderCalls += 1
                                            return IconRenderer.renderCGImage(request)
                                        })
        controller.showRest(holder: .personale)
        let restCalls = renderCalls
        let start = ContinuousClock.now
        controller.beginTransition(from: .personale)
        let beginElapsed = ContinuousClock.now - start
        let beginCalls = renderCalls
        XCTAssertEqual(beginCalls - restCalls, DockIconStateMachine.pulseFrameCount)
        XCTAssertLessThanOrEqual(beginElapsed, .milliseconds(16))

        for _ in 0..<30 {
            clock += .milliseconds(100)
            scheduler.fire(0)
        }
        XCTAssertEqual(renderCalls - beginCalls, DockIconStateMachine.slideFrameCount * 2)
        let cachedCalls = renderCalls

        controller.finishTransition(done(.lavoro), current: .personale, needsReconcile: false)
        XCTAssertEqual(renderCalls, cachedCalls)
        XCTAssertEqual(scheduler.intervals.count, 2)
        XCTAssertTrue(scheduler.handles[0].invalidated)
        XCTAssertFalse(scheduler.handles[1].invalidated)
        XCTAssertFalse(applied.isEmpty)
        controller.invalidate()
    }

    func testK98FallbackRendersMissingSlidesOnEarlyDone() {
        let scheduler = ManualDockIconScheduler()
        var clock = Duration.zero
        var applied: [NSImage] = []
        var renderCalls = 0
        let controller = makeController(scheduler: scheduler,
                                        now: { clock },
                                        applied: { applied.append($0) },
                                        render: { request in
                                            renderCalls += 1
                                            return IconRenderer.renderCGImage(request)
                                        })
        controller.beginTransition(from: .personale)
        let beginCalls = renderCalls
        clock += .milliseconds(100)
        scheduler.fire(0)
        let afterTick = renderCalls
        XCTAssertEqual(afterTick - beginCalls, 2)
        controller.finishTransition(done(.lavoro), current: .personale, needsReconcile: false)
        XCTAssertEqual(renderCalls - afterTick, DockIconStateMachine.slideFrameCount - 2)
        XCTAssertFalse(applied.isEmpty)
        controller.invalidate()
    }

    func testK98EveryOutcomeStopsTimerAndAppliesResolvedRest() {
        let scenarios: [(TransitionOutcome, Bool, Double, IconColor)] = [
            (failure(.targetFailed), false, 1, DockIconPalette.lavoroTop),
            (failure(.cancelled), false, 1, DockIconPalette.lavoroTop),
            (failure(.incoherent), true, 0.5, DockIconPalette.neutralTop),
            (failure(.unknownHolder), false, 0.5, DockIconPalette.neutralTop)
        ]
        for (outcome, needsReconcile, knob, top) in scenarios {
            let scheduler = ManualDockIconScheduler()
            var clock = Duration.zero
            var applied: [NSImage] = []
            var requests: [IconRenderRequest] = []
            let controller = makeController(scheduler: scheduler,
                                            now: { clock },
                                            applied: { applied.append($0) },
                                            requests: { requests.append($0) })
            controller.beginTransition(from: .lavoro)
            XCTAssertEqual(scheduler.intervals.count, 1)
            controller.finishTransition(outcome, current: .lavoro, needsReconcile: needsReconcile)
            XCTAssertTrue(scheduler.handles[0].invalidated)
            let settled = applied.count
            clock += .milliseconds(500)
            scheduler.fire(0)
            XCTAssertEqual(applied.count, settled)
            XCTAssertEqual(requests.last?.knobPosition, knob)
            XCTAssertEqual(requests.last?.exposedTop, top)
            XCTAssertEqual(scheduler.intervals.count, 1, "nessun nuovo timer dopo l'esito")
            controller.invalidate()
        }
    }

    func testK99ReduceMotionUsesStaticAmberWithoutTimer() {
        let scheduler = ManualDockIconScheduler()
        let clock = Duration.zero
        var applied: [NSImage] = []
        var requests: [IconRenderRequest] = []
        let controller = makeController(scheduler: scheduler,
                                        now: { clock },
                                        reduceMotion: { true },
                                        applied: { applied.append($0) },
                                        requests: { requests.append($0) })

        controller.beginTransition(from: .personale)
        XCTAssertEqual(scheduler.intervals.count, 0)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(requests.last?.exposedTop, DockIconPalette.busyTop)
        XCTAssertEqual(requests.last?.exposedBottom, DockIconPalette.busyBottom)
        XCTAssertEqual(requests.last?.knobRing, .emphasis)
        XCTAssertEqual(requests.last?.knobPosition, 0)
        XCTAssertEqual(requests.last?.letter, .p)
        XCTAssertEqual(cgImageSize(applied[0])?.width, 256)

        controller.finishTransition(done(.lavoro), current: .personale, needsReconcile: false)
        XCTAssertEqual(scheduler.intervals.count, 0)
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(requests.last?.exposedTop, DockIconPalette.lavoroTop)
        XCTAssertEqual(requests.last?.knobPosition, 1)
        XCTAssertEqual(requests.last?.knobRing, .normal)
        XCTAssertTrue(applied.allSatisfy { cgImageSize($0)?.width == 256 })
        controller.invalidate()
    }

    func testK100RenderFailureKeepsLastFrameAndNeverAppliesNil() {
        let scheduler = ManualDockIconScheduler()
        let clock = Duration.zero
        var applied: [NSImage] = []
        var renderCalls = 0
        let controller = makeController(scheduler: scheduler,
                                        now: { clock },
                                        applied: { applied.append($0) },
                                        render: { _ in
                                            renderCalls += 1
                                            return nil
                                        })
        controller.showRest(holder: .personale)
        controller.beginTransition(from: .personale)
        controller.finishTransition(done(.lavoro), current: .personale, needsReconcile: false)
        XCTAssertGreaterThan(renderCalls, 0)
        XCTAssertTrue(applied.isEmpty)
        controller.invalidate()
    }

    func testK102AbortAppliesRestAndInvalidatesTimer() {
        let scheduler = ManualDockIconScheduler()
        var clock = Duration.zero
        var applied: [NSImage] = []
        var requests: [IconRenderRequest] = []
        let controller = makeController(scheduler: scheduler,
                                        now: { clock },
                                        applied: { applied.append($0) },
                                        requests: { requests.append($0) })
        controller.beginTransition(from: .personale)
        XCTAssertEqual(scheduler.intervals.count, 1)
        controller.showRest(holder: .personale)
        XCTAssertTrue(scheduler.handles[0].invalidated)
        XCTAssertEqual(requests.last?.exposedTop, DockIconPalette.personaleTop)
        XCTAssertEqual(requests.last?.knobPosition, 0)
        let count = applied.count
        clock += .milliseconds(300)
        scheduler.fire(0)
        XCTAssertEqual(applied.count, count)
        controller.invalidate()
    }

    func testK102AppModelPassesRealOutcomeAndAbort() throws {
        let home = try makeTempDirectory("dock-icon-model-k102")
        defer { try? FileManager.default.removeItem(at: home) }
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.disconnected(), Fixtures.disconnected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])

        let scheduler = ManualDockIconScheduler()
        let clock = Duration.zero
        var requests: [IconRenderRequest] = []
        var applied: [NSImage] = []
        let controller = makeController(scheduler: scheduler,
                                        now: { clock },
                                        applied: { applied.append($0) },
                                        requests: { requests.append($0) })
        let model = AppModel(paths: AppPaths(home: home),
                             logURL: home.appendingPathComponent("log.txt"),
                             resourcesDirectory: nil,
                             bundledToolsVersion: "test",
                             operationsFactory: { _ in ops },
                             timings: .fast,
                             dockIconController: controller)

        model.handle(done(.lavoro))
        XCTAssertEqual(requests.last?.exposedTop, DockIconPalette.lavoroTop)
        XCTAssertEqual(requests.last?.knobPosition, 1)

        model.handle(TransitionOutcome(state: .failed(nil, .incoherent),
                                       persistence: PersistencePlan(needsReconcile: true),
                                       actual: nil))
        XCTAssertEqual(model.actual, .unknown)
        XCTAssertEqual(requests.last?.exposedTop, DockIconPalette.neutralTop)
        XCTAssertNil(requests.last?.letter)

        model.handle(done(.personale))
        XCTAssertEqual(requests.last?.knobPosition, 0)
        XCTAssertEqual(scheduler.intervals.count, 0)

        model.toggle(.lavoro)
        XCTAssertEqual(scheduler.intervals.count, 1)
        model.handle(nil)
        XCTAssertTrue(scheduler.handles[0].invalidated)
        guard let last = applied.last else {
            return XCTFail("nessuna immagine applicata dopo l'abort")
        }
        let exposed = appliedPixel(last,
                                   masterX: exposedSampleX(for: .personale),
                                   masterY: IconGeometry.pillMidY + IconGeometry.pillHeight * 0.42)
        XCTAssertEqual(exposed?.r ?? -1, DockIconPalette.personaleTop.r, accuracy: 6.0 / 255.0)
        XCTAssertEqual(exposed?.g ?? -1, DockIconPalette.personaleTop.g, accuracy: 6.0 / 255.0)
        let knob = appliedPixel(last,
                                masterX: IconGeometry.knobCenterX(position: 0),
                                masterY: IconGeometry.pillMidY)
        XCTAssertGreaterThan(knob?.g ?? 0, 0.9)
        XCTAssertTrue(applied.allSatisfy { cgImageSize($0)?.width == IconRenderer.runtimeFrameSize })
    }

    func testK102LazySlidePrecomputeMeansDoneHasNoRender() throws {
        let home = try makeTempDirectory("dock-icon-model-lazy-k102")
        defer { try? FileManager.default.removeItem(at: home) }
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])

        let scheduler = ManualDockIconScheduler()
        var clock = Duration.zero
        var renderCalls = 0
        var applied: [NSImage] = []
        let controller = makeController(scheduler: scheduler,
                                        now: { clock },
                                        applied: { applied.append($0) },
                                        render: { request in
                                            renderCalls += 1
                                            return IconRenderer.renderCGImage(request)
                                        })
        let model = AppModel(paths: AppPaths(home: home),
                             logURL: home.appendingPathComponent("log.txt"),
                             resourcesDirectory: nil,
                             bundledToolsVersion: "test",
                             operationsFactory: { _ in ops },
                             timings: .fast,
                             dockIconController: controller)

        model.handle(done(.personale))
        model.toggle(.lavoro)
        XCTAssertEqual(scheduler.intervals.count, 1)
        for _ in 0..<30 {
            clock += .milliseconds(100)
            scheduler.fire(0)
        }
        let cachedCalls = renderCalls
        model.handle(done(.lavoro))
        XCTAssertEqual(renderCalls, cachedCalls)
        XCTAssertEqual(scheduler.intervals.count, 2)
        XCTAssertFalse(applied.isEmpty)
        XCTAssertTrue(applied.allSatisfy { cgImageSize($0)?.width == IconRenderer.runtimeFrameSize })
        controller.invalidate()
    }

    func testK102StartAppliesRestFromActual() async throws {
        let home = try makeTempDirectory("dock-icon-model-start")
        defer { try? FileManager.default.removeItem(at: home) }
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])

        let scheduler = ManualDockIconScheduler()
        let clock = Duration.zero
        var requests: [IconRenderRequest] = []
        var applied: [NSImage] = []
        let controller = makeController(scheduler: scheduler,
                                        now: { clock },
                                        applied: { applied.append($0) },
                                        requests: { requests.append($0) })
        let model = AppModel(paths: AppPaths(home: home),
                             logURL: home.appendingPathComponent("log.txt"),
                             resourcesDirectory: nil,
                             bundledToolsVersion: "test",
                             operationsFactory: { _ in ops },
                             timings: .fast,
                             dockIconController: controller)

        await model.start()

        XCTAssertEqual(model.actual, .nowhere)
        XCTAssertEqual(requests.last?.exposedTop, DockIconPalette.neutralTop)
        XCTAssertNil(requests.last?.letter)
        XCTAssertEqual(scheduler.intervals.count, 0)
        XCTAssertFalse(applied.isEmpty)
        XCTAssertTrue(applied.allSatisfy { cgImageSize($0)?.width == IconRenderer.runtimeFrameSize })
        controller.invalidate()
    }
}
