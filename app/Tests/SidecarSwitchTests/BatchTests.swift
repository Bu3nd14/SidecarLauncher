import XCTest
@testable import SidecarSwitchCore

final class BatchParserTests: XCTestCase {
    private let nonce = "0123456789abcdef"

    private func begin(_ section: String) -> String { BatchProtocol.begin(section, nonce: nonce) }
    private func end(_ section: String, _ code: Int32) -> String { BatchProtocol.end(section, nonce: nonce, exitCode: code) }

    func testK54HappyPathKeepsContentUntrimmed() throws {
        let stdout = [
            begin("devices"),
            "  iPad  ",
            end("devices", 0),
            begin("dispid"),
            "id=3 vendor=0x5644",
            end("dispid", 0),
            ""
        ].joined(separator: "\n")

        let result = try BatchParser.parse(nonce: nonce, stdout: stdout,
                                           expected: ["devices", "dispid"]).get()
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].section, "devices")
        XCTAssertEqual(result[0].exitCode, 0)
        XCTAssertEqual(result[0].content, "  iPad  ")
        XCTAssertEqual(result[1].section, "dispid")
        XCTAssertEqual(result[1].content, "id=3 vendor=0x5644")
    }

    func testK55MapsMixedExitsThroughExistingReports() throws {
        let stdout = [
            begin("devices"),
            "iPad",
            end("devices", 2),
            begin("dispid"),
            "id=3 vendor=0x5644",
            end("dispid", 0),
            ""
        ].joined(separator: "\n")
        let sections = try BatchParser.parse(nonce: nonce, stdout: stdout,
                                             expected: ["devices", "dispid"]).get()
        XCTAssertEqual(BatchClassification.devices(sections[0]).status, .exited(2))
        XCTAssertEqual(BatchClassification.displays(sections[1]).status, .ok)

        let crashed = RemoteSectionResult(section: "dispid", exitCode: 137, content: "")
        XCTAssertEqual(BatchClassification.displays(crashed).status, .transport(.remoteCrashed))
        let disconnected = RemoteSectionResult(section: "connected_a", exitCode: 1, content: "connected=0")
        XCTAssertEqual(BatchClassification.probe(disconnected).state, .disconnected)
    }

    func testK56EmptyOutputIsParseFailure() {
        let result = BatchParser.parse(nonce: nonce, stdout: "", expected: ["devices", "dispid"])
        XCTAssertEqual(result, .failure(.emptyOutput))
    }

    func testK59MissingDuplicateAndOutOfOrderAreFailures() {
        let missing = [begin("devices"), "iPad", end("devices", 0)].joined(separator: "\n")
        guard case .failure = BatchParser.parse(nonce: nonce, stdout: missing, expected: ["devices", "dispid"]) else {
            return XCTFail("sezione mancante deve fallire")
        }

        let duplicate = [
            begin("devices"), end("devices", 0),
            begin("devices"), end("devices", 0),
            begin("dispid"), end("dispid", 0)
        ].joined(separator: "\n")
        guard case .failure = BatchParser.parse(nonce: nonce, stdout: duplicate, expected: ["devices", "dispid"]) else {
            return XCTFail("duplicato deve fallire")
        }

        let outOfOrder = [
            begin("dispid"), end("dispid", 0),
            begin("devices"), end("devices", 0)
        ].joined(separator: "\n")
        guard case .failure = BatchParser.parse(nonce: nonce, stdout: outOfOrder, expected: ["devices", "dispid"]) else {
            return XCTFail("fuori ordine deve fallire")
        }

        let invalidExit = [
            begin("devices"), "iPad", "__SSC_END_devices_\(nonce)__exit=abc",
            begin("dispid"), end("dispid", 0)
        ].joined(separator: "\n")
        guard case .failure = BatchParser.parse(nonce: nonce, stdout: invalidExit, expected: ["devices", "dispid"]) else {
            return XCTFail("exit non numerico deve fallire")
        }
    }

    func testK57NonceValidationAndHostileDeviceDoesNotEnterBatchCommand() throws {
        XCTAssertTrue(BatchProtocol.isValidNonce(nonce))
        XCTAssertFalse(BatchProtocol.isValidNonce("__SSC_BEGIN_x__"))
        XCTAssertThrowsError(try CommandBuilder.remoteBatchCommand(
            kind: .prereqs, nonce: "NOT-A-NONCE", binaryPath: "/remote/SidecarLauncher",
            connectedPath: "/remote/connected", dispidPath: "/remote/dispid", settle: .seconds(3)
        ))

        let command = try CommandBuilder.remoteBatchCommand(
            kind: .prereqs, nonce: nonce, binaryPath: "/remote/SidecarLauncher",
            connectedPath: "/remote/connected", dispidPath: "/remote/dispid", settle: .seconds(3)
        )
        let hostileDevice = "iPad__SSC_BEGIN_devices_\(nonce)__"
        let remoteCommand = CommandBuilder.remoteCommand(remoteExecutable: "/remote/SidecarLauncher",
                                                         verb: "connect", device: hostileDevice)
        XCTAssertTrue(remoteCommand.contains(CommandBuilder.shellQuote(hostileDevice)))
        XCTAssertFalse(command.contains(hostileDevice))
        XCTAssertFalse(command.contains("sh -c"))
        XCTAssertTrue(command.contains("__SSC_BEGIN_devices_\(nonce)__"))
        XCTAssertTrue(command.contains("'$?'") || command.contains("\"$?\""))
        XCTAssertEqual(FixedNonceProvider(nonce).makeNonce(), nonce)
    }
}

final class BatchCommandTests: XCTestCase {
    private let nonce = "fedcba9876543210"

    func testK53PrereqsCommandHasOneSessionAndQuotedPaths() throws {
        let command = try CommandBuilder.remoteBatchCommand(
            kind: .prereqs, nonce: nonce,
            binaryPath: "/Users/utente/SidecarLauncher/tools/bin/SidecarLauncher",
            connectedPath: "/Users/utente/SidecarLauncher/tools/bin/connected",
            dispidPath: "/Users/utente/SidecarLauncher/tools/bin/dispid",
            settle: .seconds(3)
        )
        XCTAssertTrue(command.contains("'/Users/utente/SidecarLauncher/tools/bin/SidecarLauncher' devices"))
        XCTAssertTrue(command.contains("'/Users/utente/SidecarLauncher/tools/bin/dispid'"))
        XCTAssertTrue(command.contains("__SSC_BEGIN_devices_\(nonce)__"))
        XCTAssertTrue(command.contains("__SSC_END_devices_\(nonce)__exit=%d"))
        XCTAssertFalse(command.contains("sleep"))
        XCTAssertFalse(command.contains("sh -c"))
    }

    func testK53VerifyCommandHasSleepAndTwoConnected() throws {
        let command = try CommandBuilder.remoteBatchCommand(
            kind: .verify, nonce: nonce,
            binaryPath: "/remote/SidecarLauncher",
            connectedPath: "/remote/connected",
            dispidPath: "/remote/dispid",
            settle: .seconds(3)
        )
        XCTAssertEqual(command.components(separatedBy: "'/remote/connected'").count - 1, 2)
        XCTAssertTrue(command.contains("sleep 3"))
        XCTAssertTrue(command.contains("__SSC_BEGIN_connected_a_\(nonce)__"))
        XCTAssertTrue(command.contains("__SSC_BEGIN_connected_b_\(nonce)__"))
        XCTAssertFalse(command.contains("sh -c"))
    }
}

final class SystemOperationsBatchTests: XCTestCase, @unchecked Sendable {
    private let nonce = "0123456789abcdef"

    private func remote() -> RemoteSettings {
        RemoteSettings(host: "personale.local", user: "utente", port: 22,
                       identityFile: "~/.ssh/id_ed25519_sidecar_switch",
                       binaryPath: "/remote/SidecarLauncher", connectedPath: "/remote/connected",
                       dispidPath: "/remote/dispid", mirrorPath: "/remote/mirror",
                       arrangePath: "/remote/arrange")
    }

    private func makeOperations(home: URL, runner: any CommandRunning,
                                sleeper: any Sleeping = TestSleeper()) -> SystemOperations {
        let config = OperationsConfig(
            deviceName: "iPad",
            local: LocalToolPaths.standard(toolsDirectory: home.appendingPathComponent("tools").path),
            remote: remote(),
            ssh: SSHSettings(connectTimeout: 2),
            knownHostsDirectory: home.appendingPathComponent(".sidecar-switch").path,
            legacyKnownHostsPath: nil,
            home: home,
            toolsVersion: "test",
            environment: ["PATH": "/usr/bin:/bin"],
            sshExecutable: "/usr/bin/ssh"
        )
        return SystemOperations(config: config, runner: runner, logging: NoopLogging(), sleeper: sleeper)
    }

    private func prereqOutput() -> String {
        [
            BatchProtocol.begin("devices", nonce: nonce),
            "iPad",
            BatchProtocol.end("devices", nonce: nonce, exitCode: 0),
            BatchProtocol.begin("dispid", nonce: nonce),
            "id=3 vendor=0x5644",
            BatchProtocol.end("dispid", nonce: nonce, exitCode: 0),
            ""
        ].joined(separator: "\n")
    }

    func testK53OneSSHSessionExecutesPrereqBatch() async throws {
        let home = try makeTempDirectory("ops-batch-one")
        defer { try? FileManager.default.removeItem(at: home) }
        let batchCommands = Counter()
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            if spec.arguments.last?.contains("lipo -archs") == true {
                return CommandResult.launched(exitCode: 0, stdout: "arm64\n")
            }
            if spec.arguments.last?.contains("__SSC_BEGIN_devices_\(self.nonce)__") == true {
                _ = batchCommands.increment()
                return CommandResult.launched(exitCode: 0, stdout: self.prereqOutput())
            }
            return CommandResult.launched(exitCode: 0)
        }
        let ops = makeOperations(home: home, runner: runner)

        let execution = await ops.remoteBatch(.prereqs, nonce: nonce, settle: .seconds(3), timeout: .seconds(2))

        guard case .sections(let sections) = execution else {
            return XCTFail("attese sezioni, ottenuto \(execution)")
        }
        XCTAssertEqual(sections.map(\.section), ["devices", "dispid"])
        XCTAssertEqual(batchCommands.value, 1)
    }

    func testK58Batch255RetriesTransportWithoutFallback() async throws {
        let home = try makeTempDirectory("ops-batch-retry")
        defer { try? FileManager.default.removeItem(at: home) }
        let attempts = Counter()
        let sleeper = RecordingSleeper()
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            if spec.arguments.last?.contains("lipo -archs") == true {
                return CommandResult.launched(exitCode: 0, stdout: "arm64\n")
            }
            if spec.arguments.contains("-G") {
                return CommandResult.launched(exitCode: 0, stdout: "port 22\n")
            }
            let count = attempts.increment()
            if count == 1 {
                return CommandResult.launched(exitCode: 255,
                                              stderr: "Connection timed out during banner exchange")
            }
            return CommandResult.launched(exitCode: 0, stdout: self.prereqOutput())
        }
        let ops = makeOperations(home: home, runner: runner, sleeper: sleeper)

        let execution = await ops.remoteBatch(.prereqs, nonce: nonce, settle: .seconds(3), timeout: .seconds(2))

        guard case .sections = execution else {
            return XCTFail("il retry deve completare il batch, ottenuto \(execution)")
        }
        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(sleeper.durations, [.seconds(2)])
    }

    func testK58Exhausted255MapsToTransportReason() async throws {
        let home = try makeTempDirectory("ops-batch-255")
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            if spec.arguments.last?.contains("lipo -archs") == true {
                return CommandResult.launched(exitCode: 0, stdout: "arm64\n")
            }
            return CommandResult.launched(exitCode: 255,
                                          stderr: "Connection timed out during banner exchange")
        }
        let ops = makeOperations(home: home, runner: runner)

        let execution = await ops.remoteBatch(.prereqs, nonce: nonce, settle: .seconds(3), timeout: .seconds(2))

        XCTAssertEqual(execution, .transport(.targetUnreachable))
    }

    func testK53VerifyBatchCommandContainsSleepAndTwoConnected() async throws {
        let home = try makeTempDirectory("ops-batch-verify")
        defer { try? FileManager.default.removeItem(at: home) }
        let captured = SpecBox()
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            if spec.arguments.last?.contains("lipo -archs") == true {
                return CommandResult.launched(exitCode: 0, stdout: "arm64\n")
            }
            captured.value = spec
            return CommandResult.launched(exitCode: 0, stdout: "")
        }
        let ops = makeOperations(home: home, runner: runner)

        _ = await ops.remoteBatch(.verify, nonce: nonce, settle: .seconds(3), timeout: .seconds(2))

        let command = try XCTUnwrap(captured.value?.arguments.last)
        XCTAssertTrue(command.contains("sleep 3"))
        XCTAssertEqual(command.components(separatedBy: "'/remote/connected'").count - 1, 2)
        XCTAssertFalse(command.contains("sh -c"))
    }
}
