import Foundation

public struct EnvironmentSnapshot: Sendable, Equatable {
    public var variables: [String: String]
    public var proxyAvailable: Bool

    public init(variables: [String: String], proxyAvailable: Bool) {
        self.variables = variables
        self.proxyAvailable = proxyAvailable
    }
}

public protocol EnvironmentProviding: Sendable {
    func capture() async -> EnvironmentSnapshot?
}

public enum EnvironmentAllowlist {
    public static let fixedKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "PATH", "LANG",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE"
    ]

    public static let proxyKeys: Set<String> = [
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"
    ]

    public static let certificateKeys: Set<String> = [
        "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE"
    ]

    public static func isAllowed(_ key: String) -> Bool {
        fixedKeys.contains(key) || key.hasPrefix("LC_")
    }

    public static func filter(_ raw: [String: String]) -> [String: String] {
        raw.filter { isAllowed($0.key) }
    }

    public static func containsProxy(_ variables: [String: String]) -> Bool {
        variables.keys.contains { proxyKeys.contains($0) }
    }

    public static func containsCA(_ variables: [String: String]) -> Bool {
        variables.keys.contains { certificateKeys.contains($0) }
    }
}

public enum BaseEnvironment {
    public static func make() -> [String: String] {
        let user = NSUserName()
        return [
            "HOME": NSHomeDirectory(),
            "USER": user,
            "LOGNAME": user,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8"
        ]
    }

    public static func shellPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let shell = environment["SHELL"], !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }
}

public final class LoginShellEnvironmentProvider: EnvironmentProviding, @unchecked Sendable {
    private let runner: any CommandRunning
    private let logging: any SwitchLogging
    private let shellPath: String
    private let timeout: Duration
    private let maxBytes: Int
    private let fallback: ProxyFallback?
    private let lock = NSLock()
    private var cached: EnvironmentSnapshot?

    public init(runner: any CommandRunning = SystemCommandRunner(),
                logging: any SwitchLogging = NoopLogging(),
                shellPath: String? = nil,
                timeout: Duration = .seconds(5),
                maxBytes: Int = 64 * 1024,
                fallback: ProxyFallback? = ProxyFallback()) {
        self.runner = runner
        self.logging = logging
        self.shellPath = shellPath ?? BaseEnvironment.shellPath()
        self.timeout = timeout
        self.maxBytes = maxBytes
        self.fallback = fallback
    }

    private func cachedSnapshot() -> EnvironmentSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    private func storeSnapshot(_ value: EnvironmentSnapshot) -> EnvironmentSnapshot {
        lock.lock()
        if cached == nil { cached = value }
        let result = cached ?? value
        lock.unlock()
        return result
    }

    public func capture() async -> EnvironmentSnapshot? {
        if let cached = cachedSnapshot() { return cached }
        let snapshot = await compute()
        return storeSnapshot(snapshot)
    }

    private func snapshot(arguments: [String]) async -> [String: String]? {
        let result = await runner.run(
            CommandSpec(executable: shellPath, arguments: arguments),
            timeout: timeout
        )
        guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        let capped = String(result.stdout.prefix(maxBytes))
        var raw: [String: String] = [:]
        for entry in capped.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            let value = String(entry[entry.index(after: equals)...])
            guard !key.isEmpty else { continue }
            raw[key] = value
        }
        return EnvironmentAllowlist.filter(raw)
    }

    private func merge(_ variables: inout [String: String], with next: [String: String]?) {
        guard let next, !next.isEmpty else { return }
        for (key, value) in next where !value.isEmpty {
            variables[key] = value
        }
    }

    private func compute() async -> EnvironmentSnapshot {
        var variables = await snapshot(arguments: ["-lc", "env -0"]) ?? [:]

        if !EnvironmentAllowlist.containsProxy(variables) || !EnvironmentAllowlist.containsCA(variables) {
            let interactive = await snapshot(arguments: ["-lic", "env -0"])
            merge(&variables, with: interactive)
        }

        if !EnvironmentAllowlist.containsProxy(variables) || !EnvironmentAllowlist.containsCA(variables) {
            let sourced = await snapshot(arguments: ["-lc", "source ~/.zshrc >/dev/null 2>&1; env -0"])
            merge(&variables, with: sourced)
        }

        if variables.isEmpty {
            logging.log(.warning, "login shell: snapshot ambiente non disponibile, uso allowlist base (proxy/CA non ereditati)")
            return EnvironmentSnapshot(variables: BaseEnvironment.make(), proxyAvailable: false)
        }

        for (key, value) in BaseEnvironment.make() where variables[key] == nil {
            variables[key] = value
        }

        if !EnvironmentAllowlist.containsProxy(variables) || !EnvironmentAllowlist.containsCA(variables) {
            if let fallback, let recovered = await fallback.discover(existing: variables) {
                for (key, value) in recovered where variables[key] == nil {
                    variables[key] = value
                }
            }
        }

        let proxyAvailable = EnvironmentAllowlist.containsProxy(variables)
        if !proxyAvailable {
            logging.log(.warning, "login shell: proxy/CA non disponibili nell'ambiente (rete senza proxy o configurazione mancante)")
        }
        return EnvironmentSnapshot(variables: variables, proxyAvailable: proxyAvailable)
    }
}

public final class ProxyFallback: @unchecked Sendable {
    private let runner: any CommandRunning
    private let timeout: Duration

    public init(runner: any CommandRunning = SystemCommandRunner(), timeout: Duration = .seconds(2)) {
        self.runner = runner
        self.timeout = timeout
    }

    public func discover(existing: [String: String]) async -> [String: String]? {
        var result: [String: String] = [:]

        let scutil = await runner.run(
            CommandSpec(executable: "/usr/sbin/scutil", arguments: ["--proxy"]),
            timeout: timeout
        )
        if scutil.exitCode == 0 {
            let values = Self.parseScutil(scutil.stdout)
            for (key, value) in values where existing[key] == nil {
                result[key] = value
            }
        }

        if result.isEmpty {
            for key in EnvironmentAllowlist.proxyKeys.union(EnvironmentAllowlist.certificateKeys) {
                let value = await runner.run(
                    CommandSpec(executable: "/bin/launchctl", arguments: ["getenv", key]),
                    timeout: timeout
                )
                guard value.exitCode == 0 else { continue }
                let text = value.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result[key] = text }
            }
        }

        return result.isEmpty ? nil : result
    }

    public static func parseScutil(_ output: String) -> [String: String] {
        var fields: [String: String] = [:]
        for raw in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }

        func endpoint(_ hostKey: String, _ portKey: String, scheme: String) -> String? {
            guard let host = fields[hostKey], !host.isEmpty, host != "0.0.0.0" else { return nil }
            let port = fields[portKey] ?? ""
            return port.isEmpty ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
        }

        var result: [String: String] = [:]
        if let http = endpoint("HTTPProxy", "HTTPPort", scheme: "http") {
            result["http_proxy"] = http
            result["HTTP_PROXY"] = http
        }
        if let https = endpoint("HTTPSProxy", "HTTPSPort", scheme: "http") {
            result["https_proxy"] = https
            result["HTTPS_PROXY"] = https
        }
        if let pac = fields["ProxyAutoConfigURLString"], !pac.isEmpty {
            result["http_proxy"] = pac
        }
        return result
    }
}
