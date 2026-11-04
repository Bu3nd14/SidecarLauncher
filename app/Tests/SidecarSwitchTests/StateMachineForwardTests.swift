import XCTest
@testable import SidecarSwitchCore

final class StateMachineForwardTests: XCTestCase {
    func testK3LavoroToPersonaleExactOrder() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDevices(.personale, [Fixtures.devicesOK()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.virtual, Fixtures.sidecarLive])])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        assertOperations(ops, [
            .probe(.lavoro),
            .probe(.personale),
            .devices(.personale),
            .displays(.personale),
            .probe(.lavoro),
            .disconnect(.lavoro, "iPad"),
            .probe(.lavoro),
            .devices(.personale),
            .connect(.personale, "iPad"),
            .probe(.personale),
            .probe(.personale),
            .displays(.personale),
            .harden(.personale)
        ])
        XCTAssertEqual(outcome.state, .done(.personale))
        XCTAssertEqual(outcome.persistence, .success(.personale))
        XCTAssertEqual(outcome.actual, .personale)
    }

    func testK4PersonaleToLavoroExactOrder() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setProbes(.personale, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setDevices(.lavoro, [Fixtures.devicesOK()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin]),
                                  Fixtures.displaysOK([Fixtures.builtin, Fixtures.sidecarMirrored])])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())

        assertOperations(ops, [
            .probe(.lavoro),
            .probe(.personale),
            .devices(.lavoro),
            .displays(.lavoro),
            .probe(.personale),
            .disconnect(.personale, "iPad"),
            .probe(.personale),
            .devices(.lavoro),
            .connect(.lavoro, "iPad"),
            .probe(.lavoro),
            .probe(.lavoro),
            .displays(.lavoro)
        ])
        XCTAssertEqual(outcome.state, .done(.lavoro))
        XCTAssertEqual(outcome.persistence, .success(.lavoro))
    }

    func testK9NoopHardensAndPersistsWithoutConnect() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected()])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())

        assertOperations(ops, [.probe(.lavoro), .probe(.personale)])
        XCTAssertEqual(outcome.state, .done(.lavoro))
        XCTAssertEqual(outcome.persistence, .success(.lavoro))
    }

    func testHardenWarningDoesNotChangeSuccess() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.sidecarLive])])
        ops.setHarden(.personale, [.warning("arrange: layout non applicato")])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .done(.personale))
    }

    func testK23LastLocationPersistedAfterSuccess() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.sidecarLive])])
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.persistence.lastLocation, .set(.personale))
        XCTAssertEqual(outcome.persistence.needsReconcile, false)
    }

    func testObserverReceivesIntermediateStates() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected(), Fixtures.connected(), Fixtures.connected()])
        ops.setDisplays(.personale, [Fixtures.displaysOK([Fixtures.virtual]),
                                     Fixtures.displaysOK([Fixtures.sidecarLive])])
        let collector = StateCollector()
        let machine = makeMachine(ops, observer: { state in
            collector.append(state)
        })

        _ = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        let captured = collector.states
        XCTAssertTrue(captured.contains(.probing))
        XCTAssertTrue(captured.contains(.preflight))
        XCTAssertTrue(captured.contains(.disconnectingSource(.lavoro)))
        XCTAssertTrue(captured.contains(.connectingTarget(.personale, attempt: 1)))
        XCTAssertTrue(captured.contains(.verifyingTarget(.personale, display: true)))
        XCTAssertTrue(captured.contains(.hardening(.personale)))
        XCTAssertEqual(captured.last, .done(.personale))
    }
}
