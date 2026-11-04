import XCTest
@testable import SidecarSwitchCore

final class AddendumTests: XCTestCase {
    func testK50IncoherentAndUnknownHolderSetActualUnknown() {
        let incoherent = TransitionOutcome(state: .failed(nil, .incoherent),
                                          persistence: PersistencePlan(needsReconcile: true),
                                          actual: nil)
        XCTAssertEqual(OutcomeStateReducer.actual(after: incoherent, current: .lavoro), .unknown)

        let unknownHolder = TransitionOutcome(state: .failed(nil, .unknownHolder),
                                              persistence: .unchanged,
                                              actual: nil)
        XCTAssertEqual(OutcomeStateReducer.actual(after: unknownHolder, current: .personale), .unknown)

        let rolledBack = TransitionOutcome(state: .failed(.lavoro, .targetFailedRolledBack),
                                           persistence: .success(.lavoro), actual: .lavoro)
        XCTAssertEqual(OutcomeStateReducer.actual(after: rolledBack, current: .personale), .lavoro)
    }

    func testK51CancelAfterConnectKeepsTargetAndNeverRollsBack() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDevices(.personale, [Fixtures.devicesOK()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.virtual, Fixtures.sidecarLive])])
        let token = CancellationToken()
        ops.onOperation = { operation in
            if operation == .connect(.personale, "iPad") { token.cancel() }
        }
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: token)

        XCTAssertEqual(outcome.state, .done(.personale))
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 0)
        XCTAssertEqual(outcome.actual, .personale)
    }

    func testRollbackVerifiesSourceBeforeDeclaringRolledBack() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [
            Fixtures.connected(),
            Fixtures.connected(),
            Fixtures.disconnected(),
            Fixtures.connected(),
            Fixtures.connected(),
            Fixtures.disconnected()
        ])
        ops.setProbes(.personale, [
            Fixtures.disconnected(),
            Fixtures.disconnected(),
            Fixtures.disconnected()
        ])
        ops.setDevices(.personale, [Fixtures.devicesOK(), Fixtures.devicesOK()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual])])
        ops.setConnectStatuses([.exited(2), .exited(2)])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(nil, .incoherent))
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 0)
        XCTAssertEqual(ops.count(of: .harden(.lavoro)), 0)
    }

    func testRollbackAlreadyConnectedSourceIsVerifiedAndHardenedOnce() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [
            Fixtures.connected(),
            Fixtures.connected(),
            Fixtures.disconnected(),
            Fixtures.connected(),
            Fixtures.connected(),
            Fixtures.connected()
        ])
        ops.setProbes(.personale, [
            Fixtures.disconnected(),
            Fixtures.disconnected(),
            Fixtures.disconnected()
        ])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual])])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin, Fixtures.sidecarLive])])
        ops.setConnectStatuses([.exited(2), .exited(2)])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .targetFailedRolledBack))
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 0)
        XCTAssertEqual(ops.count(of: .harden(.lavoro)), 0)
    }

    func testConnectExit4TransientIsRetried() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.sidecarLive])])
        ops.setConnectOutcomes([
            CommandOutcome(status: .exited(4), report: CommandReport(status: .exited(4), stderr: "-455 SidecarErrorDisplayAWDLDegraded")),
            CommandOutcome(status: .ok, report: CommandReport(status: .ok))
        ])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.personale))
        XCTAssertEqual(ops.count(of: .connect(.personale, "iPad")), 2)
    }

    func testConnectExit4FatalStopsWithoutRetry() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.sidecarLive])])
        ops.setConnectOutcomes([
            CommandOutcome(status: .exited(4), report: CommandReport(status: .exited(4), stderr: "-501 SidecarErrorVirtualDisplayFailed"))
        ])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.personale), "verify decide, non l'exit 4")
        XCTAssertEqual(ops.count(of: .connect(.personale, "iPad")), 1)
    }

    func testPostDisconnectSettleHappensBeforeConnect() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.sidecarLive])])
        let sleeper = RecordingSleeper()
        var timings = Timings.fast
        timings.postDisconnectSettle = .seconds(3)
        timings.settleBudget = .seconds(8)
        let machine = StateMachine(ops: ops, timings: timings, sleeper: sleeper,
                                   deviceName: "iPad", logging: NoopLogging())

        _ = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertTrue(sleeper.durations.contains(.seconds(3)))
        XCTAssertLessThanOrEqual(sleeper.durations.reduce(Duration.zero, +).inSeconds, 8)
        let disconnectIndex = ops.operations.firstIndex(of: .disconnect(.lavoro, "iPad"))
        let connectIndex = ops.operations.firstIndex(of: .connect(.personale, "iPad"))
        XCTAssertNotNil(disconnectIndex)
        XCTAssertNotNil(connectIndex)
        if let disconnectIndex, let connectIndex {
            XCTAssertTrue(ops.operations[disconnectIndex..<connectIndex].contains(.devices(.personale)))
        }
    }

    func testHardenLavoroIsNoOpAndPersonaleCallsArrangeOnly() async {
        let lavoro = RecordingOperations()
        lavoro.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected()])
        let machineL = makeMachine(lavoro)
        _ = await machineL.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(lavoro.count(of: .harden(.lavoro)), 0)

        let personale = RecordingOperations()
        personale.setProbes(.lavoro, [Fixtures.disconnected()])
        personale.setProbes(.personale, [Fixtures.connected(), Fixtures.connected()])
        let machineP = makeMachine(personale)
        _ = await machineP.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(personale.count(of: .harden(.personale)), 1)
        XCTAssertEqual(personale.count(of: .harden(.lavoro)), 0)
    }

    func testK52DockMenuMatrix() {
        struct Row {
            let actual: Location
            let last: Location
            let gate: Bool
            let transitioning: Bool
            let lavoro: Bool
            let personale: Bool
            let checkmark: Location?
        }
        let rows: [Row] = [
            Row(actual: .lavoro, last: .unknown, gate: false, transitioning: false, lavoro: true, personale: true, checkmark: .lavoro),
            Row(actual: .lavoro, last: .unknown, gate: true, transitioning: false, lavoro: true, personale: false, checkmark: .lavoro),
            Row(actual: .personale, last: .lavoro, gate: false, transitioning: false, lavoro: true, personale: true, checkmark: .personale),
            Row(actual: .personale, last: .lavoro, gate: true, transitioning: false, lavoro: true, personale: false, checkmark: .personale),
            Row(actual: .nowhere, last: .lavoro, gate: false, transitioning: false, lavoro: true, personale: true, checkmark: .lavoro),
            Row(actual: .nowhere, last: .personale, gate: false, transitioning: false, lavoro: true, personale: true, checkmark: .personale),
            Row(actual: .nowhere, last: .unknown, gate: false, transitioning: false, lavoro: true, personale: true, checkmark: nil),
            Row(actual: .nowhere, last: .lavoro, gate: true, transitioning: false, lavoro: true, personale: false, checkmark: .lavoro),
            Row(actual: .lavoro, last: .lavoro, gate: false, transitioning: true, lavoro: false, personale: false, checkmark: .lavoro),
            Row(actual: .unknown, last: .lavoro, gate: false, transitioning: false, lavoro: false, personale: false, checkmark: nil),
            Row(actual: .unknown, last: .personale, gate: true, transitioning: true, lavoro: false, personale: false, checkmark: nil)
        ]

        for row in rows {
            let state = DockMenuPlanner.plan(actual: row.actual, lastLocation: row.last,
                                             isTransitioning: row.transitioning,
                                             personaleGateDisabled: row.gate)
            XCTAssertEqual(state.lavoroEnabled, row.lavoro, "lavoro \(row)")
            XCTAssertEqual(state.personaleEnabled, row.personale, "personale \(row)")
            XCTAssertEqual(state.checkmark, row.checkmark, "checkmark \(row)")
        }
    }

    func testEveryReasonAndCancelledMapsToAPersistenceOutcome() {
        XCTAssertEqual(Reason.allCases.count, 20)
        for reason in Reason.allCases {
            XCTAssertFalse(reason.displayMessage.isEmpty, "\(reason)")
        }
        XCTAssertTrue(Reason.allCases.contains(.cancelled))
    }
}

final class TransportAfterReleaseTests: XCTestCase {
    func testD1TransportFailureAfterReleaseVerifiesConnectedTarget() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.virtual, Fixtures.sidecarLive])])
        ops.setConnectOutcomes([
            CommandOutcome(status: .transport(.targetUnreachable),
                           report: CommandReport(status: .transport(.targetUnreachable),
                                                 stderr: "Connection closed by remote host"))
        ])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.personale))
        XCTAssertEqual(ops.count(of: .connect(.personale, "iPad")), 1)
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 0)
    }

    func testD1TransportFailureAfterReleaseDisconnectedTargetRollsBackVerified() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [
            Fixtures.connected(),
            Fixtures.connected(),
            Fixtures.disconnected(),
            Fixtures.disconnected(),
            Fixtures.connected(),
            Fixtures.connected()
        ])
        ops.setProbes(.personale, [
            Fixtures.disconnected(),
            Fixtures.disconnected(),
            Fixtures.disconnected()
        ])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual])])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin, Fixtures.sidecarLive])])
        ops.setConnectOutcomes([
            CommandOutcome(status: .transport(.targetUnreachable),
                           report: CommandReport(status: .transport(.targetUnreachable))),
            CommandOutcome(status: .ok, report: CommandReport(status: .ok))
        ])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .targetFailedRolledBack))
        XCTAssertEqual(ops.count(of: .connect(.personale, "iPad")), 1)
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 1)
    }

    func testD1TransportFailureWithNoSourceFailsNowhereWithoutRollback() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.disconnected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])
        ops.setConnectOutcomes([
            CommandOutcome(status: .transport(.targetUnreachable),
                           report: CommandReport(status: .transport(.targetUnreachable)))
        ])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.nowhere, .targetUnreachable))
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 1)
        XCTAssertEqual(ops.count(of: .connect(.personale, "iPad")), 0)
        XCTAssertEqual(ops.count(of: .disconnect(.personale, "iPad")), 0)
        XCTAssertEqual(ops.count(of: .disconnect(.lavoro, "iPad")), 0)
    }

    func testD1InsufficientBudgetAfterReleaseStillVerifiesTarget() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.virtual, Fixtures.sidecarLive])])
        var timings = Timings.fast
        timings.transitionDeadline = .seconds(1)
        timings.connectCommandTimeout = .seconds(120)
        let machine = StateMachine(ops: ops, timings: timings, sleeper: TestSleeper(),
                                   deviceName: "iPad", logging: NoopLogging())

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.personale))
        XCTAssertEqual(ops.count(of: .connect(.personale, "iPad")), 0)
    }

    func testD4ReconcileWithGateSkipsAllRemoteOperations() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin, Fixtures.sidecarLive])])
        ops.setConnectOutcomes([CommandOutcome(status: .ok, report: CommandReport(status: .ok))])
        let machine = makeMachine(ops)

        let outcome = await machine.reconcile(target: .lavoro, transitionID: UUID(),
                                              token: CancellationToken(), personaleGateDisabled: true)

        XCTAssertEqual(outcome.state, .done(.lavoro))
        XCTAssertEqual(ops.operations.filter { $0.description.contains("(personale") }, [])
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 1)
    }

    func testK51CancelAfterVerifyConnectedBeforeHardenIsDone() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.virtual, Fixtures.sidecarLive])])
        let token = CancellationToken()
        let counter = Counter()
        ops.onOperation = { operation in
            if operation == .displays(.personale) {
                _ = counter.increment()
                if counter.value == 2 { token.cancel() }
            }
        }
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: token)

        XCTAssertEqual(outcome.state, .done(.personale))
        XCTAssertEqual(ops.count(of: .harden(.personale)), 0)
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 0)
    }
}

final class OperationsCacheTests: XCTestCase {
    private let local = LocalToolPaths.standard(toolsDirectory: "/tmp/tools")

    private func settings() -> Settings {
        var value = Settings.default
        value.remote.host = "personale.local"
        value.remote.user = "utente"
        value.remote.binaryPath = "/remote/SidecarLauncher"
        value.remote.connectedPath = "/remote/connected"
        value.remote.dispidPath = "/remote/dispid"
        value.remote.mirrorPath = "/remote/mirror"
        value.remote.arrangePath = "/remote/arrange"
        return value
    }

    func testD3CacheKeyIgnoresLastLocationAndReconcile() {
        var first = settings()
        let key1 = OperationsCacheKey(settings: first, toolsVersion: "v1", local: local)
        first.lastLocation = .personale
        first.needsReconcile = true
        let key2 = OperationsCacheKey(settings: first, toolsVersion: "v1", local: local)
        XCTAssertEqual(key1, key2)
    }

    func testD3CacheKeyChangesForConfigOrTools() {
        let base = settings()
        let key = OperationsCacheKey(settings: base, toolsVersion: "v1", local: local)

        var remoteChanged = base
        remoteChanged.remote.host = "altro.local"
        XCTAssertNotEqual(key, OperationsCacheKey(settings: remoteChanged, toolsVersion: "v1", local: local))

        var sshChanged = base
        sshChanged.ssh.connectTimeout = 30
        XCTAssertNotEqual(key, OperationsCacheKey(settings: sshChanged, toolsVersion: "v1", local: local))

        var deviceChanged = base
        deviceChanged.device.name = "iPad Pro"
        XCTAssertNotEqual(key, OperationsCacheKey(settings: deviceChanged, toolsVersion: "v1", local: local))

        XCTAssertNotEqual(key, OperationsCacheKey(settings: base, toolsVersion: "v2", local: local))
    }
}

final class SettleBudgetTests: XCTestCase {
    func testD8SettlePollIsBoundedAndProceedsToConnect() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.disconnected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])
        ops.setDevices(.lavoro, [Fixtures.devicesOK(),
                                 Fixtures.devicesOK(["Altro"]),
                                 Fixtures.devicesOK(["Altro"])])
        let sleeper = RecordingSleeper()
        ops.devicesDelay = .seconds(30)
        ops.devicesSleeper = sleeper

        var timings = Timings.fast
        timings.settleBudget = .milliseconds(200)
        timings.remoteProbeTimeout = .seconds(30)
        timings.settlePollAttempts = 3
        timings.settlePollBackoffs = [.seconds(2), .seconds(2), .seconds(2)]
        let machine = StateMachine(ops: ops, timings: timings, sleeper: sleeper,
                                   deviceName: "iPad", logging: NoopLogging())

        let start = Date()
        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(outcome.state, .failed(.nowhere, .targetFailed))
        XCTAssertLessThan(elapsed, 2)
        XCTAssertTrue(sleeper.durations.contains { $0 > .milliseconds(150) && $0 <= .milliseconds(200) })
        XCTAssertLessThanOrEqual(sleeper.durations.reduce(Duration.zero, +).inSeconds, 8)
        let lastTimeout = ops.deviceTimeouts.last ?? .zero
        XCTAssertGreaterThan(lastTimeout, .milliseconds(150))
        XCTAssertLessThanOrEqual(lastTimeout, .milliseconds(200))
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 1)
    }

    func testD8StandardSettleBudgetIsEightSeconds() {
        XCTAssertEqual(Timings.standard.postDisconnectSettle, .seconds(3))
        XCTAssertEqual(Timings.standard.settleBudget, .seconds(8))
    }
}
