import XCTest
@testable import SidecarSwitchCore

final class OutcomeTableTests: XCTestCase {
    func testEveryReasonHasNonEmptyMessage() {
        XCTAssertEqual(Reason.allCases.count, 20)
        for reason in Reason.allCases {
            XCTAssertFalse(reason.displayMessage.isEmpty, "\(reason)")
        }
    }

    func testK28EveryReasonHasAnOutcomePresentation() {
        for reason in Reason.allCases {
            let severity = OutcomePresentation.severity(for: .failed(nil, reason))
            switch reason {
            case .incoherent, .foreignDevice:
                XCTAssertEqual(severity, .error, "\(reason)")
            default:
                XCTAssertEqual(severity, .warning, "\(reason)")
            }
        }
        XCTAssertEqual(OutcomePresentation.severity(for: .done(.lavoro)), .info)
        XCTAssertEqual(OutcomePresentation.severity(for: .idle), .info)
    }

    func testD7TargetUnreachableMessageIncludesProxyHint() {
        let message = Reason.targetUnreachable.displayMessage
        XCTAssertTrue(message.contains("Mac personale non raggiungibile — controlla VPN/rete/tunnel"))
        XCTAssertTrue(message.contains("config SSH o proxy/CA non applicati? controlla VPN/rete"))
    }

    func testK18bRollbackReservesVerifyBeforeConnect() {
        let timings = Timings.standard
        let reserve = timings.verifyReserve(for: .personale)
        XCTAssertEqual(timings.rollbackConnectBudget(remaining: reserve + timings.connectCommandTimeout,
                                                     host: .personale),
                       timings.connectCommandTimeout)
        XCTAssertNil(timings.rollbackConnectBudget(remaining: reserve + timings.connectCommandTimeout - .seconds(1),
                                                   host: .personale))
        XCTAssertEqual(timings.rollbackConnectBudget(remaining: .seconds(400), host: .personale),
                       .seconds(400) - reserve)
    }

    func testPreflightRemoteWhenDevicesFail() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDevices(.personale, [Fixtures.devicesFailed(.exited(2))])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(.lavoro, .preflightRemote))
        XCTAssertEqual(outcome.persistence, PersistencePlan(lastLocation: .set(.lavoro), needsReconcile: false))
    }

    func testPreflightRemoteTransportAuthFailure() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDevices(.personale, [Fixtures.devicesFailed(.transport(.authFailed))])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(.lavoro, .authFailed))
    }

    func testLocalPrivateAPIViaDevicesExit4() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.connected()])
        ops.setDevices(.lavoro, [Fixtures.devicesFailed(.exited(4))])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(.personale, .localPrivateAPI))
        XCTAssertEqual(outcome.persistence, PersistencePlan(lastLocation: .set(.personale), needsReconcile: false))
    }

    func testRemoteUnknownTargetIsUnreachable() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.unknown()])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(.lavoro, .targetUnreachable))
    }

    func testRollbackDisplayUnverifiedKeepsSource() async {
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
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin, Fixtures.sidecarAsleep])])
        ops.setConnectStatuses([.exited(2), .exited(2), .ok])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .displayUnverified))
        XCTAssertEqual(outcome.persistence, PersistencePlan(lastLocation: .set(.lavoro), needsReconcile: true))
    }

    func testForeignDeviceOnRemoteAborts() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.connected(["iPad di Mario"])])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(nil, .foreignDevice))
    }

    func testPersistedNeedsReconcileIsClearedByNoop() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected()])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.persistence.needsReconcile, false)
    }

    func testReconcileSuccess() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin, Fixtures.sidecarLive])])
        let machine = makeMachine(ops)

        let outcome = await machine.reconcile(target: .lavoro, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.lavoro))
        XCTAssertEqual(outcome.persistence, .success(.lavoro))
        XCTAssertEqual(ops.count(of: .disconnect(.lavoro, "iPad")), 1)
        XCTAssertEqual(ops.count(of: .disconnect(.personale, "iPad")), 1)
        XCTAssertEqual(ops.count(of: .connect(.lavoro, "iPad")), 1)
    }

    func testReconcileFailureSetsNeedsReconcile() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.disconnected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        let machine = makeMachine(ops)

        let outcome = await machine.reconcile(target: .lavoro, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .failed(.nowhere, .targetUnknown))
        XCTAssertEqual(outcome.persistence, PersistencePlan(lastLocation: .unchanged, needsReconcile: true))
    }
}
