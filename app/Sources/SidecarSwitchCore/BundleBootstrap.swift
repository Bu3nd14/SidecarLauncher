import Darwin
import Foundation

public enum BundleBootstrapError: Error, Equatable, CustomStringConvertible {
    case missingTool(String)
    case emptyToolsVersion
    case notADirectory(String)
    case swapFailed(String)

    public var description: String {
        switch self {
        case .missingTool(let name): return "tool mancante nel bundle: \(name)"
        case .emptyToolsVersion: return "TOOLS_VERSION vuota"
        case .notADirectory(let path): return "non è una directory: \(path)"
        case .swapFailed(let message): return "swap della directory tools fallito: \(message)"
        }
    }
}

public struct BundleBootstrap: Sendable {
    public static let toolNames = ["SidecarLauncher", "connected", "dispid", "mirror", "arrange"]

    public let resourcesDirectory: URL
    public let supportDirectory: URL
    public let toolsVersion: String

    public init(resourcesDirectory: URL, supportDirectory: URL, toolsVersion: String) {
        self.resourcesDirectory = resourcesDirectory
        self.supportDirectory = supportDirectory
        self.toolsVersion = toolsVersion
    }

    public var toolsDirectory: URL { supportDirectory.appendingPathComponent("tools", isDirectory: true) }

    public func synchronize(force: Bool = false) throws {
        let version = toolsVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { throw BundleBootstrapError.emptyToolsVersion }

        let manager = FileManager.default
        if !manager.fileExists(atPath: supportDirectory.path) {
            try manager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        }
        chmod(supportDirectory.path, 0o700)

        if !force, currentToolsVersion() == version, toolsAreUsable() {
            removeQuarantineFromTools()
            writeSupportVersion(version)
            return
        }

        let staging = supportDirectory.appendingPathComponent(".tools.new-\(UUID().uuidString)", isDirectory: true)
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        chmod(staging.path, 0o700)

        do {
            for name in Self.toolNames {
                let source = resourcesDirectory.appendingPathComponent(name)
                guard manager.fileExists(atPath: source.path) else {
                    throw BundleBootstrapError.missingTool(name)
                }
                let destination = staging.appendingPathComponent(name)
                try manager.copyItem(at: source, to: destination)
                chmod(destination.path, 0o755)
                removeQuarantine(destination.path)
            }
            let versionFile = staging.appendingPathComponent("VERSION")
            manager.createFile(atPath: versionFile.path, contents: Data((version + "\n").utf8),
                               attributes: [.posixPermissions: 0o644])
            chmod(versionFile.path, 0o644)
            chmod(staging.path, 0o700)
            try swapDirectory(from: staging, to: toolsDirectory)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }

        removeQuarantineFromTools()
        writeSupportVersion(version)
    }

    private func writeSupportVersion(_ version: String) {
        let file = supportDirectory.appendingPathComponent("VERSION")
        FileManager.default.createFile(atPath: file.path, contents: Data((version + "\n").utf8),
                                       attributes: [.posixPermissions: 0o644])
        chmod(file.path, 0o644)
    }

    private func currentToolsVersion() -> String? {
        let file = toolsDirectory.appendingPathComponent("VERSION")
        guard let data = try? Data(contentsOf: file),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toolsAreUsable() -> Bool {
        for name in Self.toolNames {
            let path = toolsDirectory.appendingPathComponent(name).path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return false
            }
            guard access(path, X_OK) == 0 else { return false }
        }
        return true
    }

    private func swapDirectory(from staging: URL, to destination: URL) throws {
        let manager = FileManager.default
        var destinationIsDirectory: ObjCBool = false
        if manager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory) {
            guard destinationIsDirectory.boolValue else {
                throw BundleBootstrapError.notADirectory(destination.path)
            }
            let previous = supportDirectory.appendingPathComponent(".tools.old-\(UUID().uuidString)", isDirectory: true)
            guard rename(destination.path, previous.path) == 0 else {
                throw BundleBootstrapError.swapFailed("mv tools -> \(previous.lastPathComponent) errno \(errno)")
            }
            guard rename(staging.path, destination.path) == 0 else {
                let code = errno
                _ = rename(previous.path, destination.path)
                throw BundleBootstrapError.swapFailed("mv staging -> tools errno \(code)")
            }
            try? manager.removeItem(at: previous)
        } else {
            guard rename(staging.path, destination.path) == 0 else {
                throw BundleBootstrapError.swapFailed("mv staging -> tools errno \(errno)")
            }
        }
    }

    private func removeQuarantineFromTools() {
        for name in Self.toolNames {
            removeQuarantine(toolsDirectory.appendingPathComponent(name).path)
        }
    }

    private func removeQuarantine(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        removexattr(path, "com.apple.quarantine", 0)
    }
}
