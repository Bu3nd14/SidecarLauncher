import Darwin
import XCTest
@testable import SidecarSwitchCore

final class FakeSSHMachine: CommandRunning, @unchecked Sendable {
    enum Mode {
        case happy
        case deadMaster
        case bindFailure
        case exitFailure
    }

    struct Invocation {
        var executable: String
        var arguments: [String]
        var environment: [String: String]?
        var timeout: Duration
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []
    private var alive: Set<String> = []
    private var creations = 0
    private var reuses = 0
    private var connectedCallIndex = 0
    private var _mode: Mode = .happy

    var connectedExits: [Int32] = []
    var failPlainConnected = false
    var whitelistFailuresRemaining = 0
    var block: Duration?
    var dispidContextual = false
    var onInvocation: (@Sendable ([String]) -> Void)?
    private var blockUntilReleased = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func blockTransportCommands(_ count: Int) {
        lock.lock()
        blockUntilReleased = count
        lock.unlock()
    }

    var blockedCount: Int {
        lock.lock(); defer { lock.unlock() }; return waiters.count
    }

    func release() {
        lock.lock()
        released = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    private func shouldBlock(_ args: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard blockUntilReleased > 0, controlVerb(args) == nil, args.contains("BatchMode=yes") else {
            return false
        }
        blockUntilReleased -= 1
        return true
    }

    private func waitForRelease() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }

    var invocations: [Invocation] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }

    var creationCount: Int {
        lock.lock(); defer { lock.unlock() }; return creations
    }

    var reuseCount: Int {
        lock.lock(); defer { lock.unlock() }; return reuses
    }

    var exitCount: Int {
        invocations.filter { controlVerb($0.arguments) != nil }.count
    }

    var checkCount: Int {
        invocations.filter { controlVerb($0.arguments) == "check" }.count
    }

    var muxInvocationCount: Int {
        invocations.filter { controlPath($0.arguments) != nil }.count
    }

    var plainInvocationCount: Int {
        invocations.filter { controlPath($0.arguments) == nil }.count
    }

    func count(containing needle: String) -> Int {
        invocations.filter { ($0.arguments.last ?? "").contains(needle) }.count
    }

    func arguments(containing needle: String) -> [[String]] {
        invocations.filter { ($0.arguments.last ?? "").contains(needle) }.map(\.arguments)
    }

    func isAlive(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return alive.contains(path)
    }

    private func controlPath(_ args: [String]) -> String? {
        var index = 0
        while index + 1 < args.count {
            if args[index] == "-o", args[index + 1].hasPrefix("ControlPath=") {
                return String(args[index + 1].dropFirst("ControlPath=".count))
            }
            index += 1
        }
        return nil
    }

    private func controlVerb(_ args: [String]) -> String? {
        guard let index = args.firstIndex(of: "-O"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func isMaster(_ args: [String]) -> Bool {
        args.contains("ControlMaster=auto")
    }

    private func recordInvocation(_ spec: CommandSpec, timeout: Duration) -> Duration? {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(Invocation(executable: spec.executable, arguments: spec.arguments,
                                   environment: spec.environment, timeout: timeout))
        return block
    }

    func run(_ spec: CommandSpec, timeout: Duration) async -> CommandResult {
        if let block = recordInvocation(spec, timeout: timeout) {
            try? await Task.sleep(for: block)
        }
        onInvocation?(spec.arguments)
        if shouldBlock(spec.arguments) {
            await waitForRelease()
        }
        return handle(spec.arguments, executable: spec.executable)
    }

    private func handle(_ args: [String], executable: String) -> CommandResult {
        if controlVerb(args) != nil {
            let path = controlPath(args) ?? ""
            lock.lock()
            alive.remove(path)
            let failure = _mode == .exitFailure
            lock.unlock()
            return failure ? .launched(exitCode: 1) : .launched(exitCode: 0)
        }

        let command = args.last.flatMap { $0.isEmpty ? nil : $0 } ?? executable
        if let path = controlPath(args), isMaster(args) {
            lock.lock()
            let mode = _mode
            if mode == .bindFailure {
                lock.unlock()
                return .launched(exitCode: 255,
                                 stderr: "unix_listener: cannot bind \(path): Permission denied")
            }
            if mode == .deadMaster, alive.contains(path) {
                lock.unlock()
                return CommandResult(exitCode: 255, stderr: "")
            }
            if alive.contains(path) {
                reuses += 1
            } else {
                alive.insert(path)
                creations += 1
            }
            lock.unlock()
        }

        return respond(command, inSession: controlPath(args) != nil)
    }

    private func respond(_ command: String, inSession: Bool) -> CommandResult {
        if command.contains("lipo -archs") {
            return .launched(exitCode: 0, stdout: "arm64\n")
        }
        if command.contains("__SSC_BEGIN_") {
            return batchResponse(command)
        }
        if command.contains("connected") {
            lock.lock()
            let index = connectedCallIndex
            connectedCallIndex += 1
            let exits = connectedExits
            let failPlain = failPlainConnected && !inSession
            let whitelistFailure = whitelistFailuresRemaining > 0
            if whitelistFailure { whitelistFailuresRemaining -= 1 }
            lock.unlock()
            if failPlain { return CommandResult(exitCode: 255, stderr: "") }
            if whitelistFailure {
                return CommandResult(exitCode: 255, stderr: "Connection reset by peer")
            }
            let code = index < exits.count ? exits[index] : 0
            if code == 0 {
                return .launched(exitCode: 0, stdout: "connected=1\ndevice=iPad\n")
            }
            return .launched(exitCode: code, stdout: "connected=0\n")
        }
        if command.contains("disconnect") {
            return .launched(exitCode: 0, stdout: "disconnected\n")
        }
        if command.contains("connect") {
            return .launched(exitCode: 0, stdout: "connected\n")
        }
        if command.contains("devices") {
            return .launched(exitCode: 0, stdout: "iPad\n")
        }
        if command.contains("dispid") {
            return .launched(exitCode: 0, stdout: displayLine(inSession: inSession))
        }
        if command.contains("arrange") {
            return .launched(exitCode: 0)
        }
        return .launched(exitCode: 0)
    }

    private static let displayLine =
        "id=3 vendor=0x5644 model=0x1 serial=0 builtin=false main=true active=true mirror_of=0 asleep=false 1321x918"

    private static let sidecarLine =
        "id=4 vendor=0x6161706c model=0x69506164 serial=0 builtin=false main=false active=true mirror_of=0 asleep=false 1321x918"

    private static let builtinLine =
        "id=1 vendor=0x610 model=0x1 serial=0 builtin=true main=true active=true mirror_of=0 asleep=false 3024x1964"

    private func displayLine(inSession: Bool) -> String {
        lock.lock()
        let contextual = dispidContextual
        lock.unlock()
        guard contextual else { return Self.displayLine }
        return inSession ? Self.displayLine + "\n" + Self.sidecarLine : Self.builtinLine
    }

    private func batchResponse(_ command: String) -> CommandResult {
        guard let range = command.range(of: "__SSC_BEGIN_") else {
            return .launched(exitCode: 0)
        }
        let rest = command[range.upperBound...]
        guard let end = rest.range(of: "__") else { return .launched(exitCode: 0) }
        let header = rest[..<end.lowerBound].split(separator: "_")
        guard header.count >= 2 else { return .launched(exitCode: 0) }
        let section = String(header[0])
        let nonce = String(header.last ?? header[0])

        func block(_ name: String, _ body: String, exit: Int32 = 0) -> String {
            "__SSC_BEGIN_\(name)_\(nonce)__\n\(body)\n__SSC_END_\(name)_\(nonce)__exit=\(exit)"
        }

        if section == "devices" {
            let output = [
                block("devices", "iPad"),
                block("dispid", Self.displayLine)
            ].joined(separator: "\n")
            return .launched(exitCode: 0, stdout: output)
        }
        let output = [
            block("connected_a", "connected=1\ndevice=iPad"),
            block("connected_b", "connected=1\ndevice=iPad"),
            block("dispid", Self.displayLine + "\n" + Self.sidecarLine)
        ].joined(separator: "\n")
        return .launched(exitCode: 0, stdout: output)
    }
}

final class SequenceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ value: String) {
        lock.lock()
        entries.append(value)
        lock.unlock()
    }

    var items: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func firstIndex(where predicate: (String) -> Bool) -> Int? {
        items.firstIndex(where: predicate)
    }
}

struct LoggingSleeper: Sleeping {
    let log: SequenceLog

    func sleep(_ duration: Duration) async {
        log.append("sleep:\(duration.inSeconds)")
    }
}

final class ControlMasterTransportTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup {
            chmod(url.appendingPathComponent(".sidecar-switch").path, 0o700)
            chmod(url.appendingPathComponent(".sidecar-switch/run").path, 0o700)
            try? FileManager.default.removeItem(at: url)
        }
        cleanup = []
        super.tearDown()
    }

    private func shortHome() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/ssw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cleanup.append(url)
        return url
    }

    private func waitUntil(_ condition: @Sendable () -> Bool, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = Deadline(after: timeout)
        while !condition() && !deadline.isExpired {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func remote(host: String = "127.0.0.1") -> RemoteSettings {        RemoteSettings(host: host, user: "tester", port: 2222,
                       identityFile: "~/.ssh/id_ed25519_sidecar_switch",
                       binaryPath: "/remote/SidecarLauncher",
                       connectedPath: "/remote/connected",
                       dispidPath: "/remote/dispid",
                       mirrorPath: "/remote/mirror",
                       arrangePath: "/remote/arrange")
    }

    private func makeOperations(home: URL, fake: FakeSSHMachine,
                                timings: Timings = .standard,
                                sentinel: (@Sendable (URL) -> Bool)? = nil,
                                sleeper: any Sleeping = TestSleeper()) -> SystemOperations {
        let sshPath = "/tmp/ssw-fake-ssh-\(UUID().uuidString.prefix(8))"
        let config = OperationsConfig(
            deviceName: "iPad",
            local: LocalToolPaths.standard(toolsDirectory: home.appendingPathComponent("tools").path),
            remote: remote(),
            ssh: SSHSettings(connectTimeout: 2),
            knownHostsDirectory: home.appendingPathComponent("known-hosts").path,
            legacyKnownHostsPath: nil,
            home: home,
            toolsVersion: "test",
            environment: ["PATH": "/usr/bin:/bin", "HOME": home.path],
            sshExecutable: sshPath,
            timings: timings
        )
        let store = HostKeyStore(directory: home.appendingPathComponent("known-hosts"), legacyPath: nil,
                                 runner: fake, logging: NoopLogging())
        return SystemOperations(config: config, runner: fake, logging: NoopLogging(), keyStore: store,
                                sleeper: sleeper)
    }

    private func makeTransport(home: URL, fake: FakeSSHMachine,
                               sentinel: (@Sendable (URL) -> Bool)? = nil,
                               probeFloor: Duration = .seconds(25),
                               retryBudget: Duration = .seconds(40)) -> SSHTransport {
        let store = HostKeyStore(directory: home.appendingPathComponent("known-hosts"), legacyPath: nil,
                                 runner: fake, logging: NoopLogging())
        return SSHTransport(remote: remote(), ssh: SSHSettings(connectTimeout: 2),
                            knownHosts: store, runner: fake, logging: NoopLogging(),
                            home: home, environment: ["PATH": "/usr/bin:/bin"],
                            executable: "/tmp/fake-ssh",
                            retryBudget: retryBudget,
                            probeFloor: probeFloor,
                            sessionSentinel: sentinel,
                            sleeper: TestSleeper())
    }

    func testK71MasterCreationAndReuseWithSingleExit() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        let ops = makeOperations(home: home, fake: fake)
        let sessionValue = await ops.beginRemoteSession()
        let session = try XCTUnwrap(sessionValue)
        XCTAssertTrue(ControlSocket.pathLengthValid(session.controlPath))
        XCTAssertTrue(session.controlPath.hasPrefix(home.appendingPathComponent(".sidecar-switch/run").path))

        let first = await ops.probe(.personale, timeout: .seconds(2), session: session)
        XCTAssertEqual(first.state, .connected(devices: ["iPad"]))
        for _ in 0..<3 {
            let report = await ops.devices(.personale, timeout: .seconds(2), session: session)
            XCTAssertEqual(report.status, .ok)
        }
        await ops.endRemoteSession(session)

        XCTAssertEqual(fake.creationCount, 1)
        XCTAssertEqual(fake.reuseCount, 3)
        XCTAssertEqual(fake.exitCount, 1)
        XCTAssertEqual(fake.checkCount, 0)
        XCTAssertEqual(fake.count(containing: "lipo -archs"), 1)
        XCTAssertFalse(fake.isAlive(session.controlPath))
        XCTAssertEqual(fake.arguments(containing: "connected").first?.filter { $0 == "ControlMaster=auto" }.count, 1)
    }

    func testK70NoMuxArgumentsOutsideSession() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        let ops = makeOperations(home: home, fake: fake)
        _ = await ops.probe(.personale, timeout: .seconds(2))
        let connected = try XCTUnwrap(fake.arguments(containing: "connected").last)
        XCTAssertFalse(connected.contains("ControlMaster=auto"))
        XCTAssertFalse(connected.contains { $0.hasPrefix("ControlPath=") })
        XCTAssertFalse(connected.contains { $0.hasPrefix("ControlPersist=") })
        XCTAssertEqual(fake.exitCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".sidecar-switch/run").path))
    }

    func testK73StaleSocketFileStillSucceedsWithoutCheck() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        let ops = makeOperations(home: home, fake: fake)
        let sessionValue = await ops.beginRemoteSession()
        let session = try XCTUnwrap(sessionValue)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: session.controlPath))
        let report = await ops.probe(.personale, timeout: .seconds(2), session: session)
        await ops.endRemoteSession(session)
        XCTAssertEqual(report.state, .connected(devices: ["iPad"]))
        XCTAssertEqual(fake.checkCount, 0)
        XCTAssertEqual(fake.creationCount, 1)
    }

    func testK74DeadMasterOnMutatingConnectHasNoRetry() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        let ops = makeOperations(home: home, fake: fake)
        let sessionValue = await ops.beginRemoteSession()
        let session = try XCTUnwrap(sessionValue)
        _ = await ops.probe(.personale, timeout: .seconds(2), session: session)
        fake.mode = .deadMaster
        let before = fake.count(containing: "connect") - fake.count(containing: "connected")
        let outcome = await ops.connect(.personale, device: "iPad", timeout: .seconds(2), session: session)
        let after = fake.count(containing: "connect") - fake.count(containing: "connected")
        await ops.endRemoteSession(session)
        XCTAssertEqual(outcome.status, .transport(.targetUnreachable))
        XCTAssertEqual(after - before, 1)
        XCTAssertEqual(fake.exitCount, 1)
    }

    func testK75DeadMasterOnReadOnlyHasNoRetry() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        let ops = makeOperations(home: home, fake: fake)
        let sessionValue = await ops.beginRemoteSession()
        let session = try XCTUnwrap(sessionValue)
        _ = await ops.probe(.personale, timeout: .seconds(2), session: session)
        fake.mode = .deadMaster
        let before = fake.count(containing: "connected")
        let report = await ops.probe(.personale, timeout: .seconds(2), session: session)
        let after = fake.count(containing: "connected")
        await ops.endRemoteSession(session)
        XCTAssertEqual(report.state, .unreachable)
        XCTAssertEqual(report.reason, .targetUnreachable)
        XCTAssertEqual(after - before, 1)
    }

    func testK76aChmodRepairsRunDirectoryAndMuxStaysEnabled() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        let run = home.appendingPathComponent(".sidecar-switch/run")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        chmod(run.path, 0o500)
        let ops = makeOperations(home: home, fake: fake)
        let session = await ops.beginRemoteSession()
        XCTAssertNotNil(session)

        var status = stat()
        stat(run.path, &status)
        XCTAssertEqual(status.st_mode & 0o777, 0o700)

        if let session {
            let report = await ops.probe(.personale, timeout: .seconds(2), session: session)
            await ops.endRemoteSession(session)
            XCTAssertEqual(report.state, .connected(devices: ["iPad"]))
        }
    }

    func testK76aSentinelFailureViaInjectionDegradesToPlain() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        let transport = makeTransport(home: home, fake: fake, sentinel: { _ in false })
        let session = transport.beginSession()
        XCTAssertNil(session)
        let result = await transport.execute("'/remote/connected'", timeout: .seconds(2))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fake.creationCount, 0)
        XCTAssertEqual(fake.exitCount, 0)
        let connected = try XCTUnwrap(fake.arguments(containing: "connected").last)
        XCTAssertFalse(connected.contains("ControlMaster=auto"))
    }

    func testK76bBindFailureDoesOnePlainRetry() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        fake.mode = .bindFailure
        let ops = makeOperations(home: home, fake: fake)
        let sessionValue = await ops.beginRemoteSession()
        let session = try XCTUnwrap(sessionValue)
        let report = await ops.probe(.personale, timeout: .seconds(25), session: session)
        XCTAssertEqual(report.state, .connected(devices: ["iPad"]))
        XCTAssertTrue(session.disabled)
        XCTAssertEqual(fake.count(containing: "connected"), 2)
        XCTAssertEqual(fake.muxInvocationCount, 1)
        await ops.endRemoteSession(session)
        XCTAssertEqual(fake.exitCount, 1)
    }

    func testK78FirstCallFallbackIsBoundedToOnePlainRetry() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        fake.mode = .bindFailure
        fake.failPlainConnected = true
        let ops = makeOperations(home: home, fake: fake)
        let sessionValue = await ops.beginRemoteSession()
        let session = try XCTUnwrap(sessionValue)
        let start = Date()
        let report = await ops.probe(.personale, timeout: .seconds(25), session: session)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(report.state, .unreachable)
        XCTAssertLessThanOrEqual(elapsed, Timings.standard.remoteRetryBudget.inSeconds)
        XCTAssertEqual(fake.count(containing: "connected"), 2)
        XCTAssertFalse(session.disabled == false)
        let again = await ops.probe(.personale, timeout: .seconds(25), session: session)
        XCTAssertEqual(again.state, .unreachable)
        XCTAssertEqual(fake.count(containing: "connected"), 3)
        XCTAssertEqual(fake.muxInvocationCount, 1)
    }

    func testK78ExpiredGroupDeadlineSkipsPlainFallback() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        fake.mode = .bindFailure
        fake.block = .seconds(1.2)
        let transport = makeTransport(home: home, fake: fake,
                                      probeFloor: .milliseconds(100),
                                      retryBudget: .seconds(1))
        let session = try XCTUnwrap(transport.beginSession())
        transport.resetGroup(.probe)

        let result = await transport.execute("'/remote/connected'", timeout: .seconds(25),
                                             retryGroup: .probe, session: session,
                                             allowFirstCallFallback: true)

        XCTAssertEqual(result.exitCode, 255)
        XCTAssertTrue(session.disabled)
        XCTAssertEqual(fake.count(containing: "connected"), 1)
        XCTAssertEqual(fake.plainInvocationCount, 0)
        XCTAssertEqual(fake.exitCount, 0)
    }

    func testK79ExitSuccessDoesNotUnlinkAndFailureUnlinks() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        let ops = makeOperations(home: home, fake: fake)

        let successValue = await ops.beginRemoteSession()
        let success = try XCTUnwrap(successValue)
        _ = await ops.probe(.personale, timeout: .seconds(2), session: success)
        try Data("socket".utf8).write(to: URL(fileURLWithPath: success.controlPath))
        await ops.endRemoteSession(success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: success.controlPath))
        XCTAssertFalse(fake.isAlive(success.controlPath))
        XCTAssertEqual(fake.exitCount, 1)

        fake.mode = .exitFailure
        let failureValue = await ops.beginRemoteSession()
        let failure = try XCTUnwrap(failureValue)
        try Data("socket".utf8).write(to: URL(fileURLWithPath: failure.controlPath))
        await ops.endRemoteSession(failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failure.controlPath))
        XCTAssertFalse(fake.isAlive(failure.controlPath))
        XCTAssertEqual(fake.exitCount, 2)

        fake.mode = .happy
        let disabledValue = await ops.beginRemoteSession()
        let disabled = try XCTUnwrap(disabledValue)
        disabled.disable()
        await ops.endRemoteSession(disabled)
        XCTAssertEqual(fake.exitCount, 3)
    }

    func testK77TransportRetryWithWhitelisted255IsUnchanged() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        fake.whitelistFailuresRemaining = 1
        let transport = makeTransport(home: home, fake: fake)
        transport.resetGroup(.probe)
        let result = await transport.execute("'/remote/connected'", timeout: .seconds(2),
                                             retryGroup: .probe)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fake.count(containing: "connected"), 2)
        XCTAssertEqual(fake.muxInvocationCount, 0)
        XCTAssertEqual(fake.exitCount, 0)
    }

    func testK89K90StaleSocketIsCleanedWithoutLiveMaster() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        fake.mode = .exitFailure
        let ops = makeOperations(home: home, fake: fake)
        let sessionValue = await ops.beginRemoteSession()
        let session = try XCTUnwrap(sessionValue)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: session.controlPath))
        let report = await ops.probe(.personale, timeout: .seconds(2), session: session)
        XCTAssertEqual(report.state, .connected(devices: ["iPad"]))
        await ops.endRemoteSession(session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.controlPath))
        XCTAssertFalse(fake.isAlive(session.controlPath))
        XCTAssertEqual(fake.exitCount, 1)
    }

    func testK80StandaloneProbeCreatesNoMasterAndNoSocket() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        let transport = makeTransport(home: home, fake: fake)
        _ = await transport.execute("'/remote/connected'", timeout: .seconds(2))
        XCTAssertEqual(fake.muxInvocationCount, 0)
        XCTAssertEqual(fake.exitCount, 0)
        XCTAssertEqual(fake.creationCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".sidecar-switch/run").path))
    }

    func testK87ControlExitUsesTransportExecutableAndEnvironment() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        let transport = makeTransport(home: home, fake: fake)
        let session = try XCTUnwrap(transport.beginSession())
        await transport.endSession(session)
        let invocation = try XCTUnwrap(fake.invocations.first { args in
            guard let index = args.arguments.firstIndex(of: "-O") else { return false }
            return args.arguments[index + 1] == "exit"
        })
        XCTAssertEqual(invocation.executable, "/tmp/fake-ssh")
        XCTAssertEqual(invocation.environment?["PATH"], "/usr/bin:/bin")
        XCTAssertFalse(invocation.arguments.contains("-i"))
        XCTAssertFalse(invocation.arguments.contains("BatchMode=yes"))
        XCTAssertFalse(invocation.arguments.contains { $0.contains("check") })
        XCTAssertEqual(invocation.timeout, .seconds(5))
    }

    func testK84DisconnectInSessionCarriesThreeMuxOptions() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        let ops = makeOperations(home: home, fake: fake)
        let sessionValue = await ops.beginRemoteSession()
        let session = try XCTUnwrap(sessionValue)

        let outcome = await ops.disconnect(.personale, device: "iPad", timeout: .seconds(2),
                                           session: session)

        XCTAssertEqual(outcome.status, .ok)
        let argv = try XCTUnwrap(fake.arguments(containing: "disconnect").last)
        XCTAssertTrue(argv.contains("ControlMaster=auto"), "\(argv)")
        XCTAssertTrue(argv.contains("ControlPath=\(session.controlPath)"), "\(argv)")
        XCTAssertTrue(argv.contains("ControlPersist=\(ControlSocket.controlPersistSeconds)"), "\(argv)")
        XCTAssertEqual(fake.creationCount, 1)

        await ops.endRemoteSession(session)
        XCTAssertEqual(fake.exitCount, 1)
        XCTAssertFalse(fake.isAlive(session.controlPath))
    }

    func testK86CancelMidFlightBlockedTransportStillEndsSession() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        fake.blockTransportCommands(1)
        let ops = makeOperations(home: home, fake: fake)
        let machine = StateMachine(ops: ops, timings: .fast, sleeper: TestSleeper(), deviceName: "iPad")
        let token = CancellationToken()
        let expectedPath = ControlSocket.path(
            runDirectory: home.appendingPathComponent(".sidecar-switch/run").path,
            host: "127.0.0.1", user: "tester", port: 2222
        )

        let task = Task { await machine.toggle(target: .personale, transitionID: UUID(), token: token) }
        let blocked = await waitUntil { fake.blockedCount == 1 }
        XCTAssertTrue(blocked, "il fake ssh deve essere bloccato a livello transport")
        token.cancel()
        fake.release()
        let outcome = await task.value

        XCTAssertEqual(outcome.state, .failed(nil, .cancelled))
        XCTAssertEqual(fake.creationCount, 1)
        XCTAssertEqual(fake.exitCount, 1)
        XCTAssertFalse(fake.isAlive(expectedPath))
        let exitInvocation = try XCTUnwrap(fake.invocations.first { args in
            guard let index = args.arguments.firstIndex(of: "-O") else { return false }
            return args.arguments[index + 1] == "exit"
        })
        XCTAssertTrue(exitInvocation.arguments.contains("ControlPath=\(expectedPath)"))
    }

    func testK93PersonaleToLavoroLocalPhaseBeyondPersistThenRollback() async throws {
        let home = try shortHome()
        let fake = FakeSSHMachine()
        fake.dispidContextual = true
        fake.connectedExits = [1, 0, 0, 1, 1, 1, 0]
        let log = SequenceLog()
        let sleeper = LoggingSleeper(log: log)
        fake.onInvocation = { arguments in
            if arguments.contains("-O") {
                log.append("exit")
            } else if arguments == ["connect", "iPad"] {
                log.append("local-connect")
            } else if arguments.contains("BatchMode=yes") {
                log.append("remote")
            } else {
                log.append("local-tool")
            }
        }
        var timings = Timings.standard
        timings.postDisconnectSettle = .seconds(21)
        timings.settleBudget = .seconds(21)
        timings.settlePollBackoffs = [.seconds(21)]
        let ops = makeOperations(home: home, fake: fake, timings: timings, sleeper: sleeper)
        let machine = StateMachine(ops: ops, timings: timings, sleeper: sleeper, deviceName: "iPad")
        let expectedPath = ControlSocket.path(
            runDirectory: home.appendingPathComponent(".sidecar-switch/run").path,
            host: "127.0.0.1", user: "tester", port: 2222
        )

        let start = Date()
        let outcome = await machine.toggle(target: .lavoro, transitionID: UUID(), token: CancellationToken())
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(outcome.state, .failed(.personale, .targetFailedRolledBack))
        XCTAssertEqual(outcome.persistence.needsReconcile, false)

        let items = log.items
        let earlyExit = try XCTUnwrap(items.firstIndex(of: "exit"))
        let localPhase = try XCTUnwrap(items.firstIndex(of: "sleep:21.0"))
        let localConnect = try XCTUnwrap(items.firstIndex(of: "local-connect"))
        XCTAssertLessThan(earlyExit, localPhase)
        XCTAssertLessThan(localPhase, localConnect)
        XCTAssertFalse(items[earlyExit...localConnect].contains("remote"),
                       "nessun comando remoto durante la fase locale: \(items)")
        XCTAssertGreaterThan(timings.postDisconnectSettle.inSeconds,
                             Double(ControlSocket.controlPersistSeconds))
        XCTAssertEqual(fake.exitCount, 2)
        XCTAssertEqual(fake.creationCount, 2)
        XCTAssertFalse(fake.isAlive(expectedPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath))
        let sleeps = items.compactMap { entry -> Double? in
            guard entry.hasPrefix("sleep:") else { return nil }
            return Double(entry.dropFirst("sleep:".count))
        }
        XCTAssertLessThanOrEqual(sleeps.reduce(0, +), 182)
        XCTAssertLessThanOrEqual(elapsed, 182)
        let controlTimeouts = fake.invocations
            .filter { $0.arguments.contains("-O") }
            .map(\.timeout)
        XCTAssertEqual(controlTimeouts, [ControlSocket.controlCommandTimeout, ControlSocket.controlCommandTimeout])
    }

    func testK83ExplicitOptionsWinOverSSHConfigWithRealSSH() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/ssh") else {
            throw XCTSkip("/usr/bin/ssh non disponibile")
        }
        let directory = try makeTempDirectory("ssh-precedence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        let other = "/tmp/other-master.sock"
        let ours = "/tmp/ssc-0123456789abcdef.sock"
        try Data("""
        Host *
          ControlMaster yes
          ControlPath \(other)
          ControlPersist yes
        """.utf8).write(to: config)

        let args = ["/usr/bin/ssh", "-F", config.path,
                    "-o", "ControlMaster=auto", "-o", "ControlPath=\(ours)",
                    "-o", "ControlPersist=20", "-G", "utente@personale.local"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("controlmaster auto"), output)
        XCTAssertTrue(output.contains("controlpath \(ours)"), output)
        XCTAssertTrue(output.contains("controlpersist 20"), output)
    }
}
