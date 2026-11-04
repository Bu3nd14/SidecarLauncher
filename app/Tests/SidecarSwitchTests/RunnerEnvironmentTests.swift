import XCTest
@testable import SidecarSwitchCore

final class RunnerEnvironmentTests: XCTestCase {
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

    private var loginShellSnapshot: String {
        [
            "HOME=/Users/utente",
            "USER=utente",
            "LOGNAME=utente",
            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "TMPDIR=/var/folders/tmp",
            "LANG=it_IT.UTF-8",
            "LC_ALL=it_IT.UTF-8",
            "SSH_AUTH_SOCK=/tmp/ssh-agent.sock",
            "https_proxy=http://localhost:4242",
            "HTTPS_PROXY=http://localhost:4242",
            "http_proxy=http://localhost:4242",
            "HTTP_PROXY=http://localhost:4242",
            "NO_PROXY=localhost,127.0.0.1",
            "SSL_CERT_FILE=/etc/ssl/cert.pem",
            "NODE_EXTRA_CA_CERTS=/etc/ssl/extra.pem",
            "SECRET_TOKEN=must-not-leak"
        ].joined(separator: "\0") + "\0"
    }

    func testK47K48LoginShellSnapshotFiltersAllowlistAndKeepsProxyCase() async {
        let shellText = loginShellSnapshot
        let runner = ClosureRunner { spec in
            if spec.executable.hasSuffix("zsh") || spec.executable.hasSuffix("bash") || spec.executable.hasSuffix("sh") {
                return CommandResult.launched(exitCode: 0, stdout: shellText)
            }
            return CommandResult(launchError: "unexpected")
        }
        let provider = LoginShellEnvironmentProvider(runner: runner, logging: NoopLogging(),
                                                     shellPath: "/bin/zsh", fallback: nil)
        let snapshot = await provider.capture()
        let env = try? XCTUnwrap(snapshot?.variables)
        XCTAssertEqual(env?["https_proxy"], "http://localhost:4242")
        XCTAssertEqual(env?["HTTPS_PROXY"], "http://localhost:4242")
        XCTAssertEqual(env?["http_proxy"], "http://localhost:4242")
        XCTAssertEqual(env?["HTTP_PROXY"], "http://localhost:4242")
        XCTAssertEqual(env?["SSL_CERT_FILE"], "/etc/ssl/cert.pem")
        XCTAssertEqual(env?["NODE_EXTRA_CA_CERTS"], "/etc/ssl/extra.pem")
        XCTAssertEqual(env?["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        XCTAssertEqual(env?["SSH_AUTH_SOCK"], "/tmp/ssh-agent.sock")
        XCTAssertNil(env?["SECRET_TOKEN"])
        XCTAssertEqual(snapshot?.proxyAvailable, true)
    }

    func testK48TransportUsesDerivedLoginShellEnvironment() async throws {
        let home = try makeTempDirectory("runner-env")
        defer { try? FileManager.default.removeItem(at: home) }
        let spec = SpecBox()
        let shellText = loginShellSnapshot
        let runner = ClosureRunner { command in
            if command.executable == "/bin/zsh" {
                return CommandResult.launched(exitCode: 0, stdout: shellText)
            }
            if command.executable == "/usr/bin/ssh" { spec.value = command }
            return CommandResult.launched(exitCode: 0, stdout: "ok")
        }
        let provider = LoginShellEnvironmentProvider(runner: runner, logging: NoopLogging(),
                                                     shellPath: "/bin/zsh", fallback: nil)
        let store = HostKeyStore(directory: home.appendingPathComponent(".sidecar-switch"),
                                 legacyPath: nil, runner: runner, logging: NoopLogging())
        let transport = SSHTransport(remote: remote, ssh: SSHSettings(connectTimeout: 2),
                                     knownHosts: store, runner: runner, logging: NoopLogging(),
                                     home: home, environmentProvider: provider,
                                     sleeper: TestSleeper())
        _ = await transport.execute("'/remote/connected'", timeout: .seconds(2))

        let env = try XCTUnwrap(spec.value?.environment)
        XCTAssertEqual(env["https_proxy"], "http://localhost:4242")
        XCTAssertEqual(env["SSL_CERT_FILE"], "/etc/ssl/cert.pem")
        XCTAssertEqual(env["HOME"], "/Users/utente")
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        XCTAssertNil(env["SECRET_TOKEN"])
    }

    func testK47SshWithoutProxyFailsAndWithDerivedProxySucceeds() async throws {
        let home = try makeTempDirectory("runner-proxy")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = HostKeyStore(directory: home.appendingPathComponent(".sidecar-switch"),
                                 legacyPath: nil, runner: ClosureRunner { _ in CommandResult(launchError: "skip") },
                                 logging: NoopLogging())

        let shellText = loginShellSnapshot
        let withoutProxy = ClosureRunner { command in
            if command.executable == "/bin/zsh" {
                return CommandResult.launched(exitCode: 0, stdout: "HOME=/Users/utente\0PATH=/usr/bin:/bin\0")
            }
            let env = command.environment ?? [:]
            if env["https_proxy"] == nil && env["HTTPS_PROXY"] == nil {
                return CommandResult.launched(exitCode: 255, stderr: "Connection timed out during banner exchange")
            }
            return CommandResult.launched(exitCode: 0)
        }
        let providerWithout = LoginShellEnvironmentProvider(runner: withoutProxy, logging: NoopLogging(),
                                                            shellPath: "/bin/zsh", fallback: nil)
        let transportWithout = SSHTransport(remote: remote, ssh: SSHSettings(connectTimeout: 2),
                                            knownHosts: store, runner: withoutProxy, logging: NoopLogging(),
                                            home: home, environmentProvider: providerWithout,
                                            sleeper: TestSleeper())
        let failed = await transportWithout.execute("'/remote/connected'", timeout: .seconds(2))
        XCTAssertEqual(failed.exitCode, 255)

        let withProxy = ClosureRunner { command in
            if command.executable == "/bin/zsh" {
                return CommandResult.launched(exitCode: 0, stdout: shellText)
            }
            let env = command.environment ?? [:]
            if env["https_proxy"] == nil && env["HTTPS_PROXY"] == nil {
                return CommandResult.launched(exitCode: 255, stderr: "Connection timed out during banner exchange")
            }
            return CommandResult.launched(exitCode: 0)
        }
        let providerWith = LoginShellEnvironmentProvider(runner: withProxy, logging: NoopLogging(),
                                                         shellPath: "/bin/zsh", fallback: nil)
        let store2 = HostKeyStore(directory: home.appendingPathComponent("kh2"),
                                  legacyPath: nil, runner: withoutProxy, logging: NoopLogging())
        let transportWith = SSHTransport(remote: remote, ssh: SSHSettings(connectTimeout: 2),
                                         knownHosts: store2, runner: withProxy, logging: NoopLogging(),
                                         home: home, environmentProvider: providerWith,
                                         sleeper: TestSleeper())
        let success = await transportWith.execute("'/remote/connected'", timeout: .seconds(2))
        XCTAssertEqual(success.exitCode, 0)
    }

    func testK43aRunnerGuaranteesBaseEnvironmentWhenSpecEnvironmentIsNil() async throws {
        let runner = SystemCommandRunner(gracePeriod: .milliseconds(100))
        let result = await runner.run(CommandSpec(executable: "/usr/bin/env"), timeout: .seconds(5))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("HOME="))
        XCTAssertTrue(result.stdout.contains("USER="))
        XCTAssertTrue(result.stdout.contains("LOGNAME="))
        XCTAssertTrue(result.stdout.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        XCTAssertTrue(result.stdout.contains("TMPDIR="))
    }

    func testEmptySnapshotFallsBackToBaseAllowlist() async {
        let runner = ClosureRunner { _ in CommandResult.launched(exitCode: 1) }
        let log = ArrayLogging()
        let provider = LoginShellEnvironmentProvider(runner: runner, logging: log,
                                                     shellPath: "/bin/zsh", fallback: nil)
        let snapshot = await provider.capture()
        XCTAssertEqual(snapshot?.variables["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(snapshot?.proxyAvailable, false)
        XCTAssertTrue(log.messages.contains { $0.contains("proxy/CA non ereditati") })
    }

    func testProxyFallbackParsesScutil() {
        let output = """
        <dictionary> {
          HTTPEnable : 1
          HTTPPort : 4242
          HTTPProxy : 127.0.0.1
          HTTPSEnable : 1
          HTTPSPort : 4242
          HTTPSProxy : 127.0.0.1
        }
        """
        let parsed = ProxyFallback.parseScutil(output)
        XCTAssertEqual(parsed["http_proxy"], "http://127.0.0.1:4242")
        XCTAssertEqual(parsed["https_proxy"], "http://127.0.0.1:4242")
        XCTAssertEqual(parsed["HTTP_PROXY"], "http://127.0.0.1:4242")
    }

    func testLogRedactionRemovesJWTAndTokensBeforeTruncation() {
        let raw = "CF-Access-Jwt-Assertion: eyJhbGciOiJI.eyJzdWIiOiIx.c2ln ?token=ABC&code=DEF cf-access-token=GHI"
        let redacted = LogRedaction.redact(raw)
        XCTAssertFalse(redacted.contains("eyJhbGciOiJI"))
        XCTAssertFalse(redacted.contains("ABC"))
        XCTAssertFalse(redacted.contains("DEF"))
        XCTAssertFalse(redacted.contains("GHI"))
        XCTAssertTrue(redacted.contains("<redacted>"))
    }
}

final class SpecBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CommandSpec?

    var value: CommandSpec? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
