import XCTest
@testable import SidecarSwitchCore

final class DockIconStateMachineTests: XCTestCase {
    private enum Event {
        case begin(Holder?)
        case done(TransitionOutcome)
        case fail(TransitionOutcome)
        case tick(Duration)
        case showRest(Holder?)
    }

    private struct Cell {
        var id: Int
        var phase: DockIconPhase
        var event: Event
        var reduceMotion: Bool
        var expected: DockIconPhase
        var settle: DockIconPhase?
    }

    private let source: Holder = .personale
    private let target: Holder = .lavoro
    private let other: Holder = .lavoro
    private let current: Location = .personale

    private var doneOutcome: TransitionOutcome {
        TransitionOutcome(state: .done(target), persistence: .success(target.location), actual: target.location)
    }

    private var failOutcome: TransitionOutcome {
        TransitionOutcome(state: .failed(nil, .targetFailed), persistence: .unchanged, actual: nil)
    }

    private func step(phase: DockIconPhase, event: Event, reduceMotion: Bool) -> DockIconStep {
        switch event {
        case .begin(let from):
            return DockIconStateMachine.begin(phase: phase, from: from, reduceMotion: reduceMotion)
        case .done(let outcome), .fail(let outcome):
            return DockIconStateMachine.onOutcome(outcome,
                                                  phase: phase,
                                                  current: current,
                                                  needsReconcile: false,
                                                  reduceMotionCaptured: reduceMotion)
        case .tick(let elapsed):
            return DockIconStateMachine.tick(phase: phase,
                                             elapsed: elapsed,
                                             reduceMotionCaptured: reduceMotion)
        case .showRest(let holder):
            return DockIconStateMachine.showRest(holder: holder)
        }
    }

    private func cells() -> [Cell] {
        let rest = DockIconPhase.rest(holder: source)
        let pulsing = DockIconPhase.pulsing(from: source)
        let staticSwitching = DockIconPhase.staticSwitching(from: source)
        let sliding = DockIconPhase.sliding(from: source, to: target)
        let restTarget = DockIconPhase.rest(holder: target)
        let restSource = DockIconPhase.rest(holder: source)
        let pulsingOther = DockIconPhase.pulsing(from: other)
        let staticOther = DockIconPhase.staticSwitching(from: other)
        let midSlide = Duration.milliseconds(100)

        return [
            Cell(id: 1, phase: rest, event: .begin(other), reduceMotion: false,
                 expected: pulsingOther, settle: nil),
            Cell(id: 2, phase: rest, event: .begin(other), reduceMotion: true,
                 expected: staticOther, settle: nil),
            Cell(id: 3, phase: rest, event: .done(doneOutcome), reduceMotion: false,
                 expected: restTarget, settle: nil),
            Cell(id: 4, phase: rest, event: .done(doneOutcome), reduceMotion: true,
                 expected: restTarget, settle: nil),
            Cell(id: 5, phase: rest, event: .fail(failOutcome), reduceMotion: false,
                 expected: restSource, settle: nil),
            Cell(id: 6, phase: rest, event: .fail(failOutcome), reduceMotion: true,
                 expected: restSource, settle: nil),
            Cell(id: 7, phase: rest, event: .tick(midSlide), reduceMotion: false,
                 expected: restSource, settle: nil),
            Cell(id: 8, phase: rest, event: .tick(midSlide), reduceMotion: true,
                 expected: restSource, settle: nil),
            Cell(id: 9, phase: rest, event: .showRest(target), reduceMotion: false,
                 expected: restTarget, settle: nil),
            Cell(id: 10, phase: rest, event: .showRest(target), reduceMotion: true,
                 expected: restTarget, settle: nil),

            Cell(id: 11, phase: pulsing, event: .begin(other), reduceMotion: false,
                 expected: pulsingOther, settle: nil),
            Cell(id: 12, phase: pulsing, event: .begin(other), reduceMotion: true,
                 expected: staticOther, settle: nil),
            Cell(id: 13, phase: pulsing, event: .done(doneOutcome), reduceMotion: false,
                 expected: sliding, settle: nil),
            Cell(id: 14, phase: pulsing, event: .done(doneOutcome), reduceMotion: true,
                 expected: restTarget, settle: nil),
            Cell(id: 15, phase: pulsing, event: .fail(failOutcome), reduceMotion: false,
                 expected: restSource, settle: nil),
            Cell(id: 16, phase: pulsing, event: .fail(failOutcome), reduceMotion: true,
                 expected: restSource, settle: nil),
            Cell(id: 17, phase: pulsing, event: .tick(midSlide), reduceMotion: false,
                 expected: pulsing, settle: nil),
            Cell(id: 18, phase: pulsing, event: .tick(midSlide), reduceMotion: true,
                 expected: pulsing, settle: nil),
            Cell(id: 19, phase: pulsing, event: .showRest(target), reduceMotion: false,
                 expected: restTarget, settle: nil),
            Cell(id: 20, phase: pulsing, event: .showRest(source), reduceMotion: true,
                 expected: restSource, settle: nil),

            Cell(id: 21, phase: staticSwitching, event: .begin(other), reduceMotion: false,
                 expected: staticOther, settle: nil),
            Cell(id: 22, phase: staticSwitching, event: .begin(other), reduceMotion: true,
                 expected: staticOther, settle: nil),
            Cell(id: 23, phase: staticSwitching, event: .done(doneOutcome), reduceMotion: false,
                 expected: restTarget, settle: nil),
            Cell(id: 24, phase: staticSwitching, event: .done(doneOutcome), reduceMotion: true,
                 expected: restTarget, settle: nil),
            Cell(id: 25, phase: staticSwitching, event: .fail(failOutcome), reduceMotion: false,
                 expected: restSource, settle: nil),
            Cell(id: 26, phase: staticSwitching, event: .fail(failOutcome), reduceMotion: true,
                 expected: restSource, settle: nil),
            Cell(id: 27, phase: staticSwitching, event: .tick(midSlide), reduceMotion: false,
                 expected: staticSwitching, settle: nil),
            Cell(id: 28, phase: staticSwitching, event: .tick(midSlide), reduceMotion: true,
                 expected: staticSwitching, settle: nil),
            Cell(id: 29, phase: staticSwitching, event: .showRest(target), reduceMotion: false,
                 expected: restTarget, settle: nil),
            Cell(id: 30, phase: staticSwitching, event: .showRest(source), reduceMotion: true,
                 expected: restSource, settle: nil),

            Cell(id: 31, phase: sliding, event: .begin(other), reduceMotion: false,
                 expected: pulsingOther, settle: restTarget),
            Cell(id: 32, phase: sliding, event: .begin(other), reduceMotion: true,
                 expected: staticOther, settle: restTarget),
            Cell(id: 33, phase: sliding, event: .done(doneOutcome), reduceMotion: false,
                 expected: restTarget, settle: nil),
            Cell(id: 34, phase: sliding, event: .done(doneOutcome), reduceMotion: true,
                 expected: restTarget, settle: nil),
            Cell(id: 35, phase: sliding, event: .fail(failOutcome), reduceMotion: false,
                 expected: restSource, settle: nil),
            Cell(id: 36, phase: sliding, event: .fail(failOutcome), reduceMotion: true,
                 expected: restSource, settle: nil),
            Cell(id: 37, phase: sliding, event: .tick(midSlide), reduceMotion: false,
                 expected: sliding, settle: nil),
            Cell(id: 38, phase: sliding, event: .tick(midSlide), reduceMotion: true,
                 expected: restTarget, settle: nil),
            Cell(id: 39, phase: sliding, event: .showRest(target), reduceMotion: false,
                 expected: restTarget, settle: nil),
            Cell(id: 40, phase: sliding, event: .showRest(source), reduceMotion: true,
                 expected: restSource, settle: nil)
        ]
    }

    func testK94MatrixIsTotalWithFortyCells() {
        let table = cells()
        XCTAssertEqual(table.count, 40)
        XCTAssertEqual(Set(table.map(\.id)).count, 40)
        for cell in table {
            let result = step(phase: cell.phase, event: cell.event, reduceMotion: cell.reduceMotion)
            XCTAssertEqual(result.next, cell.expected, "cella \(cell.id)")
            XCTAssertEqual(result.settle, cell.settle, "cella \(cell.id)")
        }
    }

    func testK94SlideEndAndSameHolderDoneAndDefensiveCells() {
        let sliding = DockIconPhase.sliding(from: source, to: target)
        let end = DockIconStateMachine.tick(phase: sliding,
                                            elapsed: .milliseconds(350),
                                            reduceMotionCaptured: false)
        XCTAssertEqual(end.next, .rest(holder: target))

        let sameHolderDone = DockIconStateMachine.onOutcome(
            TransitionOutcome(state: .done(source), persistence: .success(source.location), actual: source.location),
            phase: .pulsing(from: source),
            current: current,
            needsReconcile: false,
            reduceMotionCaptured: false
        )
        XCTAssertEqual(sameHolderDone.next, .rest(holder: source))
        XCTAssertNil(sameHolderDone.settle)

        let defensivePulsingTick = DockIconStateMachine.tick(phase: .pulsing(from: source),
                                                            elapsed: .milliseconds(100),
                                                            reduceMotionCaptured: true)
        XCTAssertEqual(defensivePulsingTick.next, .pulsing(from: source))

        let defensiveStaticDone = DockIconStateMachine.onOutcome(
            doneOutcome,
            phase: .staticSwitching(from: source),
            current: current,
            needsReconcile: false,
            reduceMotionCaptured: false
        )
        XCTAssertEqual(defensiveStaticDone.next, .rest(holder: target))
        XCTAssertNil(defensiveStaticDone.settle)

        let defensiveSlidingTick = DockIconStateMachine.tick(phase: sliding,
                                                            elapsed: .milliseconds(10),
                                                            reduceMotionCaptured: true)
        XCTAssertEqual(defensiveSlidingTick.next, .rest(holder: target))
    }

    func testK94RestResolverBranches() {
        let work = TransitionOutcome(state: .done(.lavoro), persistence: .success(.lavoro), actual: .lavoro)
        XCTAssertEqual(DockIconRestResolver.holder(outcome: work, current: .personale, needsReconcile: false),
                       .lavoro)

        let genericFailure = TransitionOutcome(state: .failed(nil, .targetFailed),
                                               persistence: .unchanged,
                                               actual: nil)
        XCTAssertEqual(DockIconRestResolver.holder(outcome: genericFailure,
                                                   current: .personale,
                                                   needsReconcile: false),
                       .personale)

        let incoherent = TransitionOutcome(state: .failed(nil, .incoherent),
                                           persistence: PersistencePlan(needsReconcile: true),
                                           actual: nil)
        XCTAssertNil(DockIconRestResolver.holder(outcome: incoherent,
                                                 current: .personale,
                                                 needsReconcile: false))

        let unknownHolder = TransitionOutcome(state: .failed(nil, .unknownHolder),
                                              persistence: .unchanged,
                                              actual: nil)
        XCTAssertNil(DockIconRestResolver.holder(outcome: unknownHolder,
                                                 current: .lavoro,
                                                 needsReconcile: false))

        XCTAssertNil(DockIconRestResolver.holder(outcome: work, current: .personale, needsReconcile: true))
    }

    func testK96bFrameIndexPulseCycleAndSlideMonotonicity() {
        let pulse = DockIconPhase.pulsing(from: .lavoro)
        for index in 0..<DockIconStateMachine.pulseFrameCount {
            let elapsed = Duration.seconds(Double(index) / 15 + 0.001)
            XCTAssertEqual(DockIconStateMachine.frameIndex(phase: pulse, elapsed: elapsed), index)
        }
        XCTAssertEqual(DockIconStateMachine.frameIndex(phase: pulse,
                                                       elapsed: Duration.seconds(10.0 / 15 + 0.001)),
                       0)
        XCTAssertEqual(DockIconStateMachine.frameIndex(phase: pulse,
                                                       elapsed: Duration.seconds(1.0)),
                       5)
        XCTAssertEqual(DockIconStateMachine.frameIndex(phase: pulse, elapsed: .zero), 0)
        XCTAssertEqual(DockIconStateMachine.frameIndex(phase: pulse, elapsed: .milliseconds(-10)), 0)

        let sliding = DockIconPhase.sliding(from: .personale, to: .lavoro)
        var previous = -1
        for index in 0..<DockIconStateMachine.slideFrameCount {
            let elapsed = Duration.milliseconds(Int64(index) * 35)
            let value = DockIconStateMachine.frameIndex(phase: sliding, elapsed: elapsed)
            XCTAssertEqual(value, index)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
        XCTAssertEqual(DockIconStateMachine.frameIndex(phase: sliding, elapsed: .milliseconds(349)), 9)
        XCTAssertEqual(DockIconStateMachine.frameIndex(phase: sliding, elapsed: .milliseconds(350)), 10)
        XCTAssertEqual(DockIconStateMachine.frameIndex(phase: sliding, elapsed: .milliseconds(900)), 10)
        XCTAssertEqual(DockIconStateMachine.frameIndex(phase: .rest(holder: .lavoro), elapsed: .seconds(2)), 0)
        XCTAssertEqual(DockIconStateMachine.frameIndex(phase: .staticSwitching(from: .personale),
                                                       elapsed: .seconds(2)), 0)
    }
}
