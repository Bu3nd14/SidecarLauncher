import XCTest
@testable import SidecarSwitchCore

final class ControlMasterStateMachineTests: XCTestCase {
    private func firstSessionOperation(_ ops: RecordingOperations) -> Op? {
        ops.sessionOperations.first { $0.session }?.op
    }

    private func index(of needle: String, in lifecycle: [String]) -> Int? {
        lifecycle.firstIndex(of: needle)
    }

    func testK92ForwardLavoroToPersonaleFirstInSessionIsReadOnly() async {
        let ops = RecordingOperations()
        ops.setSessionEnabled(true)
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDevices(.personale, [Fixtures.devicesOK()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.virtual, Fixtures.sidecarLive])])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.personale))
        XCTAssertEqual(firstSessionOperation(ops), .probe(.personale))
        XCTAssertEqual(ops.begins, 1)
        XCTAssertEqual(ops.ends, 1)
        XCTAssertEqual(ops.lifecycle.last, "end[session]")
    }

    func testK92ForwardPersonaleToLavoroFirstInSessionIsReadOnly() async {
        let ops = RecordingOperations()
        ops.setSessionEnabled(true)
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setDevices(.lavoro, [Fixtures.devicesOK()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin]),
                                  Fixtures.displaysOK([Fixtures.builtin, Fixtures.sidecarMirrored])])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.lavoro))
        XCTAssertEqual(firstSessionOperation(ops), .probe(.personale))
        XCTAssertEqual(ops.begins, 1)
        XCTAssertEqual(ops.ends, 1)
    }

    func testK92NoopFirstInSessionIsReadOnly() async {
        let ops = RecordingOperations()
        ops.setSessionEnabled(true)
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.lavoro))
        XCTAssertEqual(firstSessionOperation(ops), .probe(.personale))
        XCTAssertEqual(ops.ends, 1)
    }

    func testK81ReconcileDisconnectsPlainThenFirstSessionIsReadOnly() async {
        let ops = RecordingOperations()
        ops.setSessionEnabled(true)
        ops.setProbes(.lavoro, [Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual, Fixtures.sidecarLive])])
        let machine = makeMachine(ops)

        let outcome = await machine.reconcile(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.personale))
        XCTAssertEqual(Array(ops.operations.prefix(2)), [.disconnect(.lavoro, "iPad"), .disconnect(.personale, "iPad")])
        XCTAssertEqual(firstSessionOperation(ops), .probe(.personale))
        XCTAssertEqual(ops.sessionOperations.filter { $0.op == .disconnect(.lavoro, "iPad") }.count, 0)
        XCTAssertEqual(ops.sessionOperations.filter { $0.op == .disconnect(.personale, "iPad") }.count, 0)
        XCTAssertEqual(ops.begins, 1)
        XCTAssertEqual(ops.ends, 1)
    }

    func testK92ReconcileGateDisabledHasNoInSessionCommands() async {
        let ops = RecordingOperations()
        ops.setSessionEnabled(true)
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin, Fixtures.sidecarMirrored])])
        let machine = makeMachine(ops)

        let outcome = await machine.reconcile(target: .lavoro, transitionID: UUID(), token: CancellationToken(),
                                              personaleGateDisabled: true)

        XCTAssertEqual(outcome.state, .done(.lavoro))
        XCTAssertTrue(ops.sessionOperations.filter { $0.session }.isEmpty)
        XCTAssertEqual(ops.begins, 1)
        XCTAssertEqual(ops.ends, 1)
    }

    func testP3PersonaleToLavoroClosesSessionBeforeLocalConnect() async {
        let ops = RecordingOperations()
        ops.setSessionEnabled(true)
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setDevices(.lavoro, [Fixtures.devicesOK()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin]),
                                  Fixtures.displaysOK([Fixtures.builtin, Fixtures.sidecarMirrored])])
        var timings = Timings.fast
        timings.postDisconnectSettle = .seconds(3)
        timings.settleBudget = .seconds(21)
        timings.settlePollBackoffs = [.seconds(21)]
        let machine = makeMachine(ops, timings: timings)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.lavoro))
        let lifecycle = ops.lifecycle
        let end = index(of: "end[session]", in: lifecycle)
        let connect = index(of: "do:connect(lavoro, iPad)", in: lifecycle)
        XCTAssertNotNil(end)
        XCTAssertNotNil(connect)
        if let end, let connect { XCTAssertLessThan(end, connect) }
        XCTAssertEqual(ops.begins, 1)
        XCTAssertEqual(ops.ends, 1)
    }

    func testP3PersonaleToLavoroRollbackReopensSession() async {
        let ops = RecordingOperations()
        ops.setSessionEnabled(true)
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.disconnected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected(),
                                   Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDevices(.lavoro, [Fixtures.devicesOK()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual, Fixtures.sidecarLive])])
        ops.setConnectStatuses([.exited(4), .ok])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.personale, .targetFailedRolledBack))
        XCTAssertEqual(ops.begins, 2)
        XCTAssertEqual(ops.ends, 2)
        let lifecycle = ops.lifecycle
        XCTAssertEqual(lifecycle.filter { $0 == "begin" }.count, 2)
        XCTAssertEqual(lifecycle.filter { $0 == "end[session]" }.count, 2)
        XCTAssertEqual(lifecycle.last, "end[session]")
        let secondSessionProbes = ops.sessionOperations.filter { $0.session }
        XCTAssertEqual(secondSessionProbes.first?.op, .probe(.personale))
    }

    func testK92RollbackFirstInSessionIsReadOnly() async {
        let ops = RecordingOperations()
        ops.setSessionEnabled(true)
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected(),
                                Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.disconnected(), Fixtures.disconnected()])
        ops.setDevices(.personale, [Fixtures.devicesOK()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual, Fixtures.sidecarLive])])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin, Fixtures.sidecarMirrored])])
        ops.setConnectStatuses([.exited(4), .ok])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .targetFailedRolledBack))
        let session = ops.sessionOperations.filter { $0.session }
        XCTAssertEqual(session.first?.op, .probe(.personale))
        XCTAssertEqual(ops.ends, 1)
    }

    func testK84DisconnectTransportFailsCannotReleaseWithoutReprobe() async {
        let ops = RecordingOperations()
        ops.setSessionEnabled(true)
        ops.setProbes(.lavoro, [Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.connected(), Fixtures.connected()])
        ops.setDevices(.lavoro, [Fixtures.devicesOK()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])
        ops.setDisconnectStatuses([.transport(.targetUnreachable)])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.personale, .cannotRelease))
        XCTAssertEqual(outcome.persistence.lastLocation, .set(.personale))
        XCTAssertEqual(outcome.persistence.needsReconcile, false)
        XCTAssertEqual(ops.count(of: .disconnect(.personale, "iPad")), 1)
        XCTAssertEqual(ops.count(of: .probe(.personale)), 2)
        XCTAssertEqual(ops.operations.last, .disconnect(.personale, "iPad"))
        XCTAssertEqual(ops.sessionOperations.filter { $0.op == .disconnect(.personale, "iPad") }.map(\.session), [true])
        XCTAssertEqual(ops.sessionOperations.filter { $0.session }.first?.op, .probe(.personale))
    }

    func testK85VerifyTransportIsUnknownWithoutSeparateFallback() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDevices(.lavoro, [Fixtures.devicesOK()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])
        ops.batchExecutor = { kind in
            if kind == .prereqs {
                return .sections([
                    RemoteSectionResult(section: "devices", exitCode: 0, content: "iPad"),
                    RemoteSectionResult(section: "dispid", exitCode: 0,
                                        content: "id=3 vendor=0x5644 model=0x1 serial=0 builtin=false main=true active=true mirror_of=0 asleep=false 1321x918")
                ])
            }
            return .transport(.targetUnreachable)
        }
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .targetUnknown))
        XCTAssertEqual(outcome.persistence.needsReconcile, true)
        XCTAssertEqual(ops.count(of: .batch(.verify)), 1)
        XCTAssertEqual(ops.count(of: .displays(.personale)), 0)
    }

    func testK72EndRunsOnPreflightCannotReleaseAndIncoherent() async {
        let preflight = RecordingOperations()
        preflight.setSessionEnabled(true)
        preflight.setProbes(.lavoro, [Fixtures.connected()])
        preflight.setProbes(.personale, [Fixtures.disconnected()])
        preflight.setDevices(.personale, [Fixtures.devicesOK()])
        preflight.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.builtin])])
        let machine1 = makeMachine(preflight)
        _ = await machine1.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(preflight.ends, 1)

        let cannotRelease = RecordingOperations()
        cannotRelease.setSessionEnabled(true)
        cannotRelease.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected()])
        cannotRelease.setProbes(.personale, [Fixtures.disconnected()])
        cannotRelease.setDevices(.lavoro, [Fixtures.devicesOK()])
        cannotRelease.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])
        cannotRelease.setDisconnectStatuses([.transport(.targetUnreachable)])
        let machine2 = makeMachine(cannotRelease)
        _ = await machine2.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(cannotRelease.ends, 1)

        let incoherent = RecordingOperations()
        incoherent.setSessionEnabled(true)
        incoherent.setProbes(.lavoro, [ProbeReport(state: .connected(devices: ["iPad", "iPhone"]))])
        let machine3 = makeMachine(incoherent)
        let outcome = await machine3.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(nil, .incoherent))
        XCTAssertEqual(incoherent.ends, 1)
    }

    func testK86CancelMidFlightStillEndsSession() async {
        let ops = RecordingOperations()
        ops.setSessionEnabled(true)
        ops.probeDelay = .milliseconds(200)
        ops.setProbes(.lavoro, [Fixtures.connected()])
        let machine = makeMachine(ops)
        let token = CancellationToken()
        let task = Task { await machine.toggle(target: .personale, transitionID: UUID(), token: token) }
        try? await Task.sleep(for: .milliseconds(50))
        token.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome.state, .failed(nil, .cancelled))
        XCTAssertEqual(ops.ends, 1)
        XCTAssertEqual(ops.lifecycle.last, "end[session]")
    }
}
