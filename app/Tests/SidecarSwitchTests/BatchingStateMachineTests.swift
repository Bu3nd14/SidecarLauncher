import XCTest
@testable import SidecarSwitchCore

final class BatchingStateMachineTests: XCTestCase, @unchecked Sendable {
    private let liveVirtual = Fixtures.virtual
    private let liveSidecar = Fixtures.sidecarLive

    private func prereqSections(devicesExit: Int32 = 0, devicesText: String = "iPad",
                                dispidExit: Int32 = 0,
                                dispidText: String = "id=3 vendor=0x5644 main=true active=true asleep=false") -> BatchExecution {
        .sections([
            RemoteSectionResult(section: "devices", exitCode: devicesExit, content: devicesText),
            RemoteSectionResult(section: "dispid", exitCode: dispidExit, content: dispidText)
        ])
    }

    private func verifySections(aConnected: Bool = true, bConnected: Bool = true,
                                dispid: String) -> BatchExecution {
        let a = aConnected ? "connected=1\ndevice=iPad" : "connected=0"
        let b = bConnected ? "connected=1\ndevice=iPad" : "connected=0"
        return .sections([
            RemoteSectionResult(section: "connected_a", exitCode: aConnected ? 0 : 1, content: a),
            RemoteSectionResult(section: "connected_b", exitCode: bConnected ? 0 : 1, content: b),
            RemoteSectionResult(section: "dispid", exitCode: 0, content: dispid)
        ])
    }

    private func installBatch(_ ops: RecordingOperations, _ handler: @escaping @Sendable (RemoteBatchKind) -> BatchExecution) {
        ops.batchExecutor = handler
    }

    func testK56CompletedEmptyBatchFallsBackToSeparate() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setDevices(.personale, [Fixtures.devicesFailed(.exited(2))])
        installBatch(ops) { kind in
            kind == .prereqs ? .parseFailed(.emptyOutput) : .transport(.targetUnreachable)
        }
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .preflightRemote))
        XCTAssertEqual(ops.count(of: .devices(.personale)), 1)
        XCTAssertEqual(ops.count(of: .displays(.personale)), 0)
    }

    func testK58TransportFailureDoesNotFallback() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        installBatch(ops) { _ in .transport(.targetUnreachable) }
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .targetUnreachable))
        XCTAssertEqual(ops.count(of: .devices(.personale)), 0)
        XCTAssertEqual(ops.count(of: .displays(.personale)), 0)
    }

    func testK59InvalidMarkersFallbackToSeparate() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setDevices(.personale, [Fixtures.devicesFailed(.exited(2))])
        installBatch(ops) { kind in
            kind == .prereqs ? .parseFailed(.invalidStructure("marker duplicato")) : .transport(.targetUnreachable)
        }
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .preflightRemote))
        XCTAssertEqual(ops.count(of: .devices(.personale)), 1)
    }

    func testK22FallbackDispidCrashMapsToRemoteCrashed() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected()])
        ops.setDevices(.personale, [Fixtures.devicesOK()])
        ops.setDisplays(.personale, [Fixtures.displaysFailed(.transport(.remoteCrashed))])
        installBatch(ops) { _ in .parseFailed(.invalidStructure("forza fallback")) }
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .remoteCrashed))
        XCTAssertEqual(ops.count(of: .displays(.personale)), 1)
    }

    func testK55PreflightSectionExitsAreClassifiedPerSection() async {
        let devicesFail = RecordingOperations()
        devicesFail.setProbes(.lavoro, [Fixtures.connected()])
        installBatch(devicesFail) { _ in self.prereqSections(devicesExit: 2) }
        let machine1 = makeMachine(devicesFail)
        let outcome1 = await machine1.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome1.state, .failed(.lavoro, .preflightRemote))

        let dispidCrash = RecordingOperations()
        dispidCrash.setProbes(.lavoro, [Fixtures.connected()])
        installBatch(dispidCrash) { _ in self.prereqSections(dispidExit: 137) }
        let machine2 = makeMachine(dispidCrash)
        let outcome2 = await machine2.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome2.state, .failed(.lavoro, .remoteCrashed))
    }

    func testK3BatchedPreflightAndVerifyUseOneSSHSessionEach() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setConnectOutcomes([CommandOutcome(status: .ok, report: CommandReport(status: .ok))])
        let dispid = "id=3 vendor=0x5644 main=true active=true asleep=false\n" +
                     "id=4 vendor=0x6161706c active=true asleep=false mirror_of=0"
        installBatch(ops) { kind in
            switch kind {
            case .prereqs: return self.prereqSections()
            case .verify: return self.verifySections(dispid: dispid)
            }
        }
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.personale))
        assertOperations(ops, [
            .probe(.lavoro),
            .probe(.personale),
            .batch(.prereqs),
            .probe(.lavoro),
            .disconnect(.lavoro, "iPad"),
            .probe(.lavoro),
            .devices(.personale),
            .connect(.personale, "iPad"),
            .batch(.verify),
            .harden(.personale)
        ])
    }

    private func preparedVerify(_ ops: RecordingOperations) {
        ops.setProbes(.lavoro, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setDisplays(.personale, [])
    }

    func testK60VerifyUsesOneBatchSessionAndTwoSamples() async {
        let ops = RecordingOperations()
        preparedVerify(ops)
        installBatch(ops) { kind in
            switch kind {
            case .prereqs:
                return self.prereqSections()
            case .verify:
                return self.verifySections(dispid: "id=3 vendor=0x5644 main=true active=true asleep=false\nid=4 vendor=0x6161706c active=true asleep=false mirror_of=0")
            }
        }
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.personale))
        XCTAssertEqual(ops.count(of: .batch(.verify)), 1)
        XCTAssertEqual(ops.count(of: .probe(.personale)), 1)
        XCTAssertEqual(ops.count(of: .displays(.personale)), 0)
    }

    func testK61VerifyBatchDispidNotLivePollsSeparateDispid() async {
        let ops = RecordingOperations()
        preparedVerify(ops)
        ops.setDisplays(.personale, [Fixtures.displaysOK([liveVirtual, liveSidecar])])
        installBatch(ops) { kind in
            switch kind {
            case .prereqs:
                return self.prereqSections()
            case .verify:
                return self.verifySections(dispid: "id=3 vendor=0x5644 main=true active=true asleep=false")
            }
        }
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.personale))
        XCTAssertEqual(ops.count(of: .batch(.verify)), 1)
        XCTAssertEqual(ops.count(of: .displays(.personale)), 1)
    }

    func testK64DiscordantBatchSamplesAreUnknown() async {
        let ops = RecordingOperations()
        preparedVerify(ops)
        installBatch(ops) { kind in
            switch kind {
            case .prereqs:
                return self.prereqSections()
            case .verify:
                return self.verifySections(aConnected: true, bConnected: false, dispid: "")
            }
        }
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .targetUnknown))
        XCTAssertEqual(ops.count(of: .displays(.personale)), 0)
    }

    func testK62SkipArrangeWhenSidecarMirrorsVirtual() async {
        let ops = RecordingOperations()
        preparedVerify(ops)
        let dispid = "id=3 vendor=0x5644 main=true active=true asleep=false\n" +
                     "id=4 vendor=0x6161706c active=true asleep=false mirror_of=3"
        installBatch(ops) { kind in
            switch kind {
            case .prereqs: return self.prereqSections()
            case .verify: return self.verifySections(dispid: dispid)
            }
        }
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.personale))
        XCTAssertEqual(ops.hardenSkip(.personale), true)
    }

    func testK63FailSafeWhenMirroringIsAmbiguous() async {
        let cases = [
            "id=3 vendor=0x5644 main=true active=true asleep=false\nid=4 vendor=0x6161706c active=true asleep=false mirror_of=0",
            "id=3 vendor=0x5644 main=false active=true asleep=false\nid=4 vendor=0x6161706c active=true asleep=false mirror_of=3"
        ]
        for dispid in cases {
            let ops = RecordingOperations()
            preparedVerify(ops)
            installBatch(ops) { kind in
                switch kind {
                case .prereqs: return self.prereqSections()
                case .verify: return self.verifySections(dispid: dispid)
                }
            }
            let machine = makeMachine(ops)
            _ = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
            XCTAssertEqual(ops.hardenSkip(.personale), false, dispid)
        }
    }

    func testK63DisplayRuleFailSafeAmbiguities() {
        let virtual = Fixtures.virtual
        let asleep = DisplayInfo(id: 4, vendor: 0x6161706c, active: true, mirrors: 3, asleep: true)
        let mirrorZero = DisplayInfo(id: 4, vendor: 0x6161706c, active: true, mirrors: 0, asleep: false)
        XCTAssertFalse(DisplayRule.isSidecarMirroringVirtual([virtual, asleep]))
        XCTAssertFalse(DisplayRule.isSidecarMirroringVirtual([virtual, mirrorZero]))
        XCTAssertFalse(DisplayRule.isSidecarMirroringVirtual([virtual]))
        XCTAssertFalse(DisplayRule.isSidecarMirroringVirtual([virtual, Fixtures.sidecarLive]))
        XCTAssertFalse(DisplayRule.isSidecarMirroringVirtual([virtual, Fixtures.builtin, Fixtures.sidecarLive]))
    }
}

final class BatchingArrangePolicyTests: XCTestCase, @unchecked Sendable {
    private func mirroringDispid() -> String {
        "id=3 vendor=0x5644 main=true active=true asleep=false\n" +
        "id=4 vendor=0x6161706c active=true asleep=false mirror_of=3"
    }

    private func verifyMirroring() -> BatchExecution {
        .sections([
            RemoteSectionResult(section: "connected_a", exitCode: 0, content: "connected=1\ndevice=iPad"),
            RemoteSectionResult(section: "connected_b", exitCode: 0, content: "connected=1\ndevice=iPad"),
            RemoteSectionResult(section: "dispid", exitCode: 0, content: mirroringDispid())
        ])
    }

    func testRollbackAlwaysRunsArrangeEvenWhenMirroring() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.disconnected(), Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.connected(), Fixtures.connected(), Fixtures.disconnected(), Fixtures.disconnected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])
        ops.setConnectOutcomes([
            CommandOutcome(status: .exited(2), report: CommandReport(status: .exited(2))),
            CommandOutcome(status: .exited(2), report: CommandReport(status: .exited(2))),
            CommandOutcome(status: .ok, report: CommandReport(status: .ok))
        ])
        ops.batchExecutor = { kind in
            kind == .verify ? self.verifyMirroring() : .parseFailed(.invalidStructure("non usato"))
        }
        let machine = makeMachine(ops)

        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.personale, .targetFailedRolledBack))
        XCTAssertEqual(ops.hardenSkip(.personale), false)
        XCTAssertEqual(ops.count(of: .harden(.personale)), 1)
    }

    func testReconcileAlwaysRunsArrangeEvenWhenMirroring() async {
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected()])
        ops.setProbes(.personale, [Fixtures.disconnected()])
        ops.setConnectOutcomes([CommandOutcome(status: .ok, report: CommandReport(status: .ok))])
        ops.batchExecutor = { kind in
            kind == .verify ? self.verifyMirroring() : .parseFailed(.invalidStructure("non usato"))
        }
        let machine = makeMachine(ops)

        let outcome = await machine.reconcile(target: .personale, transitionID: UUID(),
                                              token: CancellationToken())

        XCTAssertEqual(outcome.state, .done(.personale))
        XCTAssertEqual(ops.hardenSkip(.personale), false)
        XCTAssertEqual(ops.count(of: .harden(.personale)), 1)
    }
}
