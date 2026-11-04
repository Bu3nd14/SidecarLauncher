import Foundation

public enum ExitCodes {
    public static func local(_ result: CommandResult) -> CommandStatus {
        if let error = result.launchError {
            return .launchFailed(error)
        }
        if result.timedOut { return .timedOut }
        if let signal = result.signal { return .crashed(signal: signal) }
        guard let exitCode = result.exitCode else { return .launchFailed("nessun exit code") }
        return exitCode == 0 ? .ok : .exited(exitCode)
    }

    public static func ssh(_ result: CommandResult) -> CommandStatus {
        if let error = result.launchError {
            return .launchFailed(error)
        }
        if result.timedOut { return .transport(.targetUnreachable) }
        if let signal = result.signal {
            return .transport(signal == SIGKILL || signal == SIGTERM ? .targetUnreachable : .remoteCrashed)
        }
        guard let exitCode = result.exitCode else { return .launchFailed("nessun exit code") }

        switch exitCode {
        case 0...125:
            return exitCode == 0 ? .ok : .exited(exitCode)
        case 126:
            return .transport(.remoteBootstrap)
        case 127:
            return .transport(.remoteBootstrap)
        case 128...254:
            return .transport(.remoteCrashed)
        case 255:
            return .transport(transportReason(stderr: result.stderr))
        default:
            return .launchFailed("exit code inatteso: \(exitCode)")
        }
    }

    public static func isTransportWhitelisted(stderr: String) -> Bool {
        let lower = stderr.lowercased()
        let patterns = [
            "connection timed out during banner exchange",
            "operation timed out",
            "connection reset",
            "kex_exchange_identification",
            "connection closed by"
        ]
        if patterns.contains(where: { lower.contains($0) }) { return true }
        return lower.contains("proxycommand") && lower.contains("exited with status")
    }

    public static func connectExit4IsTransient(stderr: String) -> Bool {
        let lower = stderr.lowercased()
        let markers = ["-455", "-101", "-203",
                       "sidecarerrordisplayawdldegraded",
                       "sidecarerrorservicedisconnected",
                       "sidecarerrordevicewifinotenabled"]
        return markers.contains { lower.contains($0) }
    }

    public static func transportReason(stderr: String) -> Reason {
        let lower = stderr.lowercased()
        if lower.contains("host key verification failed")
            || lower.contains("remote host identification has changed")
            || lower.contains("host key mismatch")
            || lower.contains("host key has changed") {
            return .hostKeyMismatch
        }
        if lower.contains("permission denied")
            || lower.contains("publickey")
            || lower.contains("too many authentication failures")
            || lower.contains("authentication failed") {
            return .authFailed
        }
        return .targetUnreachable
    }

    public static func probeReport(host: Host, result: CommandResult) -> ProbeReport {
        let status = host == .lavoro ? local(result) : ssh(result)
        return probeReport(status: status, stdout: result.stdout, stderr: result.stderr)
    }

    public static func probeReport(status: CommandStatus, stdout: String, stderr: String) -> ProbeReport {
        switch status {
        case .ok:
            let parsed = ConnectedParser.parse(stdout)
            guard !parsed.devices.isEmpty else {
                return ProbeReport(state: .unknown, detail: "connected exit 0 senza device")
            }
            if let count = parsed.count, count != parsed.devices.count {
                return ProbeReport(state: .unknown, detail: "connected count=\(count) device=\(parsed.devices.count)")
            }
            return ProbeReport(state: .connected(devices: parsed.devices))
        case .exited(1):
            return ProbeReport(state: .disconnected)
        case .exited(3):
            return ProbeReport(state: .unknown, detail: "private API rotta (exit 3)")
        case .exited(let code):
            return ProbeReport(state: .unknown, detail: "connected exit \(code)")
        case .crashed(let signal):
            return ProbeReport(state: .unknown, detail: "connected terminato da segnale \(signal)")
        case .timedOut:
            return ProbeReport(state: .unknown, detail: "connected timeout")
        case .launchFailed(let message):
            return ProbeReport(state: .unknown, detail: "launch failed: \(message)")
        case .transport(let reason):
            return ProbeReport(state: .unreachable, reason: reason, detail: stderr)
        }
    }

    public static func devicesReport(host: Host, result: CommandResult) -> DevicesReport {
        let status = host == .lavoro ? local(result) : ssh(result)
        return DevicesReport(status: status, names: DeviceListParser.parse(result.stdout),
                             report: CommandReport(status: status, stdout: result.stdout,
                                                   stderr: result.stderr, exitCode: result.exitCode))
    }

    public static func displaysReport(host: Host, result: CommandResult) -> DisplaysReport {
        let status = host == .lavoro ? local(result) : ssh(result)
        return DisplaysReport(status: status, displays: DisplayParser.parse(result.stdout),
                              report: CommandReport(status: status, stdout: result.stdout,
                                                    stderr: result.stderr, exitCode: result.exitCode))
    }

    public static func commandOutcome(host: Host, result: CommandResult) -> CommandOutcome {
        let status = host == .lavoro ? local(result) : ssh(result)
        return CommandOutcome(status: status,
                              report: CommandReport(status: status, stdout: result.stdout,
                                                    stderr: result.stderr, exitCode: result.exitCode))
    }

    public static func harden(status: CommandStatus, stderr: String) -> HardenOutcome {
        switch status {
        case .ok: return .ok
        case .exited(0): return .ok
        case .exited(3): return .warning("arrange: layout applicato ma non verificato")
        case .exited(2): return .warning("arrange: nessun display Sidecar/virtuale")
        case .exited(1): return .warning("arrange: errore CG")
        case .exited(let code): return .warning("arrange exit \(code)")
        case .crashed(let signal): return .warning("arrange segnale \(signal)")
        case .timedOut: return .warning("arrange timeout")
        case .launchFailed(let message): return .warning("arrange non eseguibile: \(message)")
        case .transport(let reason): return .warning("arrange remoto: \(reason.rawValue)")
        }
    }
}
