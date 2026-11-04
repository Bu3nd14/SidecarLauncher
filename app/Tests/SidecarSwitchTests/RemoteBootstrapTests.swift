import XCTest
@testable import SidecarSwitchCore

final class RemoteBootstrapTests: XCTestCase {
    private var remote: RemoteSettings {
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

    private func makeTransport(runner: any CommandRunning,
                               home: URL,
                               logging: any SwitchLogging = NoopLogging(),
                               sleeper: any Sleeping = TestSleeper(),
                               retryBudget: Duration = .seconds(40),
                               executable: String = CommandBuilder.sshExecutable)
    -> (SSHTransport, HostKeyStore, URL) {
        let directory = home.appendingPathComponent(".sidecar-switch", isDirectory: true)
        let store = HostKeyStore(directory: directory, legacyPath: nil, runner: runner, logging: logging)
        let transport = SSHTransport(remote: remote, ssh: SSHSettings(connectTimeout: 2),
                                     knownHosts: store, runner: runner, logging: logging,
                                     home: home, environment: ["PATH": "/usr/bin:/bin"],
                                     executable: executable,
                                     retryAttempts: 2, retryBackoff: .seconds(2),
                                     retryBudget: retryBudget, sleeper: sleeper)
        return (transport, store, directory)
    }

    func testArm64HandshakeSucceedsAndIsCached() async throws {
        let home = try makeTempDirectory("remote-bootstrap")
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            if spec.arguments.contains("-G") { return CommandResult.launched(exitCode: 0, stdout: "port 22\n") }
            return CommandResult.launched(exitCode: 0, stdout: "arm64\n")
        }
        let (transport, _, _) = makeTransport(runner: runner, home: home)
        let bootstrap = RemoteBootstrap(transport: transport, binaryPath: "/remote/SidecarLauncher",
                                        toolsVersion: "v1", logging: NoopLogging())

        let first = await bootstrap.ensureReady()
        XCTAssertNil(first)
        let sshCalls = runner.specs.filter { $0.executable == CommandBuilder.sshExecutable && ($0.arguments.last?.contains("lipo -archs") ?? false) }
        XCTAssertEqual(sshCalls.count, 1)
        XCTAssertTrue(sshCalls[0].arguments.last?.contains("lipo -archs") ?? false)

        let second = await bootstrap.ensureReady()
        XCTAssertNil(second)
        XCTAssertEqual(runner.specs.filter { $0.executable == CommandBuilder.sshExecutable && ($0.arguments.last?.contains("lipo -archs") ?? false) }.count, 1)
        let ready = await bootstrap.isReady
        XCTAssertTrue(ready)
    }

    func testNonArm64Fails() async throws {
        let home = try makeTempDirectory("remote-bootstrap-x86")
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            return CommandResult.launched(exitCode: 0, stdout: "x86_64\n")
        }
        let (transport, _, _) = makeTransport(runner: runner, home: home)
        let bootstrap = RemoteBootstrap(transport: transport, binaryPath: "/remote/SidecarLauncher",
                                        toolsVersion: "v1", logging: NoopLogging())
        let reason = await bootstrap.ensureReady()
        XCTAssertEqual(reason, .remoteBootstrap)
    }

    func testCommandNotFound127MapsToRemoteBootstrap() async throws {
        let home = try makeTempDirectory("remote-bootstrap-127")
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            return CommandResult.launched(exitCode: 127, stderr: "command not found")
        }
        let (transport, _, _) = makeTransport(runner: runner, home: home)
        let bootstrap = RemoteBootstrap(transport: transport, binaryPath: "/remote/SidecarLauncher",
                                        toolsVersion: "v1", logging: NoopLogging())
        let reason = await bootstrap.ensureReady()
        XCTAssertEqual(reason, .remoteBootstrap)
    }

    func testNotExecutable126MapsToRemoteBootstrap() async throws {
        let home = try makeTempDirectory("remote-bootstrap-126")
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            return CommandResult.launched(exitCode: 126, stderr: "Permission denied")
        }
        let (transport, _, _) = makeTransport(runner: runner, home: home)
        let bootstrap = RemoteBootstrap(transport: transport, binaryPath: "/remote/SidecarLauncher",
                                        toolsVersion: "v1", logging: NoopLogging())
        let reason = await bootstrap.ensureReady()
        XCTAssertEqual(reason, .remoteBootstrap)
    }

    func testAuthFailure255MapsToAuthFailed() async throws {
        let home = try makeTempDirectory("remote-bootstrap-auth")
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            return CommandResult.launched(exitCode: 255, stderr: "Permission denied (publickey).")
        }
        let (transport, _, _) = makeTransport(runner: runner, home: home)
        let bootstrap = RemoteBootstrap(transport: transport, binaryPath: "/remote/SidecarLauncher",
                                        toolsVersion: "v1", logging: NoopLogging())
        let reason = await bootstrap.ensureReady()
        XCTAssertEqual(reason, .authFailed)
    }

    func testK46BootstrapRetriesColdTunnelTwiceThenSucceeds() async throws {
        let home = try makeTempDirectory("remote-bootstrap-retry")
        defer { try? FileManager.default.removeItem(at: home) }
        let attempts = Counter()
        let sleeper = RecordingSleeper()
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            if spec.arguments.contains("-G") { return CommandResult.launched(exitCode: 0, stdout: "port 22\n") }
            let n = attempts.increment()
            if n == 1 {
                Thread.sleep(forTimeInterval: 0.01)
                return CommandResult.launched(exitCode: 255,
                                              stderr: "Connection timed out during banner exchange")
            }
            return CommandResult.launched(exitCode: 0, stdout: "arm64\n")
        }
        let (transport, _, _) = makeTransport(runner: runner, home: home, sleeper: sleeper,
                                              retryBudget: .seconds(20))
        let bootstrap = RemoteBootstrap(transport: transport, binaryPath: "/remote/SidecarLauncher",
                                        toolsVersion: "v1", logging: NoopLogging())
        let start = Date()
        let reason = await bootstrap.ensureReady()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(reason)
        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(sleeper.durations, [.seconds(2)])
        XCTAssertLessThan(elapsed, 5)
        XCTAssertLessThanOrEqual(sleeper.durations.reduce(Duration.zero, +).inSeconds,
                                 Timings.standard.bootstrapCap.inSeconds)
    }

    func testVersionWarningIsLogged() async throws {
        let home = try makeTempDirectory("remote-bootstrap-log")
        defer { try? FileManager.default.removeItem(at: home) }
        let log = ArrayLogging()
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            return CommandResult.launched(exitCode: 0, stdout: "arm64\n")
        }
        let (transport, _, _) = makeTransport(runner: runner, home: home, logging: log)
        let bootstrap = RemoteBootstrap(transport: transport, binaryPath: "/remote/SidecarLauncher",
                                        toolsVersion: "v1", logging: log)

        _ = await bootstrap.ensureReady()
        XCTAssertTrue(log.contains("TOOLS_VERSION v1"))
        XCTAssertTrue(log.messages.contains { $0.contains("skew non fatale") })
    }

    func testK39KnownHostsPathHasNoSpacesAndMigratesLegacy() throws {
        let home = try makeTempDirectory("known-hosts-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = home.appendingPathComponent("Library/Application Support/SidecarSwitch/known_hosts")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy-entry\n".utf8).write(to: legacy)

        let runner = ClosureRunner { _ in CommandResult(launchError: "skip") }
        let store = HostKeyStore(directory: home.appendingPathComponent(".sidecar-switch", isDirectory: true),
                                 legacyPath: legacy.path, runner: runner, logging: NoopLogging())
        try store.ensureFiles()

        XCTAssertFalse(store.knownHostsPath.contains(" "))
        XCTAssertEqual(store.knownHostsPath, home.appendingPathComponent(".sidecar-switch/known_hosts").path)
        XCTAssertEqual(try String(contentsOfFile: store.knownHostsPath, encoding: .utf8), "legacy-entry\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "il vecchio file non è distrutto")

        let attributes = try FileManager.default.attributesOfItem(atPath: store.knownHostsPath)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".sidecar-switch").path)
        XCTAssertEqual(((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o700)
    }

    func testK39LegacyEmptyFileMigratesAndNewWins() throws {
        let home = try makeTempDirectory("known-hosts-empty")
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = home.appendingPathComponent("Library/Application Support/SidecarSwitch/known_hosts")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: legacy)
        let runner = ClosureRunner { _ in CommandResult(launchError: "skip") }
        let store = HostKeyStore(directory: home.appendingPathComponent(".sidecar-switch", isDirectory: true),
                                 legacyPath: legacy.path, runner: runner, logging: NoopLogging())
        try store.ensureFiles()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.knownHostsPath)).count, 0)

        try Data("new-wins\n".utf8).write(to: URL(fileURLWithPath: store.knownHostsPath))
        try store.ensureFiles()
        XCTAssertEqual(try String(contentsOfFile: store.knownHostsPath, encoding: .utf8), "new-wins\n")
    }

    func testK40FingerprintAuditUsesPerMatchAndNoKeyscan() async throws {
        let home = try makeTempDirectory("known-hosts-audit")
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" {
                if spec.arguments.first == "-F" {
                    return CommandResult.launched(exitCode: 0,
                                                  stdout: "personale.local SSH-2.0-ED25519 SHA256:abc123\n")
                }
                return CommandResult.launched(exitCode: 0)
            }
            return CommandResult.launched(exitCode: 0)
        }
        let log = ArrayLogging()
        let (_, store, _) = makeTransport(runner: runner, home: home, logging: log)
        try store.ensureFiles()
        await store.recordFingerprint(host: "personale.local", port: 22)

        let keygen = runner.specs.filter { $0.executable == "/usr/bin/ssh-keygen" }
        XCTAssertEqual(keygen.count, 1)
        XCTAssertEqual(keygen[0].arguments, ["-F", "personale.local", "-l", "-f", store.knownHostsPath])
        XCTAssertTrue(log.contains("SHA256:abc123"))
        XCTAssertFalse(runner.specs.contains { $0.executable.contains("ssh-keyscan") })
    }

    func testK40CustomPortAuditUsesBracketedHost() async throws {
        let home = try makeTempDirectory("known-hosts-custom-port")
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = ClosureRunner { spec in
            guard spec.executable == "/usr/bin/ssh-keygen", spec.arguments.first == "-F" else {
                return CommandResult.launched(exitCode: 0)
            }
            if spec.arguments.contains("[personale.local]:2222") {
                return CommandResult.launched(exitCode: 0,
                                              stdout: "personale.local SSH-2.0-ED25519 SHA256:bracket\n")
            }
            return CommandResult.launched(exitCode: 1)
        }
        let log = ArrayLogging()
        let (_, store, _) = makeTransport(runner: runner, home: home, logging: log)
        try store.ensureFiles()
        await store.recordFingerprint(host: "personale.local", port: 2222)

        let patterns = runner.specs
            .filter { $0.executable == "/usr/bin/ssh-keygen" && $0.arguments.first == "-F" }
            .map { $0.arguments[1] }
        XCTAssertEqual(patterns, ["[personale.local]:2222"])
        XCTAssertTrue(log.contains("SHA256:bracket"))
    }

    func testK40ForgetHostKeyUsesDashR() async throws {
        let home = try makeTempDirectory("known-hosts-forget")
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = ClosureRunner { _ in CommandResult.launched(exitCode: 0) }
        let (_, store, _) = makeTransport(runner: runner, home: home)
        try store.ensureFiles()

        let ok = await store.forget(host: "personale.local", port: 2222)
        XCTAssertTrue(ok)
        let removals = runner.specs.filter { $0.arguments.first == "-R" }
        XCTAssertEqual(removals.count, 2)
        XCTAssertTrue(removals[0].arguments.contains("[personale.local]:2222"))
        XCTAssertTrue(removals[1].arguments.contains("personale.local"))
    }

    func testK41Port22EmitsNoDashP() throws {
        let args = try CommandBuilder.sshArguments(remote: remote, ssh: SSHSettings(connectTimeout: 15),
                                                   knownHostsPath: "/tmp/known_hosts", command: "true",
                                                   firstConnect: false, home: URL(fileURLWithPath: "/tmp"))
        XCTAssertFalse(args.contains("-p"))
    }

    func testK41CustomPortEmitsDashP() throws {
        var custom = remote
        custom.port = 2222
        let args = try CommandBuilder.sshArguments(remote: custom, ssh: SSHSettings(connectTimeout: 15),
                                                   knownHostsPath: "/tmp/known_hosts", command: "true",
                                                   firstConnect: false, home: URL(fileURLWithPath: "/tmp"))
        let index = try XCTUnwrap(args.firstIndex(of: "-p"))
        XCTAssertEqual(args[index + 1], "2222")
    }

    func testK42TransportRetriesWhitelisted255Twice() async throws {
        let home = try makeTempDirectory("transport-retry")
        defer { try? FileManager.default.removeItem(at: home) }
        let attempts = Counter()
        let sleeper = RecordingSleeper()
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            if spec.arguments.contains("-G") { return CommandResult.launched(exitCode: 0, stdout: "port 22\n") }
            let n = attempts.increment()
            if n == 1 {
                return CommandResult.launched(exitCode: 255, stderr: "Connection reset by peer")
            }
            return CommandResult.launched(exitCode: 0, stdout: "ok")
        }
        let (transport, _, _) = makeTransport(runner: runner, home: home, sleeper: sleeper,
                                              retryBudget: .seconds(20))
        transport.resetGroup(.probe)
        let result = await transport.execute("'/x/connected'", timeout: .seconds(5), retryGroup: .probe)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(sleeper.durations, [.seconds(2)])
    }

    func testK42TransportDoesNotRetryUnrecognizedOrAuth() async throws {
        for stderr in ["some unexpected failure", "Permission denied (publickey)."] {
            let home = try makeTempDirectory("transport-no-retry")
            defer { try? FileManager.default.removeItem(at: home) }
            let attempts = Counter()
            let sleeper = RecordingSleeper()
            let runner = ClosureRunner { spec in
                if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
                _ = attempts.increment()
                return CommandResult.launched(exitCode: 255, stderr: stderr)
            }
            let (transport, _, _) = makeTransport(runner: runner, home: home, sleeper: sleeper,
                                                  retryBudget: .seconds(20))
            transport.resetGroup(.probe)
            _ = await transport.execute("'/x/connected'", timeout: .seconds(5), retryGroup: .probe)
            XCTAssertEqual(attempts.value, 1, "stderr: \(stderr)")
            XCTAssertTrue(sleeper.durations.isEmpty, "stderr: \(stderr)")
        }
    }

    func testK49Unrecognized255LogsActionableRedactedHintWithoutRetry() async throws {
        let home = try makeTempDirectory("transport-hint")
        defer { try? FileManager.default.removeItem(at: home) }
        let log = ArrayLogging()
        let attempts = Counter()
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            _ = attempts.increment()
            return CommandResult.launched(exitCode: 255,
                                          stderr: "auth failed cf-access-token=SECRET?token=ABC Authorization: CF-Access-Jwt-Assertion: eyJhbGciOiJI.eyJzdWIiOiIx.c2ln")
        }
        let (transport, _, _) = makeTransport(runner: runner, home: home, logging: log)
        transport.resetGroup(.probe)
        _ = await transport.execute("'/x/connected'", timeout: .seconds(5), retryGroup: .probe)

        XCTAssertEqual(attempts.value, 1)
        let joined = log.messages.joined(separator: "\n")
        XCTAssertTrue(joined.contains("config SSH o proxy/CA non applicati? controlla VPN/rete"))
        XCTAssertFalse(joined.contains("SECRET"))
        XCTAssertFalse(joined.contains("ABC"))
        XCTAssertFalse(joined.contains("eyJhbGciOiJI"))
    }

    func testK43EffectiveConfigReadsPortAndProxyCommand() async throws {
        let home = try makeTempDirectory("transport-effective")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try Data("Host personale.local\n  Port 2222\n  ProxyCommand /opt/homebrew/bin/cloudflared access ssh --hostname x\n"
            .utf8).write(to: home.appendingPathComponent(".ssh/config"))
        let runner = ClosureRunner { spec in
            XCTAssertEqual(spec.executable, "/usr/bin/ssh")
            XCTAssertTrue(spec.arguments.contains("-G"))
            XCTAssertTrue(spec.arguments.contains("-F"))
            return CommandResult.launched(
                exitCode: 0,
                stdout: "port 2222\nproxycommand /opt/homebrew/bin/cloudflared access ssh --hostname x\n"
            )
        }
        let (transport, _, _) = makeTransport(runner: runner, home: home)
        let config = await transport.effectiveConfig()
        XCTAssertEqual(config.port, 2222)
        XCTAssertTrue(config.proxyCommand?.contains("cloudflared") ?? false)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

final class TransportBudgetCapTests: XCTestCase {
    func testD8RetryStopsWhenBudgetCannotFitAnotherAttempt() async throws {
        let home = try makeTempDirectory("transport-budget-cap")
        defer { try? FileManager.default.removeItem(at: home) }
        let attempts = Counter()
        let sleeper = RecordingSleeper()
        let runner = ClosureRunner { spec in
            if spec.executable == "/usr/bin/ssh-keygen" { return CommandResult(launchError: "skip") }
            if spec.arguments.contains("-G") { return CommandResult.launched(exitCode: 0, stdout: "port 22\n") }
            _ = attempts.increment()
            return CommandResult.launched(exitCode: 255,
                                          stderr: "Connection timed out during banner exchange")
        }
        let remote = RemoteSettings(host: "personale.local", user: "utente", port: 22,
                                    identityFile: "~/.ssh/id_ed25519_sidecar_switch",
                                    binaryPath: "/remote/SidecarLauncher", connectedPath: "/remote/connected",
                                    dispidPath: "/remote/dispid", mirrorPath: "/remote/mirror",
                                    arrangePath: "/remote/arrange")
        let store = HostKeyStore(directory: home.appendingPathComponent("kh"), legacyPath: nil,
                                 runner: runner, logging: NoopLogging())
        let transport = SSHTransport(remote: remote, ssh: SSHSettings(connectTimeout: 2),
                                     knownHosts: store, runner: runner, logging: NoopLogging(),
                                     home: home, environment: ["PATH": "/usr/bin:/bin"],
                                     executable: CommandBuilder.sshExecutable,
                                     retryAttempts: 2, retryBackoff: .seconds(2),
                                     retryBudget: .seconds(1), sleeper: sleeper)
        transport.resetGroup(.probe)
        _ = await transport.execute("'/remote/connected'", timeout: .seconds(1), retryGroup: .probe)

        XCTAssertEqual(attempts.value, 1)
        XCTAssertTrue(sleeper.durations.isEmpty)
    }
}
