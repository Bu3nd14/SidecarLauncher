import XCTest
@testable import SidecarSwitchCore

final class StateMachineFailureTests: XCTestCase {
    private func preparedSourceOnLavoro(_ ops: RecordingOperations) {
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected()])
    }

    func testK5TargetUnreachableZeroDisconnect() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.unreachable()])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        assertOperations(ops, [.probe(.lavoro), .probe(.personale)])
        XCTAssertEqual(outcome.state, .failed(.lavoro, .targetUnreachable))
        XCTAssertEqual(outcome.persistence, PersistencePlan(lastLocation: .set(.lavoro), needsReconcile: false))
    }

    func testK21RemoteBootstrapPropagated() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.unreachable(.remoteBootstrap)])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(.lavoro, .remoteBootstrap))
        XCTAssertEqual(ops.count(of: .disconnect(.lavoro, "iPad")), 0)
    }

    func testK20HostKeyMismatchPropagated() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.unreachable(.hostKeyMismatch)])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(.lavoro, .hostKeyMismatch))
        XCTAssertEqual(ops.count(of: .disconnect(.lavoro, "iPad")), 0)
    }

    func testAuthFailurePropagated() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.unreachable(.authFailed)])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(.lavoro, .authFailed))
    }

    func testK30RemoteCrashPropagated() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.unreachable(.remoteCrashed)])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(.lavoro, .remoteCrashed))
        XCTAssertEqual(ops.count(of: .disconnect(.lavoro, "iPad")), 0)
    }

    func testK22RemoteVdispMissingAbortsBeforeDisconnect() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDevices(.personale, [Fixtures.devicesOK()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.builtin])])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        assertOperations(ops, [.probe(.lavoro), .probe(.personale), .devices(.personale), .displays(.personale)])
        XCTAssertEqual(outcome.state, .failed(.lavoro, .preflightRemoteVdispMissing))
        XCTAssertEqual(ops.count(of: .disconnect(.lavoro, "iPad")), 0)
    }

    func testK16DisconnectExit3AbortsWithoutConnect() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDisconnectStatuses([.exited(3)])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .deviceNotFound))
        XCTAssertEqual(ops.count(of: .connect(.personale, "iPad")), 0)
        XCTAssertEqual(outcome.persistence.lastLocation, .set(.lavoro))
    }

    func testK6TransientConnectFailureRollsBack() async {
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
        ops.setDevices(.personale, [Fixtures.devicesOK(), Fixtures.devicesOK()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual])])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin, Fixtures.sidecarLive])])
        ops.setConnectStatuses([.exited(2), .exited(2), .ok])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(ops.count(of: .connect(.personale, "iPad")), 2)
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 1)
        XCTAssertEqual(ops.count(of: .harden(.lavoro)), 0)
        XCTAssertEqual(outcome.state, .failed(.lavoro, .targetFailedRolledBack))
        XCTAssertEqual(outcome.persistence, PersistencePlan(lastLocation: .set(.lavoro), needsReconcile: false))
    }

    func testK7RollbackFailureIsIncoherent() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [
            Fixtures.connected(),
            Fixtures.connected(),
            Fixtures.disconnected(),
            Fixtures.disconnected(),
            Fixtures.disconnected(),
            Fixtures.disconnected()
        ])
        ops.setProbes(.personale, [
            Fixtures.disconnected(),
            Fixtures.disconnected(),
            Fixtures.disconnected()
        ])
        ops.setDevices(.personale, [Fixtures.devicesOK(), Fixtures.devicesOK()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual])])
        ops.setConnectStatuses([.exited(2), .exited(2), .ok])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(nil, .incoherent))
        XCTAssertEqual(outcome.persistence, PersistencePlan(lastLocation: .unchanged, needsReconcile: true))
    }

    func testK17ConnectTimeoutButVerifyConnectedIsDone() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.sidecarLive])])
        ops.setConnectStatuses([.timedOut])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.personale))
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 0)
    }

    func testK24MixedSamplesIsTargetUnknownNoRollback() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual])])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .targetUnknown))
        XCTAssertEqual(outcome.persistence, PersistencePlan(lastLocation: .unchanged, needsReconcile: true))
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 0)
    }

    func testK29DisplayUnverifiedNoRollback() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.virtual])])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .displayUnverified))
        XCTAssertEqual(outcome.persistence, PersistencePlan(lastLocation: .unchanged, needsReconcile: true))
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 0)
    }

    func testK24bAsleepDisplayIsNotLive() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.virtual, Fixtures.sidecarAsleep])])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(.lavoro, .displayUnverified))
    }

    func testK26NowhereConnectFailureDoesNotRollback() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.disconnected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDevices(.lavoro, [Fixtures.devicesOK(), Fixtures.devicesOK()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])
        ops.setConnectStatuses([.exited(3), .exited(3)])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.nowhere, .targetFailed))
        XCTAssertEqual(outcome.persistence, PersistencePlan(lastLocation: .set(.nowhere), needsReconcile: false))
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 2)
        XCTAssertEqual(ops.count(of: .connect(.personale, "iPad")), 0)
        XCTAssertEqual(ops.count(of: .disconnect(.personale, "iPad")), 0)
    }

    func testK15UnknownHolderAbortsWithoutActions() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.unknown("private API")])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        assertOperations(ops, [.probe(.lavoro), .probe(.personale)])
        XCTAssertEqual(outcome.state, .failed(nil, .unknownHolder))
        XCTAssertEqual(outcome.persistence, .unchanged)
    }

    func testK27TooManyDevicesIsIncoherent() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(["iPad", "iPad 2"])])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(nil, .incoherent))
        XCTAssertEqual(outcome.persistence.needsReconcile, true)
        XCTAssertEqual(ops.count(of: .disconnect(.lavoro, "iPad")), 0)
    }

    func testForeignDeviceAborts() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(["MacBook Pro"])])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(nil, .foreignDevice))
        XCTAssertEqual(outcome.persistence, .unchanged)
    }

    func testK25LocalSourceChangedBeforeDisconnect() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .stateChanged))
        XCTAssertEqual(ops.count(of: .disconnect(.lavoro, "iPad")), 0)
        XCTAssertEqual(outcome.persistence, .unchanged)
    }

    func testK25bRemoteSourceChangedBeforeDisconnect() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.connected(), Fixtures.disconnected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.personale, .stateChanged))
        XCTAssertEqual(ops.count(of: .disconnect(.personale, "iPad")), 0)
    }

    func testCannotReleaseWhenDisconnectTimesOutAndSourceStaysConnected() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDisconnectStatuses([.timedOut])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .cannotRelease))
        XCTAssertEqual(ops.count(of: .connect(.personale, "iPad")), 0)
    }

    func testLocalPreflightDeviceMissing() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.connected()])
        ops.setDevices(.lavoro, [Fixtures.devicesOK(["MacBook"])])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(.personale, .deviceNotFound))
        XCTAssertEqual(ops.count(of: .disconnect(.personale, "iPad")), 0)
    }

    func testLocalLidClosedAborts() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.connected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([])])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(.personale, .localLidClosed))
        XCTAssertEqual(ops.count(of: .disconnect(.personale, "iPad")), 0)
    }

    func testForceConnectLavoroWithUnknownLocalPrivateAPI() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.unknown("private API")])
        let machine = makeMachine(ops)

        let outcome = await machine.forceConnectLavoro(transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(nil, .localPrivateAPI))
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 0)
    }
}
