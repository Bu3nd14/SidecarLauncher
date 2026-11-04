import Darwin
import Foundation

public enum RemoteGroupKind: String, Sendable, CaseIterable {
    case probe
    case prereqs
    case bootstrap
}

public final class RemoteRetryCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var deadlines: [RemoteGroupKind: Deadline] = [:]

    public init() {}

    public func begin(_ kind: RemoteGroupKind, cap: Duration) {
        lock.lock()
        deadlines[kind] = Deadline(after: cap)
        lock.unlock()
    }

    public func end(_ kind: RemoteGroupKind) {
        lock.lock()
        deadlines.removeValue(forKey: kind)
        lock.unlock()
    }

    public func deadline(_ kind: RemoteGroupKind, cap: Duration, create: Bool = true) -> Deadline? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = deadlines[kind], !existing.isExpired {
            return existing
        }
        deadlines.removeValue(forKey: kind)
        guard create else { return nil }
        let value = Deadline(after: cap)
        deadlines[kind] = value
        return value
    }

    public func isActive(_ kind: RemoteGroupKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = deadlines[kind] else { return false }
        if existing.isExpired {
            deadlines.removeValue(forKey: kind)
            return false
        }
        return true
    }
}

public struct EffectiveSSHConfig: Sendable, Equatable {
    public var port: Int
    public var proxyCommand: String?

    public init(port: Int, proxyCommand: String? = nil) {
        self.port = port
        self.proxyCommand = proxyCommand
    }
}

public final class HostKeyStore: @unchecked Sendable {
    public let directory: URL
    public let knownHostsPath: String
    private let legacyPath: String?
    private let runner: any CommandRunning
    private let logging: any SwitchLogging
    private let lock = NSLock()
    private var firstUses: Set<String> = []

    public init(directory: URL, legacyPath: String? = nil,
                runner: any CommandRunning, logging: any SwitchLogging) {
        self.directory = directory
        self.knownHostsPath = directory.appendingPathComponent("known_hosts").path
        self.legacyPath = legacyPath
        self.runner = runner
        self.logging = logging
    }

    public func ensureFiles() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        chmod(directory.path, 0o700)

        if manager.fileExists(atPath: knownHostsPath) {
            chmod(knownHostsPath, 0o600)
            return
        }

        if let legacyPath, manager.fileExists(atPath: legacyPath) {
            do {
                try manager.copyItem(at: URL(fileURLWithPath: legacyPath), to: URL(fileURLWithPath: knownHostsPath))
                chmod(knownHostsPath, 0o600)
                logging.log(.info, "known_hosts migrato da \(legacyPath) a \(knownHostsPath)")
                return
            } catch {
                logging.log(.warning, "migrazione known_hosts fallita (TOFU trasparente): \(error)")
            }
        }

        manager.createFile(atPath: knownHostsPath, contents: Data(), attributes: [.posixPermissions: 0o600])
        chmod(knownHostsPath, 0o600)
    }

    public func consumeFirstUse(host: String, port: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(host):\(port)"
        if firstUses.contains(key) { return false }
        firstUses.insert(key)
        return true
    }

    public var hasAudited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstUses.isEmpty == false
    }

    public func recordFingerprint(host: String, port: Int) async {
        var patterns = [host]
        if port != 22 { patterns = ["[\(host)]:\(port)", host] }
        for pattern in patterns {
            let fingerprint = await runner.run(
                CommandSpec(executable: "/usr/bin/ssh-keygen",
                            arguments: ["-F", pattern, "-l", "-f", knownHostsPath]),
                timeout: .seconds(10)
            )
            guard fingerprint.exitCode == 0 else { continue }
            let value = fingerprint.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let date = ISO8601DateFormatter().string(from: Date())
            logging.log(.info, "host key \(pattern) \(value) \(date)")
            return
        }
        logging.log(.warning, "host key: fingerprint non disponibile per \(host):\(port) (TOFU accettato)")
    }

    @discardableResult
    public func forget(host: String, port: Int = 22) async -> Bool {
        var ok = true
        var patterns = [host]
        if port != 22 { patterns = ["[\(host)]:\(port)", host] }
        for pattern in patterns {
            let result = await runner.run(
                CommandSpec(executable: "/usr/bin/ssh-keygen", arguments: ["-R", pattern, "-f", knownHostsPath]),
                timeout: .seconds(10)
            )
            if result.exitCode != 0 { ok = false }
        }
        logging.log(ok ? .info : .warning, "host key: dimentica \(host):\(port) esito=\(ok)")
        return ok
    }
}

public struct FixedEnvironmentProvider: EnvironmentProviding {
    public let variables: [String: String]

    public init(_ variables: [String: String]) {
        self.variables = variables
    }

    public func capture() async -> EnvironmentSnapshot? {
        EnvironmentSnapshot(variables: variables, proxyAvailable: EnvironmentAllowlist.containsProxy(variables))
    }
}

public final class SSHTransport: @unchecked Sendable {
    public let remote: RemoteSettings
    public let ssh: SSHSettings
    public let knownHosts: HostKeyStore
    private let runner: any CommandRunning
    private let logging: any SwitchLogging
    private let home: URL
    private let environmentProvider: any EnvironmentProviding
    private let executable: String
    private let retryAttempts: Int
    private let retryBackoff: Duration
    private let retryBudget: Duration
    private let sleeper: any Sleeping
    private let coordinator: RemoteRetryCoordinator
    private let probeFloor: Duration
    private let sessionSentinel: (@Sendable (URL) -> Bool)?
    private let lock = NSLock()
    private var audited = false
    private var cachedConfig: EffectiveSSHConfig?

    public init(remote: RemoteSettings, ssh: SSHSettings, knownHosts: HostKeyStore,
                runner: any CommandRunning, logging: any SwitchLogging,
                home: URL = SystemHome().homeDirectory,
                environmentProvider: (any EnvironmentProviding)? = nil,
                environment: [String: String]? = nil,
                executable: String = CommandBuilder.sshExecutable,
                retryAttempts: Int = 2,
                retryBackoff: Duration = .seconds(2),
                retryBudget: Duration = .seconds(40),
                probeFloor: Duration = .seconds(25),
                sessionSentinel: (@Sendable (URL) -> Bool)? = nil,
                sleeper: any Sleeping = RealSleeper(),
                coordinator: RemoteRetryCoordinator = RemoteRetryCoordinator()) {
        self.remote = remote
        self.ssh = ssh
        self.knownHosts = knownHosts
        self.runner = runner
        self.logging = logging
        self.home = home
        self.environmentProvider = environmentProvider
            ?? environment.map(FixedEnvironmentProvider.init)
            ?? LoginShellEnvironmentProvider(runner: runner, logging: logging)
        self.executable = executable
        self.retryAttempts = retryAttempts
        self.retryBackoff = retryBackoff
        self.retryBudget = retryBudget
        self.probeFloor = probeFloor
        self.sessionSentinel = sessionSentinel
        self.sleeper = sleeper
        self.coordinator = coordinator
    }

    public var sshConfigPath: String? {
        let path = home.appendingPathComponent(".ssh/config").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    public func resetGroup(_ kind: RemoteGroupKind) {
        coordinator.begin(kind, cap: retryBudget)
    }

    public func resetGroup(_ kind: RemoteGroupKind, cap: Duration) {
        coordinator.begin(kind, cap: cap)
    }

    public func endGroup(_ kind: RemoteGroupKind) {
        coordinator.end(kind)
    }

    private func cachedEffectiveConfig() -> EffectiveSSHConfig? {
        lock.lock()
        defer { lock.unlock() }
        return cachedConfig
    }

    private func storeEffectiveConfig(_ value: EffectiveSSHConfig) {
        lock.lock()
        cachedConfig = value
        lock.unlock()
    }

    private func claimAudit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if audited { return false }
        audited = true
        return true
    }

    public func effectiveConfig() async -> EffectiveSSHConfig {
        if let cached = cachedEffectiveConfig() { return cached }

        let result: CommandResult
        do {
            let argv = try CommandBuilder.sshQueryArguments(remote: remote, ssh: ssh, home: home,
                                                            sshConfigPath: sshConfigPath)
            var spec = CommandSpec(executable: argv[0], arguments: Array(argv.dropFirst()))
            spec.environment = await environmentProvider.capture()?.variables ?? BaseEnvironment.make()
            result = await runner.run(spec, timeout: .seconds(10))
        } catch {
            let fallback = EffectiveSSHConfig(port: remote.port)
            storeEffectiveConfig(fallback)
            return fallback
        }

        guard result.exitCode == 0 else {
            let fallback = EffectiveSSHConfig(port: remote.port)
            storeEffectiveConfig(fallback)
            logging.log(.warning, "ssh -G fallito (exit \(result.exitCode ?? -1)): uso remote.port=\(remote.port)")
            return fallback
        }

        var port = remote.port
        var proxy: String?
        for raw in result.stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            if line.hasPrefix("port ") {
                port = Int(line.dropFirst("port ".count).trimmingCharacters(in: .whitespaces)) ?? port
            } else if line.hasPrefix("proxycommand ") {
                proxy = String(line.dropFirst("proxycommand ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        let config = EffectiveSSHConfig(port: port, proxyCommand: proxy)
        storeEffectiveConfig(config)
        logging.log(.debug, "ssh -G: port=\(port) proxycommand=\(proxy ?? "none")")
        return config
    }

    public func beginSession() -> RemoteSession? {
        guard !remote.host.isEmpty else { return nil }
        assert(ControlSocket.controlPersistExceedsMaxGap)
        let runDirectory = AppPaths(home: home).runDirectory
        let path = ControlSocket.path(runDirectory: runDirectory.path, host: remote.host,
                                      user: remote.user, port: remote.port)
        guard ControlSocket.pathLengthValid(path) else {
            logging.log(.warning, "ControlSocket disabilitato: path \(path.utf8.count) byte > \(ControlSocket.maxPathBytes) (\(path))")
            return nil
        }
        guard !ControlSocket.pathContainsPercent(path) else {
            logging.log(.warning, "ControlSocket disabilitato: path contiene '%' (\(path))")
            return nil
        }

        let manager = FileManager.default
        do {
            try manager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        } catch {
            logging.log(.warning, "ControlSocket disabilitato: directory \(runDirectory.path) non creabile (\(error))")
            return nil
        }
        chmod(runDirectory.path, 0o700)

        if let sessionSentinel {
            guard sessionSentinel(runDirectory) else {
                logging.log(.warning, "ControlSocket disabilitato: sentinella fallita in \(runDirectory.path)")
                return nil
            }
        } else {
            let sentinel = runDirectory.appendingPathComponent(".ssc-sentinel-\(UUID().uuidString)")
            guard manager.createFile(atPath: sentinel.path, contents: Data(),
                                     attributes: [.posixPermissions: 0o600]) else {
                logging.log(.warning, "ControlSocket disabilitato: dir \(runDirectory.path) non scrivibile (sentinella)")
                return nil
            }
            do {
                try manager.removeItem(at: sentinel)
            } catch {
                logging.log(.warning, "ControlSocket disabilitato: sentinella non rimovibile in \(runDirectory.path) (\(error))")
                return nil
            }
        }

        logging.log(.info, "ControlSocket attivo: \(path)")
        return RemoteSession(controlPath: path)
    }

    public func endSession(_ session: RemoteSession?) async {
        guard let session else { return }
        let environment = await environmentProvider.capture()?.variables ?? BaseEnvironment.make()
        do {
            let argv = try CommandBuilder.sshControlArguments(
                remote: remote,
                controlPath: session.controlPath,
                verb: "exit",
                executable: executable,
                environment: environment,
                home: home,
                sshConfigPath: sshConfigPath
            )
            var spec = CommandSpec(executable: argv[0], arguments: Array(argv.dropFirst()))
            spec.environment = environment
            let result = await runner.run(spec, timeout: ControlSocket.controlCommandTimeout)
            if result.exitCode == 0, !result.timedOut, result.signal == nil {
                logging.log(.debug, "ControlSocket chiuso (-O exit): \(session.controlPath)")
                return
            }
            logging.log(.warning, "ControlSocket -O exit fallito (exit \(result.exitCode.map(String.init) ?? "timeout")): unlink \(session.controlPath)")
        } catch {
            logging.log(.warning, "ControlSocket -O exit non eseguibile (\(error)): unlink \(session.controlPath)")
        }
        try? FileManager.default.removeItem(atPath: session.controlPath)
    }

    public func execute(_ command: String, timeout: Duration, retryGroup: RemoteGroupKind? = nil,
                        session: RemoteSession? = nil,
                        allowFirstCallFallback: Bool = false) async -> CommandResult {
        do {
            try knownHosts.ensureFiles()
        } catch {
            return CommandResult(launchError: "known_hosts: \(error)")
        }

        let inSession = session.map { !$0.disabled } ?? false
        let firstCommand = inSession ? session?.claimFirstCommand() ?? false : false
        let controlPath = inSession ? session?.controlPath : nil

        var attempt = 1
        var result = CommandResult(launchError: "nessun tentativo")
        while true {
            var attemptTimeout = timeout
            if let retryGroup {
                let deadline = coordinator.deadline(retryGroup, cap: retryBudget)
                attemptTimeout = min(timeout, deadline?.remaining ?? timeout)
            }
            if attemptTimeout <= .zero {
                return CommandResult(exitCode: nil, timedOut: true)
            }
            result = await runOnce(command, timeout: attemptTimeout, controlPath: controlPath)
            guard let retryGroup,
                  result.exitCode == 255,
                  ExitCodes.isTransportWhitelisted(stderr: result.stderr),
                  attempt < retryAttempts else { break }

            let deadline = coordinator.deadline(retryGroup, cap: retryBudget)
            let remaining = deadline?.remaining ?? .zero
            guard remaining >= sshConnectTimeoutDuration + .seconds(2) else {
                logging.log(.warning, "retry trasporto non eseguito: budget residuo insufficiente")
                break
            }
            attempt += 1
            logging.log(.warning, "retry trasporto \(attempt)/\(retryAttempts) dopo 255 transitorio: \(LogRedaction.redact(result.stderr))")
            await sleeper.sleep(retryBackoff)
        }

        if let exit = result.exitCode, exit != 0, exit != 255 {
            logging.log(.warning, "ssh host=\(remote.host) exit=\(exit) stderr=\(LogRedaction.redact(result.stderr))")
        }
        if result.timedOut {
            logging.log(.warning, "ssh host=\(remote.host) timeout stderr=\(LogRedaction.redact(result.stderr))")
        }
        if result.exitCode == 255, !ExitCodes.isTransportWhitelisted(stderr: result.stderr) {
            logging.log(.error, "ssh 255 non riconosciuto host=\(remote.host) exit=255: \(LogRedaction.redact(result.stderr))")
            logging.log(.error, "config SSH o proxy/CA non applicati? controlla VPN/rete")
        }

        guard inSession, result.exitCode == 255, firstCommand else { return result }
        session?.disable()
        guard allowFirstCallFallback else { return result }

        let remaining: Duration
        if let retryGroup {
            remaining = coordinator.deadline(retryGroup, cap: retryBudget, create: false)?.remaining ?? .zero
        } else {
            remaining = timeout
        }
        guard remaining >= probeFloor else {
            logging.log(.warning, "fallback plain non eseguito: residuo \(remaining.inSeconds)s < \(probeFloor.inSeconds)s")
            return result
        }
        let fallbackTimeout = min(timeout, remaining)
        logging.log(.warning, "fallback plain dopo 255 della prima chiamata in-session (mux disabilitato)")
        return await runOnce(command, timeout: fallbackTimeout, controlPath: nil)
    }

    private var sshConnectTimeoutDuration: Duration { .seconds(ssh.connectTimeout) }

    private func runOnce(_ command: String, timeout: Duration, controlPath: String?) async -> CommandResult {
        let first = knownHosts.consumeFirstUse(host: remote.host, port: remote.port)
        do {
            var spec = try CommandBuilder.sshSpec(
                remote: remote,
                ssh: ssh,
                knownHostsPath: knownHosts.knownHostsPath,
                command: command,
                firstConnect: first,
                home: home,
                sshConfigPath: sshConfigPath,
                executable: executable,
                controlPath: controlPath,
                controlPersist: controlPath == nil ? nil : ControlSocket.controlPersistSeconds,
                logging: logging
            )
            spec.environment = await environmentProvider.capture()?.variables ?? BaseEnvironment.make()
            logging.log(.debug, "ssh \(remote.host) \(LogRedaction.redact(command))")
            let result = await runner.run(spec, timeout: timeout)
            if result.exitCode == 0 {
                await auditIfNeeded()
            }
            return result
        } catch {
            return CommandResult(launchError: "\(error)")
        }
    }

    private func auditIfNeeded() async {
        guard claimAudit() else { return }
        let config = await effectiveConfig()
        await knownHosts.recordFingerprint(host: remote.host, port: config.port)
    }
}

public actor RemoteBootstrap {
    private var ready = false
    private var warned = false
    private let transport: SSHTransport
    private let binaryPath: String
    private let toolsVersion: String
    private let logging: any SwitchLogging
    private let cap: Duration
    private let probeTimeout: Duration

    public init(transport: SSHTransport, binaryPath: String, toolsVersion: String, logging: any SwitchLogging,
                cap: Duration = .seconds(40), probeTimeout: Duration = .seconds(25)) {
        self.transport = transport
        self.binaryPath = binaryPath
        self.toolsVersion = toolsVersion
        self.logging = logging
        self.cap = cap
        self.probeTimeout = probeTimeout
    }

    public func ensureReady() async -> Reason? {
        if ready { return nil }
        if !warned {
            warned = true
            logging.log(.warning, "tool remoti: attesi \(binaryPath) allineati a TOOLS_VERSION \(toolsVersion) (stesso commit del repo; skew non fatale)")
        }

        transport.resetGroup(.bootstrap, cap: cap)
        let command = "lipo -archs \(CommandBuilder.shellQuote(binaryPath))"
        let result = await transport.execute(command, timeout: probeTimeout, retryGroup: .bootstrap)
        transport.endGroup(.bootstrap)
        switch ExitCodes.ssh(result) {
        case .ok:
            let arches = result.stdout.lowercased()
            guard arches.contains("arm64") else {
                logging.log(.error, "remote bootstrap: architettura non arm64 (\(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))")
                return .remoteBootstrap
            }
            ready = true
            return nil
        case .transport(let reason):
            logging.log(.warning, "remote bootstrap fallito: \(reason.rawValue)")
            return [.targetUnreachable, .authFailed, .hostKeyMismatch, .remoteCrashed].contains(reason) ? reason : .remoteBootstrap
        default:
            logging.log(.error, "remote bootstrap: lipo non eseguibile o tool mancanti (exit \(result.exitCode.map(String.init) ?? "segnale"))")
            return .remoteBootstrap
        }
    }

    public func reset() {
        ready = false
    }

    public var isReady: Bool { ready }
}
