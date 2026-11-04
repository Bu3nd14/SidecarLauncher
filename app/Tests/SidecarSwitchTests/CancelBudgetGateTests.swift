import XCTest
@testable import SidecarSwitchCore

final class CancelBudgetGateTests: XCTestCase {
    func testPreCancelledTokenDoesNothingDestructive() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        let machine = makeMachine(ops)
        let token = CancellationToken()
        token.cancel()

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: token)

        assertOperations(ops, [.probe(.lavoro), .probe(.personale)])
        XCTAssertEqual(outcome.state, .failed(nil, .cancelled))
        XCTAssertEqual(outcome.persistence, .unchanged)
    }

    func testCancelDuringPreflightLeavesSourceUntouched() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual])])
        let machine = makeMachine(ops)
        let token = CancellationToken()
        ops.onOperation = { operation in
            if operation == .devices(.personale) { token.cancel() }
        }

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: token)

        XCTAssertEqual(outcome.state, .failed(.lavoro, .cancelled))
        XCTAssertEqual(outcome.persistence, PersistencePlan(lastLocation: .set(.lavoro), needsReconcile: false))
        XCTAssertEqual(ops.count(of: .disconnect(.lavoro, "iPad")), 0)
        XCTAssertEqual(ops.count(of: .connect(.personale, "iPad")), 0)
    }

    func testCancelAfterSourceReleasedRollsBack() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [
            Fixtures.connected(),
            Fixtures.connected(),
            Fixtures.disconnected(),
            Fixtures.disconnected(),
            Fixtures.connected(),
            Fixtures.connected()
        ])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual])])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin, Fixtures.sidecarLive])])
        let machine = makeMachine(ops)
        let token = CancellationToken()
        ops.onOperation = { operation in
            if operation == .disconnect(.lavoro, "iPad") { token.cancel() }
        }

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: token)

        XCTAssertEqual(ops.count(of: .connect(.personale, "iPad")), 0)
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 1)
        XCTAssertEqual(outcome.state, .failed(.lavoro, .cancelled))
        XCTAssertEqual(outcome.persistence, PersistencePlan(lastLocation: .set(.lavoro), needsReconcile: false))
        XCTAssertTrue(outcome.message?.contains("ripristinata") ?? false)
    }

    func testCancelWithNowhereSource() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])
        let machine = makeMachine(ops)
        let token = CancellationToken()
        ops.onOperation = { operation in
            if operation == .devices(.lavoro) { token.cancel() }
        }

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: token)

        XCTAssertEqual(outcome.state, .failed(.nowhere, .cancelled))
        XCTAssertEqual(outcome.persistence, PersistencePlan(lastLocation: .set(.nowhere), needsReconcile: false))
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 0)
    }

    func testRollbackInsufficientBudgetIsIncoherent() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [
            Fixtures.connected(),
            Fixtures.connected(),
            Fixtures.disconnected(),
            Fixtures.disconnected()
        ])
        ops.setProbes(.personale, [
            Fixtures.disconnected(),
            Fixtures.disconnected(),
            Fixtures.disconnected()
        ])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual])])
        ops.setConnectStatuses([.exited(2), .exited(2)])
        var timings = Timings.fast
        timings.rollbackBudget = .zero
        let machine = makeMachine(ops, timings: timings)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(nil, .incoherent))
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 0)
    }

    func testVerifyReserveMatchesDesign() {
        XCTAssertEqual(Timings.standard.verifyReserve(for: .lavoro).inSeconds, 48, accuracy: 0.001)
        XCTAssertEqual(Timings.standard.verifyReserve(for: .personale).inSeconds, 58, accuracy: 0.001)
        XCTAssertEqual(Timings.standard.transitionDeadline, .seconds(360))
        XCTAssertEqual(Timings.standard.rollbackBudget, .seconds(180))
        XCTAssertEqual(Timings.standard.connectAttempts, 2)
    }

    func testGateDiscardsSecondToggleAndLogs() async {
        let ops = RecordingOperations()
        ops.probeDelay = .milliseconds(300)
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected()])
        let log = ArrayLogging()
        let machine = makeMachine(ops, logging: log)
        let gate = ToggleGate(logging: log)

        async let first = gate.run(transitionID: UUID()) { token in
            await machine.toggle(target: .lavoro, transitionID: UUID(), token: token)
        }
        try? await Task.sleep(for: .milliseconds(80))
        let second = await gate.run(transitionID: UUID()) { token in
            await machine.toggle(target: .lavoro, transitionID: UUID(), token: token)
        }
        let firstOutcome = await first

        XCTAssertNil(second)
        XCTAssertEqual(firstOutcome?.state, .done(.lavoro))
        XCTAssertTrue(log.contains("scartato"))
        XCTAssertEqual(ops.count(of: .probe(.lavoro)), 1)
    }

    func testGateAllowsSequentialRuns() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(),
                                Fixtures.connected(), Fixtures.connected()])
        let gate = ToggleGate()
        let machine = makeMachine(ops)

        let first = await gate.run(transitionID: UUID()) { token in
            await machine.toggle(target: .lavoro, transitionID: UUID(), token: token)
        }
        let second = await gate.run(transitionID: UUID()) { token in
            await machine.toggle(target: .lavoro, transitionID: UUID(), token: token)
        }

        XCTAssertEqual(first?.state, .done(.lavoro))
        XCTAssertEqual(second?.state, .done(.lavoro))
    }

    func testGateCancelAndWait() async {
        let ops = RecordingOperations()
        ops.probeDelay = .milliseconds(200)
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected()])
        let gate = ToggleGate()
        let machine = makeMachine(ops)

        async let outcome = gate.run(transitionID: UUID()) { token in
            await machine.toggle(target: .lavoro, transitionID: UUID(), token: token)
        }
        try? await Task.sleep(for: .milliseconds(50))
        await gate.cancelCurrent()
        let idle = await gate.waitForIdle(timeout: .seconds(2))
        let value = await outcome

        XCTAssertTrue(idle)
        XCTAssertEqual(value?.state, .failed(nil, .cancelled))
    }
}
