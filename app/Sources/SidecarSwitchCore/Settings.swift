import Foundation

public struct DeviceSettings: Codable, Sendable, Equatable {
    public var name: String

    public init(name: String = "iPad") {
        self.name = name
    }
}

public struct HotkeySettings: Codable, Sendable, Equatable {
    public var keyCode: Int
    public var modifiers: [String]

    public init(keyCode: Int = 1, modifiers: [String] = ["control", "option", "command"]) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let standard = HotkeySettings()

    public static let allowedModifiers: Set<String> = ["control", "option", "command", "shift"]
}

public struct Settings: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var device: DeviceSettings
    public var remote: RemoteSettings
    public var ssh: SSHSettings
    public var hotkey: HotkeySettings
    public var lastLocation: Location
    public var needsReconcile: Bool

    public init(schemaVersion: Int = 2,
                device: DeviceSettings = DeviceSettings(),
                remote: RemoteSettings = .standard,
                ssh: SSHSettings = .standard,
                hotkey: HotkeySettings = .standard,
                lastLocation: Location = .unknown,
                needsReconcile: Bool = false) {
        self.schemaVersion = schemaVersion
        self.device = device
        self.remote = remote
        self.ssh = ssh
        self.hotkey = hotkey
        self.lastLocation = lastLocation
        self.needsReconcile = needsReconcile
    }

    public static let `default` = Settings()

    public var personaleGateDisabled: Bool {
        remote.host.isEmpty
            || remote.binaryPath.isEmpty
            || remote.connectedPath.isEmpty
            || remote.dispidPath.isEmpty
            || remote.arrangePath.isEmpty
    }

    public func expandedIdentityFile(home: URL = SystemHome().homeDirectory) -> String {
        remote.identityFile.expandingLeadingTilde(home: home)
    }
}

public struct SettingsValidationError: Error, Equatable, CustomStringConvertible {
    public var messages: [String]

    public init(_ messages: [String]) {
        self.messages = messages
    }

    public var description: String { messages.joined(separator: "; ") }
}

extension Settings {
    public func validate(home: URL = SystemHome().homeDirectory) throws {
        var messages: [String] = []
        if schemaVersion != 2 { messages.append("schemaVersion \(schemaVersion) non supportata (attesa 2)") }

        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { messages.append("device.name vuoto") }
        if device.name.contains("\n") || device.name.contains("\r") { messages.append("device.name contiene newline") }

        do {
            try CommandBuilder.validate(remote, home: home)
        } catch {
            messages.append("remote: \(error)")
        }

        if !["accept-new", "yes"].contains(ssh.strictHostKeyChecking) {
            messages.append("ssh.strictHostKeyChecking deve essere accept-new o yes")
        }
        if !(1...600).contains(ssh.connectTimeout) {
            messages.append("ssh.connectTimeout fuori range")
        }

        if !(0...127).contains(hotkey.keyCode) { messages.append("hotkey.keyCode fuori range") }
        if hotkey.modifiers.isEmpty { messages.append("hotkey.modifiers vuoto") }
        let unknown = Set(hotkey.modifiers).subtracting(HotkeySettings.allowedModifiers)
        if !unknown.isEmpty { messages.append("hotkey.modifiers non validi: \(unknown.sorted())") }

        if !messages.isEmpty { throw SettingsValidationError(messages) }
    }

    public func validationWarnings() -> [String] {
        var warnings: [String] = []
        if remote.host.isEmpty { warnings.append("remote.host vuoto: Personale disabilitato") }
        let paths: [(String, String)] = [
            ("binaryPath", remote.binaryPath),
            ("connectedPath", remote.connectedPath),
            ("dispidPath", remote.dispidPath),
            ("arrangePath", remote.arrangePath)
        ]
        for (label, value) in paths where value.isEmpty {
            warnings.append("remote.\(label) vuoto: Personale disabilitato")
        }
        if remote.user.isEmpty { warnings.append("remote.user vuoto: ssh usa l'utente locale") }
        return warnings
    }
}

public struct SettingsLoadResult: Sendable, Equatable {
    public var settings: Settings
    public var warning: String?
    public var corrupt: Bool
    public var created: Bool

    public init(settings: Settings, warning: String?, corrupt: Bool, created: Bool) {
        self.settings = settings
        self.warning = warning
        self.corrupt = corrupt
        self.created = created
    }
}

public final class SettingsStore: @unchecked Sendable {
    public let directory: URL
    public let configURL: URL
    public let backupURL: URL
    public let home: URL

    public init(directory: URL, home: URL = SystemHome().homeDirectory) {
        self.directory = directory
        self.home = home
        self.configURL = directory.appendingPathComponent("config.json")
        self.backupURL = directory.appendingPathComponent("config.json.bak")
    }

    public func ensureDirectory() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        chmod(directory.path, 0o700)
    }

    public func load() -> SettingsLoadResult {
        do {
            try ensureDirectory()
        } catch {
            return SettingsLoadResult(settings: corruptDefaults(), warning: "Impossibile creare \(directory.path): \(error)",
                                      corrupt: true, created: false)
        }

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            let settings = Settings.default
            let written = (try? save(settings)) != nil
            return SettingsLoadResult(settings: settings,
                                      warning: written ? nil : "Impossibile creare config.json",
                                      corrupt: false, created: written)
        }

        do {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(Settings.self, from: data)
            try decoded.validate(home: home)
            return SettingsLoadResult(settings: decoded, warning: nil, corrupt: false, created: false)
        } catch {
            return SettingsLoadResult(settings: corruptDefaults(),
                                      warning: "config.json non valido, preservato (\(configURL.path)): \(error)",
                                      corrupt: true, created: false)
        }
    }

    public func validate(_ settings: Settings) -> String? {
        do {
            try settings.validate(home: home)
            return nil
        } catch {
            return "\(error)"
        }
    }

    private func corruptDefaults() -> Settings {
        Settings(lastLocation: .unknown, needsReconcile: true)
    }

    @discardableResult
    public func save(_ settings: Settings) throws -> URL {
        try settings.validate(home: home)
        try ensureDirectory()
        let manager = FileManager.default

        if manager.fileExists(atPath: configURL.path) {
            try? manager.removeItem(at: backupURL)
            try? manager.copyItem(at: configURL, to: backupURL)
            chmod(backupURL.path, 0o600)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)

        let temporary = directory.appendingPathComponent(".config.json.tmp-\(getpid())-\(UUID().uuidString)")
        manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let handle = try? FileHandle(forWritingTo: temporary) else {
            throw SettingsValidationError(["impossibile aprire \(temporary.path)"])
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? manager.removeItem(at: temporary)
            throw error
        }

        chmod(temporary.path, 0o600)
        guard rename(temporary.path, configURL.path) == 0 else {
            let code = errno
            try? manager.removeItem(at: temporary)
            throw SettingsValidationError(["rename config.json fallito: errno \(code)"])
        }
        chmod(configURL.path, 0o600)
        return configURL
    }
}
