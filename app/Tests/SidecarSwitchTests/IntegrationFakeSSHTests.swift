import XCTest
@testable import SidecarSwitchCore

final class IntegrationFakeSSHTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup {
            try? FileManager.default.removeItem(at: url)
        }
        cleanup = []
        super.tearDown()
    }

    private func temp(_ label: String) throws -> URL {
        let url = try makeTempDirectory(label)
        cleanup.append(url)
        return url
    }

    private func writeExecutable(_ url: URL, _ content: String) throws {
        try Data(content.utf8).write(to: url)
        chmod(url.path, 0o755)
    }

    private func makeFakeTools() throws -> (tools: URL, calls: URL) {
        let tools = try temp("fake-tools")
        let calls = tools.appendingPathComponent("calls.log")
        try writeExecutable(tools.appendingPathComponent("SidecarLauncher"), """
        #!/bin/sh
        if [ -n "$CALLS" ]; then echo "SidecarLauncher $1" >> "$CALLS"; fi
        case "$1" in
          devices) echo "iPad"; exit 0;;
          connect) rm -f "$(dirname "$0")/released"; echo "connected"; exit 0;;
          disconnect) touch "$(dirname "$0")/released"; echo "disconnected"; exit 0;;
        esac
        exit 1
        """)
        try writeExecutable(tools.appendingPathComponent("connected"), """
        #!/bin/sh
        if [ -f "$(dirname "$0")/released" ]; then
          echo "connected=0"
          exit 1
        fi
        echo "connected=1"
        echo "device=iPad"
        exit 0
        """)
        try writeExecutable(tools.appendingPathComponent("dispid"), """
        #!/bin/sh
        echo "id=1 vendor=0x610 model=0x1 serial=0 builtin=true main=true active=true mirror_of=0 asleep=false 3024x1964"
        exit 0
        """)
        try writeExecutable(tools.appendingPathComponent("mirror"), "#!/bin/sh\nexit 0\n")
        try writeExecutable(tools.appendingPathComponent("arrange"), "#!/bin/sh\nexit 0\n")
        return (tools, calls)
    }

    private func makeOperations(tools: URL, sshDirectory: URL, calls: URL? = nil) throws -> (SystemOperations, URL) {
        let support = try temp("support")
        let home = try temp("home")
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "TMPDIR": home.path
        ]
        if let calls { environment["CALLS"] = calls.path }
        var remote = RemoteSettings.standard
        remote.host = "127.0.0.1"
        remote.port = 2222
        remote.user = "tester"
        remote.binaryPath = "/remote/SidecarLauncher"
        remote.connectedPath = "/remote/connected"
        remote.dispidPath = "/remote/dispid"
        remote.mirrorPath = "/remote/mirror"
        remote.arrangePath = "/remote/arrange"
        let config = OperationsConfig(
            deviceName: "iPad",
            local: LocalToolPaths.standard(toolsDirectory: tools.path),
            remote: remote,
            ssh: SSHSettings(connectTimeout: 2),
            knownHostsDirectory: support.appendingPathComponent("known-hosts-dir").path,
            legacyKnownHostsPath: nil,
            home: home,
            toolsVersion: "test",
            environment: environment,
            sshExecutable: sshDirectory.appendingPathComponent("ssh").path
        )
        return (SystemOperations(config: config, runner: SystemCommandRunner(gracePeriod: .milliseconds(300)), logging: NoopLogging()), support)
    }

    private func makeFakeSSH(_ body: String) throws -> URL {
        let directory = try temp("fake-ssh")
        try writeExecutable(directory.appendingPathComponent("ssh"), "#!/bin/sh\n" + body + "\n")
        return directory
    }

    private func lastArgumentPattern(_ body: String) -> String {
        """
        last=""
        for a in "$@"; do last="$a"; done
        {
        \(body)
        }
        """
    }

    func testProbeAuthFailureMapsToAuthFailed() async throws {
        let tools = try makeFakeTools()
        let ssh = try makeFakeSSH("echo 'Permission denied (publickey).' >&2\nexit 255")
        let (ops, _) = try makeOperations(tools: tools.tools, sshDirectory: ssh)

        let report = await ops.probe(.personale, timeout: .seconds(2))
        XCTAssertEqual(report.state, .unreachable)
        XCTAssertEqual(report.reason, .authFailed)
    }

    func testProbeHostKeyMismatch() async throws {
        let tools = try makeFakeTools()
        let ssh = try makeFakeSSH("echo 'SwitchHost key verification failed.' >&2\nexit 255")
        let (ops, _) = try makeOperations(tools: tools.tools, sshDirectory: ssh)

        let report = await ops.probe(.personale, timeout: .seconds(2))
        XCTAssertEqual(report.state, .unreachable)
        XCTAssertEqual(report.reason, .hostKeyMismatch)
    }

    func testProbeCommandNotFound127() async throws {
        let tools = try makeFakeTools()
        let ssh = try makeFakeSSH("echo 'command not found' >&2\nexit 127")
        let (ops, _) = try makeOperations(tools: tools.tools, sshDirectory: ssh)

        let report = await ops.probe(.personale, timeout: .seconds(2))
        XCTAssertEqual(report.state, .unreachable)
        XCTAssertEqual(report.reason, .remoteBootstrap)
    }

    func testProbeNotExecutable126() async throws {
        let tools = try makeFakeTools()
        let ssh = try makeFakeSSH("echo 'Permission denied' >&2\nexit 126")
        let (ops, _) = try makeOperations(tools: tools.tools, sshDirectory: ssh)

        let report = await ops.probe(.personale, timeout: .seconds(2))
        XCTAssertEqual(report.reason, .remoteBootstrap)
    }

    func testProbeRemoteCrash137() async throws {
        let tools = try makeFakeTools()
        let ssh = try makeFakeSSH("exit 137")
        let (ops, _) = try makeOperations(tools: tools.tools, sshDirectory: ssh)

        let report = await ops.probe(.personale, timeout: .seconds(2))
        XCTAssertEqual(report.state, .unreachable)
        XCTAssertEqual(report.reason, .remoteCrashed)
    }

    func testDropMidTransitionKeepsLavoroAndDoesNotDisconnect() async throws {
        let tools = try makeFakeTools()
        let counter = tools.tools.appendingPathComponent("ssh-count")
        let body = lastArgumentPattern("""
        n=$(cat '\(counter.path)' 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > '\(counter.path)'
        if [ "$n" -le 2 ]; then
          case "$last" in
            *lipo*) echo "arm64"; exit 0;;
            *connected*) echo "connected=0"; exit 1;;
          esac
        fi
        exit 255
        """)
        let ssh = try makeFakeSSH(body)
        let (ops, _) = try makeOperations(tools: tools.tools, sshDirectory: ssh, calls: tools.calls)
        let machine = StateMachine(ops: ops, timings: .fast, sleeper: TestSleeper(), deviceName: "iPad")

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .targetUnreachable))
        let calls = (try? String(contentsOf: tools.calls, encoding: .utf8)) ?? ""
        XCTAssertFalse(calls.contains("disconnect"), "nessun disconnect locale: \(calls)")
    }

    func testRemoteVdispMissingAbortsBeforeDisconnect() async throws {
        let tools = try makeFakeTools()
        let body = lastArgumentPattern("""
        case "$last" in
          *lipo*) echo "arm64"; exit 0;;
          *connected*) echo "connected=0"; exit 1;;
          *devices*) echo "iPad"; exit 0;;
          *dispid*) echo "id=1 vendor=0x610 model=0x1 serial=0 builtin=true main=true active=true mirror_of=0 asleep=false 3024x1964"; exit 0;;
          *) exit 0;;
        esac
        """)
        let ssh = try makeFakeSSH(body)
        let (ops, _) = try makeOperations(tools: tools.tools, sshDirectory: ssh, calls: tools.calls)
        let machine = StateMachine(ops: ops, timings: .fast, sleeper: TestSleeper(), deviceName: "iPad")

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())

        XCTAssertEqual(outcome.state, .failed(.lavoro, .preflightRemoteVdispMissing))
        let calls = (try? String(contentsOf: tools.calls, encoding: .utf8)) ?? ""
        XCTAssertFalse(calls.contains("disconnect"), "nessun disconnect locale: \(calls)")
    }

    func testSuccessfulRemoteToggleWithFakeSSH() async throws {
        let tools = try makeFakeTools()
        let counter = tools.tools.appendingPathComponent("connected-count")
        let body = lastArgumentPattern("""
        case "$last" in
          *lipo*) echo "arm64"; exit 0;;
          *disconnect*) echo "disconnected"; exit 0;;
          *connected*)
            n=$(cat '\(counter.path)' 2>/dev/null || echo 0)
            n=$((n + 1))
            echo "$n" > '\(counter.path)'
            if [ "$n" -le 1 ]; then echo "connected=0"; exit 1; fi
            echo "connected=1"; echo "device=iPad"; exit 0;;
          *connect*) echo "connected"; exit 0;;
          *devices*) echo "iPad"; exit 0;;
          *dispid*) echo "id=3 vendor=0x5644 model=0x1 serial=0 builtin=false main=true active=true mirror_of=0 asleep=false 1321x918"; echo "id=4 vendor=0x6161706c model=0x69506164 serial=0 builtin=false main=false active=true mirror_of=0 asleep=false 1321x918"; exit 0;;
          *) exit 0;;
        esac
        """)
        let ssh = try makeFakeSSH(body)
        let (ops, _) = try makeOperations(tools: tools.tools, sshDirectory: ssh, calls: tools.calls)
        let machine = StateMachine(ops: ops, timings: .fast, sleeper: TestSleeper(), deviceName: "iPad")

        let outcome = await machine.toggle(target: .personale, transitionID: UUID(), token: CancellationToken())
        XCTAssertEqual(outcome.state, .done(.personale))

        let calls = (try? String(contentsOf: tools.calls, encoding: .utf8)) ?? ""
        XCTAssertTrue(calls.contains("disconnect"), calls)
        XCTAssertTrue(calls.contains("connect"), calls)
    }

    func testSSHArgumentsCarryRequiredOptions() async throws {
        let tools = try makeFakeTools()
        let log = tools.tools.appendingPathComponent("ssh-args.log")
        let body = lastArgumentPattern("""
        echo "$*" >> '\(log.path)'
        case "$last" in
          *lipo*) echo "arm64"; exit 0;;
          *connected*) echo "connected=1"; echo "device=iPad"; exit 0;;
          *) exit 0;;
        esac
        """)
        let ssh = try makeFakeSSH(body)
        let (ops, _) = try makeOperations(tools: tools.tools, sshDirectory: ssh)

        _ = await ops.probe(.personale, timeout: .seconds(2))
        let recorded = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(recorded.contains("-i"))
        XCTAssertTrue(recorded.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(recorded.contains("BatchMode=yes"))
        XCTAssertTrue(recorded.contains("ConnectTimeout=2"))
        XCTAssertTrue(recorded.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(recorded.contains("UserKnownHostsFile="))
        XCTAssertTrue(recorded.contains("-T"))
        XCTAssertTrue(recorded.contains("-p 2222"))
        XCTAssertTrue(recorded.contains("tester@127.0.0.1"))
    }

    func testLocalToolsExecute() async throws {
        let tools = try makeFakeTools()
        let ssh = try makeFakeSSH("exit 255")
        let (ops, _) = try makeOperations(tools: tools.tools, sshDirectory: ssh)

        let probe = await ops.probe(.lavoro, timeout: .seconds(2))
        XCTAssertEqual(probe.state, .connected(devices: ["iPad"]))
        let devices = await ops.devices(.lavoro, timeout: .seconds(2))
        XCTAssertEqual(devices.status, .ok)
        XCTAssertEqual(devices.names, ["iPad"])
        let displays = await ops.displays(.lavoro, timeout: .seconds(2))
        XCTAssertTrue(DisplayRule.hasBuiltin(displays.displays))
    }

    func testRunnerTimeoutKillsAndReaps() async throws {
        let directory = try temp("runner-kill")
        let script = directory.appendingPathComponent("stubborn.sh")
        let pidFile = directory.appendingPathComponent("pid")
        try writeExecutable(script, """
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(pidFile.path)"
        while :; do sleep 0.05; done
        """)

        let runner = SystemCommandRunner(gracePeriod: .milliseconds(300))
        let start = Date()
        let result = await runner.run(
            CommandSpec(executable: script.path, arguments: [], environment: [:]),
            timeout: .milliseconds(300)
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(elapsed, 5)
        try? await Task.sleep(for: .milliseconds(200))
        let text = (try? String(contentsOf: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pid = try XCTUnwrap(Int32(text))
        XCTAssertNotEqual(kill(pid, 0), 0, "il processo deve essere stato ucciso e reaped")
    }

    func testRunnerCapturesLargeOutputWithoutDeadlock() async throws {
        let directory = try temp("runner-output")
        let script = directory.appendingPathComponent("flood.sh")
        try writeExecutable(script, """
        #!/bin/sh
        i=0
        while [ $i -lt 2000 ]; do
          echo "riga numero $i con contenuto"
          i=$((i + 1))
        done
        """)
        let runner = SystemCommandRunner(gracePeriod: .milliseconds(200), outputLimit: 4096)
        let result = await runner.run(CommandSpec(executable: script.path), timeout: .seconds(5))
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("<output troncato>"))
        XCTAssertTrue(result.stdout.count < 6000)
    }
}
