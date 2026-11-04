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
    func beginRemoteGroup(_ kind: RemoteGroupKind) async
    func endRemoteGroup(_ kind: RemoteGroupKind) async
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

    public func probe(_ host: Host, timeout: Duration) async -> ProbeReport {
        await probe(host, timeout: timeout, retry: true)
    }

    public func probe(_ host: Host, timeout: Duration, retry: Bool) async -> ProbeReport {
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
                                             retryGroup: retry ? .probe : nil)
            if retry { coordinator.end(.probe) }
        }
        return ExitCodes.probeReport(host: host, result: result)
    }

    public func devices(_ host: Host, timeout: Duration) async -> DevicesReport {
        await devices(host, timeout: timeout, retry: true)
    }

    public func devices(_ host: Host, timeout: Duration, retry: Bool) async -> DevicesReport {
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
            result = await transport.execute(command, timeout: timeout, retryGroup: retry ? .prereqs : nil)
        }
        return ExitCodes.devicesReport(host: host, result: result)
    }

    public func displays(_ host: Host, timeout: Duration) async -> DisplaysReport {
        let result: CommandResult
        switch host {
        case .lavoro:
            result = await runner.run(spec(config.local.dispidPath, []), timeout: timeout)
        case .personale:
            if let reason = await bootstrap.ensureReady() {
                return DisplaysReport(status: .transport(reason), displays: [], report: CommandReport(status: .transport(reason)))
            }
            result = await transport.execute(CommandBuilder.shellQuote(config.remote.dispidPath),
                                             timeout: timeout, retryGroup: .prereqs)
        }
        return ExitCodes.displaysReport(host: host, result: result)
    }

    public func disconnect(_ host: Host, device: String, timeout: Duration) async -> CommandOutcome {
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
            result = await transport.execute(command, timeout: timeout)
        }
        logFailure("disconnect", host: host, result: result)
        return ExitCodes.commandOutcome(host: host, result: result)
    }

    public func connect(_ host: Host, device: String, timeout: Duration) async -> CommandOutcome {
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
            result = await transport.execute(command, timeout: timeout)
        }
        logFailure("connect", host: host, result: result)
        return ExitCodes.commandOutcome(host: host, result: result)
    }

    public func harden(_ host: Host, timeout: Duration) async -> HardenOutcome {
        if host == .lavoro {
            logging.log(.info, "harden Lavoro: no-op")
            return .ok
        }
        guard let reason = await bootstrap.ensureReady() else {
            let command = CommandBuilder.shellQuote(config.remote.arrangePath)
            let result = await transport.execute(command, timeout: timeout)
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
