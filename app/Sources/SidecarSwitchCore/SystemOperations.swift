import Foundation

public protocol SidecarOperations: Sendable {
    func probe(_ host: Host, timeout: Duration) async -> ProbeReport
    func probe(_ host: Host, timeout: Duration, retry: Bool) async -> ProbeReport
    func devices(_ host: Host, timeout: Duration) async -> DevicesReport
    func devices(_ host: Host, timeout: Duration, retry: Bool) async -> DevicesReport
    func displays(_ host: Host, timeout: Duration) async -> DisplaysReport
    func disconnect(_ host: Host, device: String, timeout: Duration) async -> CommandOutcome
    func connect(_ host: Host, device: String, timeout: Duration) async -> CommandOutcome
    func harden(_ host: Host, timeout: Duration) async -> HardenOutcome
    func harden(_ host: Host, timeout: Duration, skipArrange: Bool) async -> HardenOutcome
    func remoteBatch(_ kind: RemoteBatchKind, nonce: String, settle: Duration,
                     timeout: Duration) async -> BatchExecution
    func beginRemoteGroup(_ kind: RemoteGroupKind) async
    func endRemoteGroup(_ kind: RemoteGroupKind) async
    func beginRemoteSession() async -> RemoteSession?
    func endRemoteSession(_ session: RemoteSession?) async
    func probe(_ host: Host, timeout: Duration, session: RemoteSession?) async -> ProbeReport
    func probe(_ host: Host, timeout: Duration, retry: Bool, session: RemoteSession?) async -> ProbeReport
    func devices(_ host: Host, timeout: Duration, session: RemoteSession?) async -> DevicesReport
    func devices(_ host: Host, timeout: Duration, retry: Bool, session: RemoteSession?) async -> DevicesReport
    func displays(_ host: Host, timeout: Duration, session: RemoteSession?) async -> DisplaysReport
    func disconnect(_ host: Host, device: String, timeout: Duration, session: RemoteSession?) async -> CommandOutcome
    func connect(_ host: Host, device: String, timeout: Duration, session: RemoteSession?) async -> CommandOutcome
    func harden(_ host: Host, timeout: Duration, skipArrange: Bool, session: RemoteSession?) async -> HardenOutcome
    func remoteBatch(_ kind: RemoteBatchKind, nonce: String, settle: Duration,
                     timeout: Duration, session: RemoteSession?) async -> BatchExecution
}

public extension SidecarOperations {
    func probe(_ host: Host, timeout: Duration, retry: Bool) async -> ProbeReport {
        await probe(host, timeout: timeout)
    }

    func devices(_ host: Host, timeout: Duration, retry: Bool) async -> DevicesReport {
        await devices(host, timeout: timeout)
    }

    func beginRemoteGroup(_ kind: RemoteGroupKind) async {}
    func endRemoteGroup(_ kind: RemoteGroupKind) async {}

    func harden(_ host: Host, timeout: Duration, skipArrange: Bool) async -> HardenOutcome {
        await harden(host, timeout: timeout)
    }

    func remoteBatch(_ kind: RemoteBatchKind, nonce: String, settle: Duration,
                     timeout: Duration) async -> BatchExecution {
        .parseFailed(.invalidStructure("batching non disponibile"))
    }

    func beginRemoteSession() async -> RemoteSession? { nil }
    func endRemoteSession(_ session: RemoteSession?) async {}

    func probe(_ host: Host, timeout: Duration, session: RemoteSession?) async -> ProbeReport {
        await probe(host, timeout: timeout)
    }

    func probe(_ host: Host, timeout: Duration, retry: Bool, session: RemoteSession?) async -> ProbeReport {
        await probe(host, timeout: timeout, retry: retry)
    }

    func devices(_ host: Host, timeout: Duration, session: RemoteSession?) async -> DevicesReport {
        await devices(host, timeout: timeout)
    }

    func devices(_ host: Host, timeout: Duration, retry: Bool,
                 session: RemoteSession?) async -> DevicesReport {
        await devices(host, timeout: timeout, retry: retry)
    }

    func displays(_ host: Host, timeout: Duration, session: RemoteSession?) async -> DisplaysReport {
        await displays(host, timeout: timeout)
    }

    func disconnect(_ host: Host, device: String, timeout: Duration,
                    session: RemoteSession?) async -> CommandOutcome {
        await disconnect(host, device: device, timeout: timeout)
    }

    func connect(_ host: Host, device: String, timeout: Duration,
                 session: RemoteSession?) async -> CommandOutcome {
        await connect(host, device: device, timeout: timeout)
    }

    func harden(_ host: Host, timeout: Duration, skipArrange: Bool,
                session: RemoteSession?) async -> HardenOutcome {
        await harden(host, timeout: timeout, skipArrange: skipArrange)
    }

    func remoteBatch(_ kind: RemoteBatchKind, nonce: String, settle: Duration,
                     timeout: Duration, session: RemoteSession?) async -> BatchExecution {
        await remoteBatch(kind, nonce: nonce, settle: settle, timeout: timeout)
    }
}

public struct LocalToolPaths: Sendable, Equatable {
    public var binaryPath: String
    public var connectedPath: String
    public var dispidPath: String
    public var mirrorPath: String
    public var arrangePath: String

    public init(binaryPath: String, connectedPath: String, dispidPath: String,
                mirrorPath: String, arrangePath: String) {
        self.binaryPath = binaryPath
        self.connectedPath = connectedPath
        self.dispidPath = dispidPath
        self.mirrorPath = mirrorPath
        self.arrangePath = arrangePath
    }

    public static func standard(toolsDirectory: String) -> LocalToolPaths {
        LocalToolPaths(
            binaryPath: toolsDirectory + "/SidecarLauncher",
            connectedPath: toolsDirectory + "/connected",
            dispidPath: toolsDirectory + "/dispid",
            mirrorPath: toolsDirectory + "/mirror",
            arrangePath: toolsDirectory + "/arrange"
        )
    }
}

public struct OperationsConfig: Sendable, Equatable {
    public var deviceName: String
    public var local: LocalToolPaths
    public var remote: RemoteSettings
    public var ssh: SSHSettings
    public var knownHostsDirectory: String
    public var legacyKnownHostsPath: String?
    public var home: URL
    public var toolsVersion: String
    public var environment: [String: String]?
    public var sshExecutable: String
    public var timings: Timings

    public init(deviceName: String, local: LocalToolPaths, remote: RemoteSettings, ssh: SSHSettings,
                knownHostsDirectory: String, legacyKnownHostsPath: String? = nil,
                home: URL = SystemHome().homeDirectory,
                toolsVersion: String, environment: [String: String]? = nil,
                sshExecutable: String = CommandBuilder.sshExecutable,
                timings: Timings = .standard) {
        self.deviceName = deviceName
        self.local = local
        self.remote = remote
        self.ssh = ssh
        self.knownHostsDirectory = knownHostsDirectory
        self.legacyKnownHostsPath = legacyKnownHostsPath
        self.home = home
        self.toolsVersion = toolsVersion
        self.environment = environment
        self.sshExecutable = sshExecutable
        self.timings = timings
    }
}

public final class SystemOperations: SidecarOperations, @unchecked Sendable {
    public let config: OperationsConfig
    private let runner: any CommandRunning
    private let logging: any SwitchLogging
    private let transport: SSHTransport
    private let bootstrap: RemoteBootstrap
    private let coordinator: RemoteRetryCoordinator

    public init(config: OperationsConfig, runner: any CommandRunning, logging: any SwitchLogging,
                keyStore: HostKeyStore? = nil,
                environmentProvider: (any EnvironmentProviding)? = nil,
                sleeper: any Sleeping = RealSleeper(),
                retryCoordinator: RemoteRetryCoordinator = RemoteRetryCoordinator()) {
        self.config = config
        self.runner = runner
        self.logging = logging
        self.coordinator = retryCoordinator

        let store = keyStore ?? HostKeyStore(
            directory: URL(fileURLWithPath: config.knownHostsDirectory),
            legacyPath: config.legacyKnownHostsPath,
            runner: runner,
            logging: logging
        )
        self.transport = SSHTransport(remote: config.remote, ssh: config.ssh, knownHosts: store,
                                      runner: runner, logging: logging, home: config.home,
                                      environmentProvider: environmentProvider,
                                      environment: config.environment,
                                      executable: config.sshExecutable,
                                      retryAttempts: config.timings.remoteAttempts,
                                      retryBackoff: config.timings.retryBackoff,
                                      retryBudget: config.timings.remoteRetryBudget,
                                      probeFloor: config.timings.remoteProbeTimeout,
                                      sleeper: sleeper,
                                      coordinator: retryCoordinator)
        self.bootstrap = RemoteBootstrap(transport: transport, binaryPath: config.remote.binaryPath,
                                         toolsVersion: config.toolsVersion, logging: logging,
                                         cap: config.timings.bootstrapCap,
                                         probeTimeout: config.timings.remoteProbeTimeout)
    }

    public func beginRemoteGroup(_ kind: RemoteGroupKind) async {
        coordinator.begin(kind, cap: config.timings.remoteRetryBudget)
    }

    public func endRemoteGroup(_ kind: RemoteGroupKind) async {
        coordinator.end(kind)
    }

    public func beginRemoteSession() async -> RemoteSession? {
        transport.beginSession()
    }

    public func endRemoteSession(_ session: RemoteSession?) async {
        await transport.endSession(session)
    }

    public func probe(_ host: Host, timeout: Duration) async -> ProbeReport {
        await probe(host, timeout: timeout, retry: true)
    }

    public func probe(_ host: Host, timeout: Duration, retry: Bool) async -> ProbeReport {
        await probe(host, timeout: timeout, retry: retry, session: nil)
    }

    public func probe(_ host: Host, timeout: Duration, session: RemoteSession?) async -> ProbeReport {
        await probe(host, timeout: timeout, retry: true, session: session)
    }

    public func probe(_ host: Host, timeout: Duration, retry: Bool,
                      session: RemoteSession?) async -> ProbeReport {
        let result: CommandResult
        switch host {
        case .lavoro:
            result = await runner.run(spec(config.local.connectedPath, []), timeout: timeout)
        case .personale:
            if let reason = await bootstrap.ensureReady() {
                return ProbeReport(state: .unreachable, reason: reason, detail: "remote bootstrap")
            }
            if retry { coordinator.begin(.probe, cap: config.timings.remoteRetryBudget) }
            result = await transport.execute(CommandBuilder.shellQuote(config.remote.connectedPath),
                                             timeout: timeout,
                                             retryGroup: retry ? .probe : nil,
                                             session: session,
                                             allowFirstCallFallback: true)
            if retry { coordinator.end(.probe) }
        }
        return ExitCodes.probeReport(host: host, result: result)
    }

    public func devices(_ host: Host, timeout: Duration) async -> DevicesReport {
        await devices(host, timeout: timeout, retry: true)
    }

    public func devices(_ host: Host, timeout: Duration, retry: Bool) async -> DevicesReport {
        await devices(host, timeout: timeout, retry: retry, session: nil)
    }

    public func devices(_ host: Host, timeout: Duration, session: RemoteSession?) async -> DevicesReport {
        await devices(host, timeout: timeout, retry: true, session: session)
    }

    public func devices(_ host: Host, timeout: Duration, retry: Bool,
                        session: RemoteSession?) async -> DevicesReport {
        let result: CommandResult
        switch host {
        case .lavoro:
            result = await runner.run(
                spec(config.local.binaryPath, ["devices"]),
                timeout: timeout
            )
        case .personale:
            if retry, let reason = await bootstrap.ensureReady() {
                return DevicesReport(status: .transport(reason), names: [], report: CommandReport(status: .transport(reason)))
            }
            let command = CommandBuilder.remoteCommand(remoteExecutable: config.remote.binaryPath, verb: "devices", device: nil)
            result = await transport.execute(command, timeout: timeout,
                                             retryGroup: retry ? .prereqs : nil,
                                             session: session,
                                             allowFirstCallFallback: true)
        }
        return ExitCodes.devicesReport(host: host, result: result)
    }

    public func displays(_ host: Host, timeout: Duration) async -> DisplaysReport {
        await displays(host, timeout: timeout, session: nil)
    }

    public func displays(_ host: Host, timeout: Duration, session: RemoteSession?) async -> DisplaysReport {
        let result: CommandResult
        switch host {
        case .lavoro:
            result = await runner.run(spec(config.local.dispidPath, []), timeout: timeout)
        case .personale:
            if let reason = await bootstrap.ensureReady() {
                return DisplaysReport(status: .transport(reason), displays: [], report: CommandReport(status: .transport(reason)))
            }
            result = await transport.execute(CommandBuilder.shellQuote(config.remote.dispidPath),
                                             timeout: timeout, retryGroup: .prereqs,
                                             session: session,
                                             allowFirstCallFallback: true)
        }
        return ExitCodes.displaysReport(host: host, result: result)
    }

    public func disconnect(_ host: Host, device: String, timeout: Duration) async -> CommandOutcome {
        await disconnect(host, device: device, timeout: timeout, session: nil)
    }

    public func disconnect(_ host: Host, device: String, timeout: Duration,
                           session: RemoteSession?) async -> CommandOutcome {
        logging.log(.info, "disconnect \(host.rawValue) device=\(device)")
        let result: CommandResult
        switch host {
        case .lavoro:
            result = await runner.run(
                spec(config.local.binaryPath, ["disconnect", device]),
                timeout: timeout
            )
        case .personale:
            if let reason = await bootstrap.ensureReady() {
                return CommandOutcome(status: .transport(reason), report: CommandReport(status: .transport(reason)))
            }
            let command = CommandBuilder.remoteCommand(remoteExecutable: config.remote.binaryPath,
                                                       verb: "disconnect", device: device)
            result = await transport.execute(command, timeout: timeout, session: session,
                                             allowFirstCallFallback: false)
        }
        logFailure("disconnect", host: host, result: result)
        return ExitCodes.commandOutcome(host: host, result: result)
    }

    public func connect(_ host: Host, device: String, timeout: Duration) async -> CommandOutcome {
        await connect(host, device: device, timeout: timeout, session: nil)
    }

    public func connect(_ host: Host, device: String, timeout: Duration,
                        session: RemoteSession?) async -> CommandOutcome {
        logging.log(.info, "connect \(host.rawValue) device=\(device)")
        let result: CommandResult
        switch host {
        case .lavoro:
            result = await runner.run(
                spec(config.local.binaryPath, ["connect", device]),
                timeout: timeout
            )
        case .personale:
            if let reason = await bootstrap.ensureReady() {
                return CommandOutcome(status: .transport(reason), report: CommandReport(status: .transport(reason)))
            }
            let command = CommandBuilder.remoteCommand(remoteExecutable: config.remote.binaryPath,
                                                       verb: "connect", device: device)
            result = await transport.execute(command, timeout: timeout, session: session,
                                             allowFirstCallFallback: false)
        }
        logFailure("connect", host: host, result: result)
        return ExitCodes.commandOutcome(host: host, result: result)
    }

    public func remoteBatch(_ kind: RemoteBatchKind, nonce: String, settle: Duration,
                            timeout: Duration) async -> BatchExecution {
        await remoteBatch(kind, nonce: nonce, settle: settle, timeout: timeout, session: nil)
    }

    public func remoteBatch(_ kind: RemoteBatchKind, nonce: String, settle: Duration,
                            timeout: Duration, session: RemoteSession?) async -> BatchExecution {
        if let reason = await bootstrap.ensureReady() {
            return .transport(reason)
        }
        let command: String
        do {
            command = try CommandBuilder.remoteBatchCommand(
                kind: kind,
                nonce: nonce,
                binaryPath: config.remote.binaryPath,
                connectedPath: config.remote.connectedPath,
                dispidPath: config.remote.dispidPath,
                settle: settle
            )
        } catch {
            return .parseFailed(.invalidStructure("\(error)"))
        }

        let group: RemoteGroupKind = kind == .prereqs ? .prereqs : .probe
        if kind == .verify {
            coordinator.begin(.probe, cap: config.timings.remoteRetryBudget)
        }
        let result = await transport.execute(command, timeout: timeout, retryGroup: group,
                                             session: session, allowFirstCallFallback: true)
        if kind == .verify {
            coordinator.end(.probe)
        }

        switch ExitCodes.ssh(result) {
        case .ok:
            guard !result.stdout.contains("<output troncato>") else {
                return .parseFailed(.invalidStructure("output troncato"))
            }
            switch BatchParser.parse(nonce: nonce, stdout: result.stdout, expected: kind.expectedSections) {
            case .success(let sections):
                let summary = sections.map { "\($0.section)=\($0.exitCode)" }.joined(separator: ",")
                logging.log(.debug, "batch \(kind.rawValue) sezioni: \(summary)")
                return .sections(sections)
            case .failure(let error):
                return .parseFailed(error)
            }
        case .transport(let reason):
            return .transport(reason)
        default:
            return .transport(.targetUnreachable)
        }
    }

    public func harden(_ host: Host, timeout: Duration) async -> HardenOutcome {
        await harden(host, timeout: timeout, skipArrange: false)
    }

    public func harden(_ host: Host, timeout: Duration, skipArrange: Bool) async -> HardenOutcome {
        await harden(host, timeout: timeout, skipArrange: skipArrange, session: nil)
    }

    public func harden(_ host: Host, timeout: Duration, skipArrange: Bool,
                       session: RemoteSession?) async -> HardenOutcome {
        if host == .lavoro {
            logging.log(.info, "harden Lavoro: no-op")
            return .ok
        }
        if skipArrange {
            logging.log(.info, "harden Personale: arrange saltato (Sidecar già mirrorato su vdisp)")
            return .ok
        }
        guard let reason = await bootstrap.ensureReady() else {
            let command = CommandBuilder.shellQuote(config.remote.arrangePath)
            let result = await transport.execute(command, timeout: timeout, session: session,
                                                 allowFirstCallFallback: false)
            let status = ExitCodes.ssh(result)
            let outcome = ExitCodes.harden(status: status, stderr: result.stderr)
            logging.log(outcome == .ok ? .info : .warning, "harden \(host.rawValue): \(outcome)")
            return outcome
        }
        logging.log(.warning, "harden \(host.rawValue) non eseguito: \(reason.rawValue)")
        return .warning("harden remoto non eseguito: \(reason.rawValue)")
    }

    public func forgetHostKey() async -> Bool {
        let port = await transport.effectiveConfig().port
        return await transport.knownHosts.forget(host: config.remote.host, port: port)
    }

    private func logFailure(_ verb: String, host: Host, result: CommandResult) {
        guard result.exitCode != 0 || result.timedOut || result.signal != nil else { return }
        let exit = result.exitCode.map(String.init) ?? result.signal.map { "signal \($0)" } ?? "timeout"
        logging.log(.warning, "\(verb) \(host.rawValue) exit=\(exit) stderr=\(LogRedaction.redact(result.stderr))")
    }

    private func spec(_ executable: String, _ arguments: [String]) -> CommandSpec {
        CommandSpec(executable: executable, arguments: arguments, environment: config.environment)
    }
}
