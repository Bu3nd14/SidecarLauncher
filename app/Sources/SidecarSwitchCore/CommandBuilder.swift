import Foundation

public struct CommandSpec: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]?

    public init(executable: String, arguments: [String] = [], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32?
    public var signal: Int32?
    public var timedOut: Bool
    public var launchError: String?
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32? = nil, signal: Int32? = nil, timedOut: Bool = false,
                launchError: String? = nil, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.signal = signal
        self.timedOut = timedOut
        self.launchError = launchError
        self.stdout = stdout
        self.stderr = stderr
    }

    public static func launched(exitCode: Int32, stdout: String = "", stderr: String = "") -> CommandResult {
        CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}

public protocol CommandRunning: Sendable {
    func run(_ spec: CommandSpec, timeout: Duration) async -> CommandResult
}

public struct RemoteSettings: Codable, Sendable, Equatable {
    public var host: String
    public var user: String
    public var port: Int
    public var identityFile: String
    public var binaryPath: String
    public var connectedPath: String
    public var dispidPath: String
    public var mirrorPath: String
    public var arrangePath: String

    public init(host: String, user: String, port: Int, identityFile: String,
                binaryPath: String, connectedPath: String, dispidPath: String,
                mirrorPath: String, arrangePath: String) {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.binaryPath = binaryPath
        self.connectedPath = connectedPath
        self.dispidPath = dispidPath
        self.mirrorPath = mirrorPath
        self.arrangePath = arrangePath
    }

    public static let standard = RemoteSettings(
        host: "",
        user: "",
        port: 22,
        identityFile: "~/.ssh/id_ed25519_sidecar_switch",
        binaryPath: "",
        connectedPath: "",
        dispidPath: "",
        mirrorPath: "",
        arrangePath: ""
    )
}

public struct SSHSettings: Codable, Sendable, Equatable {
    public var strictHostKeyChecking: String
    public var connectTimeout: Int

    public init(strictHostKeyChecking: String = "accept-new", connectTimeout: Int = 15) {
        self.strictHostKeyChecking = strictHostKeyChecking
        self.connectTimeout = connectTimeout
    }

    public static let standard = SSHSettings()
}

public enum CommandBuilderError: Error, Equatable, CustomStringConvertible {
    case emptyHost
    case invalidHost(String)
    case invalidUser(String)
    case invalidPort(Int)
    case pathNotAbsolute(String)
    case invalidPath(String)

    public var description: String {
        switch self {
        case .emptyHost: return "host SSH vuoto"
        case .invalidHost(let value): return "host SSH non valido: \(value)"
        case .invalidUser(let value): return "utente SSH non valido: \(value)"
        case .invalidPort(let value): return "porta SSH non valida: \(value)"
        case .pathNotAbsolute(let value): return "path non assoluto: \(value)"
        case .invalidPath(let value): return "path non valido: \(value)"
        }
    }
}

public enum CommandBuilder {
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func validateHost(_ host: String) throws {
        guard !host.isEmpty else { throw CommandBuilderError.emptyHost }
        guard !host.hasPrefix("-") else { throw CommandBuilderError.invalidHost(host) }
        guard !host.contains("@") else { throw CommandBuilderError.invalidHost(host) }
        guard !host.contains("\n"), !host.contains("\r") else { throw CommandBuilderError.invalidHost(host) }

        var scalars = Array(host.unicodeScalars)
        if scalars.first == "[", scalars.last == "]" {
            scalars.removeFirst()
            scalars.removeLast()
            guard !scalars.isEmpty else { throw CommandBuilderError.invalidHost(host) }
            for scalar in scalars {
                guard allowedIPv6Scalar(scalar) else { throw CommandBuilderError.invalidHost(host) }
            }
            return
        }
        if host.contains(":") { throw CommandBuilderError.invalidHost(host) }
        for scalar in scalars {
            guard allowedHostScalar(scalar) else { throw CommandBuilderError.invalidHost(host) }
        }
    }

    private static func allowedHostScalar(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        switch scalar {
        case ".", "-", "_": return true
        default: return false
        }
    }

    private static func allowedIPv6Scalar(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        switch scalar {
        case ":", ".", "%", "-", "_": return true
        default: return false
        }
    }

    public static func validateUser(_ user: String) throws {
        guard !user.isEmpty else { return }
        guard !user.hasPrefix("-"), !user.contains("@") else {
            throw CommandBuilderError.invalidUser(user)
        }
        for scalar in user.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) { continue }
            switch scalar {
            case ".", "-", "_": continue
            default: throw CommandBuilderError.invalidUser(user)
            }
        }
    }

    public static func validatePort(_ port: Int) throws {
        guard (1...65535).contains(port) else { throw CommandBuilderError.invalidPort(port) }
    }

    public static func validateAbsolutePath(_ path: String) throws {
        guard path.hasPrefix("/") else { throw CommandBuilderError.pathNotAbsolute(path) }
        guard !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else {
            throw CommandBuilderError.invalidPath(path)
        }
    }

    public static func validateOptionalAbsolutePath(_ path: String, label: String) throws {
        guard !path.isEmpty else { return }
        guard !path.hasPrefix("~") else { throw CommandBuilderError.pathNotAbsolute(path) }
        guard path.hasPrefix("/") else { throw CommandBuilderError.pathNotAbsolute(path) }
        guard !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else {
            throw CommandBuilderError.invalidPath(label)
        }
    }

    public static func validateIdentityFile(_ value: String, home: URL) throws {
        guard !value.isEmpty else { throw CommandBuilderError.invalidPath("identityFile vuoto") }
        let expanded = value.expandingLeadingTilde(home: home)
        guard expanded.hasPrefix("/") else { throw CommandBuilderError.pathNotAbsolute(value) }
        guard !expanded.contains("\n"), !expanded.contains("\r"), !expanded.contains("\0") else {
            throw CommandBuilderError.invalidPath("identityFile")
        }
    }

    public static func validate(_ remote: RemoteSettings, home: URL = SystemHome().homeDirectory) throws {
        if !remote.host.isEmpty { try validateHost(remote.host) }
        if !remote.user.isEmpty { try validateUser(remote.user) }
        try validatePort(remote.port)
        try validateIdentityFile(remote.identityFile, home: home)
        try validateOptionalAbsolutePath(remote.binaryPath, label: "binaryPath")
        try validateOptionalAbsolutePath(remote.connectedPath, label: "connectedPath")
        try validateOptionalAbsolutePath(remote.dispidPath, label: "dispidPath")
        try validateOptionalAbsolutePath(remote.mirrorPath, label: "mirrorPath")
        try validateOptionalAbsolutePath(remote.arrangePath, label: "arrangePath")
    }

    public static func remoteCommand(remoteExecutable: String, verb: String, device: String?) -> String {
        var command = shellQuote(remoteExecutable) + " " + verb
        if let device {
            command += " " + shellQuote(device)
        }
        return command
    }

    public static let sshExecutable = "/usr/bin/ssh"

    public static func sshArguments(
        remote: RemoteSettings,
        ssh: SSHSettings,
        knownHostsPath: String,
        command: String,
        firstConnect: Bool,
        home: URL = SystemHome().homeDirectory,
        sshConfigPath: String? = nil
    ) throws -> [String] {
        try validate(remote, home: home)
        guard !remote.host.isEmpty else { throw CommandBuilderError.emptyHost }
        try validateAbsolutePath(knownHostsPath)
        guard (1...600).contains(ssh.connectTimeout) else {
            throw CommandBuilderError.invalidPort(ssh.connectTimeout)
        }
        guard ssh.strictHostKeyChecking == "accept-new" || ssh.strictHostKeyChecking == "yes" else {
            throw CommandBuilderError.invalidHost("StrictHostKeyChecking=\(ssh.strictHostKeyChecking)")
        }

        var args: [String] = [sshExecutable]
        if let sshConfigPath, !sshConfigPath.isEmpty {
            try validateAbsolutePath(sshConfigPath)
            args.append(contentsOf: ["-F", sshConfigPath])
        }
        let identity = remote.identityFile.expandingLeadingTilde(home: home)
        if !identity.isEmpty {
            args.append(contentsOf: ["-i", identity])
        }
        args.append(contentsOf: [
            "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(ssh.connectTimeout)",
            "-o", "StrictHostKeyChecking=\(ssh.strictHostKeyChecking)",
            "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-o", "LogLevel=\(firstConnect ? "INFO" : "ERROR")",
            "-T"
        ])
        if remote.port != 22 {
            args.append(contentsOf: ["-p", "\(remote.port)"])
        }
        let target = remote.user.isEmpty ? remote.host : "\(remote.user)@\(remote.host)"
        args.append(target)
        args.append(command)
        return args
    }

    public static func sshSpec(
        remote: RemoteSettings,
        ssh: SSHSettings,
        knownHostsPath: String,
        command: String,
        firstConnect: Bool,
        home: URL = SystemHome().homeDirectory,
        sshConfigPath: String? = nil,
        executable: String = CommandBuilder.sshExecutable
    ) throws -> CommandSpec {
        var argv = try sshArguments(remote: remote, ssh: ssh, knownHostsPath: knownHostsPath,
                                    command: command, firstConnect: firstConnect,
                                    home: home, sshConfigPath: sshConfigPath)
        argv[0] = executable
        return CommandSpec(executable: argv[0], arguments: Array(argv.dropFirst()))
    }

    public static func sshQueryArguments(
        remote: RemoteSettings,
        ssh: SSHSettings,
        home: URL = SystemHome().homeDirectory,
        sshConfigPath: String? = nil
    ) throws -> [String] {
        try validate(remote, home: home)
        guard !remote.host.isEmpty else { throw CommandBuilderError.emptyHost }
        var args: [String] = [sshExecutable]
        if let sshConfigPath, !sshConfigPath.isEmpty {
            try validateAbsolutePath(sshConfigPath)
            args.append(contentsOf: ["-F", sshConfigPath])
        }
        if remote.port != 22 {
            args.append(contentsOf: ["-p", "\(remote.port)"])
        }
        args.append("-G")
        let target = remote.user.isEmpty ? remote.host : "\(remote.user)@\(remote.host)"
        args.append(target)
        return args
    }

    public static func localSpec(executable: String, verb: String, device: String?) -> CommandSpec {
        var args = [verb]
        if let device { args.append(device) }
        return CommandSpec(executable: executable, arguments: args)
    }
}
