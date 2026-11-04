import Foundation

public protocol HomeProviding: Sendable {
    var homeDirectory: URL { get }
}

public struct SystemHome: HomeProviding {
    public init() {}
    public var homeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }
}

public struct AppPaths: Sendable, Equatable {
    public var home: URL

    public init(home: URL = SystemHome().homeDirectory) {
        self.home = home
    }

    public static var system: AppPaths { AppPaths() }

    public var supportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/SidecarSwitch", isDirectory: true)
    }

    public var logDirectory: URL {
        home.appendingPathComponent("Library/Logs/SidecarSwitch", isDirectory: true)
    }

    public var knownHostsDirectory: URL {
        home.appendingPathComponent(".sidecar-switch", isDirectory: true)
    }

    public var runDirectory: URL {
        home.appendingPathComponent(".sidecar-switch/run", isDirectory: true)
    }

    public var knownHostsPath: String {
        knownHostsDirectory.appendingPathComponent("known_hosts").path
    }

    public var legacyKnownHostsPath: String {
        supportDirectory.appendingPathComponent("known_hosts").path
    }

    public var sshConfigPath: String {
        home.appendingPathComponent(".ssh/config").path
    }

    public var toolsDirectory: URL {
        supportDirectory.appendingPathComponent("tools", isDirectory: true)
    }

    public var configURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    public var logFileURL: URL {
        logDirectory.appendingPathComponent("sidecar-switch.log")
    }

    public static func bundledToolsVersion(resources: URL? = Bundle.main.resourceURL) -> String? {
        guard let resources else { return nil }
        let url = resources.appendingPathComponent("TOOLS_VERSION")
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public extension String {
    func expandingLeadingTilde(home: URL) -> String {
        if self == "~" { return home.path }
        if hasPrefix("~/") { return home.path + String(dropFirst()) }
        return self
    }
}
