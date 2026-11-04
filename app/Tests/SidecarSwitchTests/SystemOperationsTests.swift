import XCTest
@testable import SidecarSwitchCore

final class SystemOperationsTests: XCTestCase {
    private func remote() -> RemoteSettings {
        RemoteSettings(
            host: "personale.local",
            user: "utente",
            port: 22,
            identityFile: "~/.ssh/id_ed25519_sidecar_switch",
            binaryPath: "/remote/SidecarLauncher",
            connectedPath: "/remote/connected",
            dispidPath: "/remote/dispid",
            mirrorPath: "/remote/mirror",
            arrangePath: "/remote/arrange"
        )
    }

    private func makeOperations(home: URL, runner: any CommandRunning,
                                sleeper: any Sleeping = TestSleeper()) -> SystemOperations {
        let config = OperationsConfig(
            deviceName: "iPad",
            local: LocalToolPaths.standard(toolsDirectory: home.appendingPathComponent("local-tools").path),
            remote: remote(),
            ssh: SSHSettings(connectTimeout: 2),
            knownHostsDirectory: home.appendingPathComponent(".sidecar-switch").path,
            legacyKnownHostsPath: nil,
            home: home,
            toolsVersion: "test",
            environment: ["PATH": "/usr/bin:/bin"],
            sshExecutable: "/usr/bin/ssh"
        )
        return SystemOperations(config: config, runner: runner, logging: NoopLogging(),
                                sleeper: sleeper)
    }

    func testHardenLavoroRunsNoCommandEvenAtOperationsLevel() async throws {
        let home = try makeTempDirectory("ops-harden-lavoro")
        defer { try? FileManager.default.removeItem(at: home) }
        let counter = Counter()
        let runner = ClosureRunner { _ in
            _ = counter.increment()
            return CommandResult.launched(exitCode: 0)
        }
        let ops = makeOperations(home: home, runner: runner)
        let outcome = await ops.harden(.lavoro, timeout: .seconds(1))
        XCTAssertEqual(outcome, .ok)
        XCTAssertEqual(counter.value, 0)
    }

    func testK62HardenPersonaleSkipArrangeRunsNoCommand() async throws {
        let home = try makeTempDirectory("ops-harden-skip")
        defer { try? FileManager.default.removeItem(at: home) }
        let counter = Counter()
        let runner = ClosureRunner { _ in
            _ = counter.increment()
            return CommandResult.launched(exitCode: 0)
        }
        let ops = makeOperations(home: home, runner: runner)
        let outcome = await ops.harden(.personale, timeout: .seconds(1), skipArrange: true)
        XCTAssertEqual(outcome, .ok)
        XCTAssertEqual(counter.value, 0)
    }

    func testHardenPersonaleUsesArrangeAndNeverMirror() async throws {
        let home = try makeTempDirectory("ops-harden-personale")
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = ClosureRunner { spec in
            if spec.arguments.last?.contains("lipo -archs") == true {
                return CommandResult.launched(exitCode: 0, stdout: "arm64\n")
            }
            return CommandResult.launched(exitCode: 0)
        }
        let ops = makeOperations(home: home, runner: runner)
        let outcome = await ops.harden(.personale, timeout: .seconds(2))
        XCTAssertEqual(outcome, .ok)
        let commands = runner.specs.compactMap { $0.arguments.last }
        XCTAssertTrue(commands.contains { $0.contains("/remote/arrange") }, "\(commands)")
        XCTAssertFalse(commands.contains { $0.contains("/remote/mirror") }, "\(commands)")
    }

    func testK45RemoteProbeRetriesColdTunnelWithinBudget() async throws {
        let home = try makeTempDirectory("ops-probe-retry")
        defer { try? FileManager.default.removeItem(at: home) }
        let connectedAttempts = Counter()
        let sleeper = RecordingSleeper()
        let runner = ClosureRunner { spec in
            if spec.arguments.last?.contains("lipo -archs") == true {
                return CommandResult.launched(exitCode: 0, stdout: "arm64\n")
            }
            if spec.arguments.last?.contains("/remote/connected") == true {
                let n = connectedAttempts.increment()
                if n == 1 {
                    Thread.sleep(forTimeInterval: 0.01)
                    return CommandResult.launched(exitCode: 255,
                                                  stderr: "Connection timed out during banner exchange")
                }
                return CommandResult.launched(exitCode: 0, stdout: "connected=1\ndevice=iPad\n")
            }
            if spec.arguments.contains("-G") {
                return CommandResult.launched(exitCode: 0, stdout: "port 22\n")
            }
            return CommandResult.launched(exitCode: 0)
        }
        let ops = makeOperations(home: home, runner: runner, sleeper: sleeper)
        let start = Date()
        let report = await ops.probe(.personale, timeout: .seconds(5))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(report.state, .connected(devices: ["iPad"]))
        XCTAssertEqual(connectedAttempts.value, 2)
        XCTAssertEqual(sleeper.durations.filter { $0 == .seconds(2) }.count, 1)
        XCTAssertLessThan(elapsed, 5)
        XCTAssertLessThanOrEqual(sleeper.durations.reduce(Duration.zero, +).inSeconds,
                                 Timings.standard.remoteRetryBudget.inSeconds)
    }

    func testSSHSpecOmitsConfigPathWhenFileMissingAndAddsItWhenPresent() async throws {
        let home = try makeTempDirectory("ops-ssh-config")
        defer { try? FileManager.default.removeItem(at: home) }
        let firstSpec = SpecBox()
        let first = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh" { firstSpec.value = spec }
            return CommandResult.launched(exitCode: 0)
        }
        let store1 = HostKeyStore(directory: home.appendingPathComponent("kh1"), legacyPath: nil,
                                  runner: first, logging: NoopLogging())
        let transport1 = SSHTransport(remote: remote(), ssh: SSHSettings(connectTimeout: 2),
                                      knownHosts: store1, runner: first, logging: NoopLogging(),
                                      home: home, environment: ["PATH": "/usr/bin:/bin"],
                                      sleeper: TestSleeper())
        _ = await transport1.execute("'/remote/connected'", timeout: .seconds(1))
        XCTAssertFalse(try XCTUnwrap(firstSpec.value).arguments.contains("-F"))

        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try Data("Host personale.local\n".utf8).write(to: home.appendingPathComponent(".ssh/config"))
        let secondSpec = SpecBox()
        let second = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh" { secondSpec.value = spec }
            return CommandResult.launched(exitCode: 0)
        }
        let store2 = HostKeyStore(directory: home.appendingPathComponent("kh2"), legacyPath: nil,
                                  runner: second, logging: NoopLogging())
        let transport2 = SSHTransport(remote: remote(), ssh: SSHSettings(connectTimeout: 2),
                                      knownHosts: store2, runner: second, logging: NoopLogging(),
                                      home: home, environment: ["PATH": "/usr/bin:/bin"],
                                      sleeper: TestSleeper())
        _ = await transport2.execute("'/remote/connected'", timeout: .seconds(1))
        let args = try XCTUnwrap(secondSpec.value).arguments
        let index = try XCTUnwrap(args.firstIndex(of: "-F"))
        XCTAssertEqual(args[index + 1], home.appendingPathComponent(".ssh/config").path)
        XCTAssertFalse(args.contains("/dev/null"))
    }

    func testTransportNeverInvokesSSHKeyscan() async throws {
        let home = try makeTempDirectory("ops-no-keyscan")
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = ClosureRunner { _ in CommandResult.launched(exitCode: 0) }
        let store = HostKeyStore(directory: home.appendingPathComponent("kh"), legacyPath: nil,
                                 runner: runner, logging: NoopLogging())
        let transport = SSHTransport(remote: remote(), ssh: SSHSettings(connectTimeout: 2),
                                     knownHosts: store, runner: runner, logging: NoopLogging(),
                                     home: home, environment: ["PATH": "/usr/bin:/bin"],
                                     sleeper: TestSleeper())
        _ = await transport.execute("'/remote/connected'", timeout: .seconds(1))
        XCTAssertFalse(runner.specs.contains { $0.executable.contains("ssh-keyscan") })
        XCTAssertFalse(runner.specs.contains { $0.arguments.contains(where: { $0.contains("ssh-keyscan") }) })
    }
}

final class HostKeyAuditOnceTests: XCTestCase {
    private var remote: RemoteSettings {
        RemoteSettings(host: "personale.local", user: "utente", port: 22,
                       identityFile: "~/.ssh/id_ed25519_sidecar_switch",
                       binaryPath: "/remote/SidecarLauncher", connectedPath: "/remote/connected",
                       dispidPath: "/remote/dispid", mirrorPath: "/remote/mirror",
                       arrangePath: "/remote/arrange")
    }

    func testK40FingerprintAuditRunsOncePerRun() async throws {
        let home = try makeTempDirectory("audit-once")
        defer { try? FileManager.default.removeItem(at: home) }
        let keygenCalls = Counter()
        let runner = ClosureRunner { spec in
            switch spec.executable {
            case "/usr/bin/ssh-keygen":
                if spec.arguments.first == "-F" { _ = keygenCalls.increment() }
                return CommandResult.launched(exitCode: 0, stdout: "personale.local SHA256:once\n")
            case "/usr/bin/ssh":
                if spec.arguments.contains("-G") {
                    return CommandResult.launched(exitCode: 0, stdout: "port 22\nproxycommand cloudflared\n")
                }
                return CommandResult.launched(exitCode: 0)
            default:
                return CommandResult.launched(exitCode: 0)
            }
        }
        let store = HostKeyStore(directory: home.appendingPathComponent("kh"), legacyPath: nil,
                                 runner: runner, logging: NoopLogging())
        let transport = SSHTransport(remote: remote, ssh: SSHSettings(connectTimeout: 2),
                                     knownHosts: store, runner: runner, logging: NoopLogging(),
                                     home: home, environment: ["PATH": "/usr/bin:/bin"],
                                     sleeper: TestSleeper())
        _ = await transport.execute("'/remote/connected'", timeout: .seconds(1))
        _ = await transport.execute("'/remote/connected'", timeout: .seconds(1))
        XCTAssertEqual(keygenCalls.value, 1)
        let queries = runner.specs.filter { $0.executable == "/usr/bin/ssh" && $0.arguments.contains("-G") }
        XCTAssertEqual(queries.count, 1)
    }
}
