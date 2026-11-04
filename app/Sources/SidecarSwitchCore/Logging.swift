import Foundation
import os

public enum LogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

public protocol SwitchLogging: Sendable {
    func log(_ level: LogLevel, _ message: String)
}

public struct NoopLogging: SwitchLogging {
    public init() {}
    public func log(_ level: LogLevel, _ message: String) {}
}

public struct ArrayLogging: SwitchLogging {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var entries: [(LogLevel, String)] = []
    }

    private let storage = Storage()

    public init() {}

    public func log(_ level: LogLevel, _ message: String) {
        storage.lock.lock()
        storage.entries.append((level, message))
        storage.lock.unlock()
    }

    public var entries: [(LogLevel, String)] {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.entries
    }

    public var messages: [String] { entries.map { $0.1 } }

    public func contains(_ needle: String) -> Bool {
        messages.contains { $0.contains(needle) }
    }
}

public final class SwitchLogger: SwitchLogging, @unchecked Sendable {
    public let fileURL: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private let osLogger: Logger
    private let formatter: ISO8601DateFormatter

    public init(fileURL: URL, maxBytes: Int = 5 * 1024 * 1024) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.osLogger = Logger(subsystem: "local.sidecar.SidecarSwitch", category: "switch")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter
        ensureDirectory()
    }

    private func ensureDirectory() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
    }

    public func log(_ level: LogLevel, _ message: String) {
        lock.lock()
        defer { lock.unlock() }

        switch level {
        case .debug: osLogger.debug("\(message, privacy: .private)")
        case .info: osLogger.info("\(message, privacy: .private)")
        case .warning: osLogger.warning("\(message, privacy: .private)")
        case .error: osLogger.error("\(message, privacy: .private)")
        }

        rotateIfNeeded()
        let line = "\(formatter.string(from: Date())) [\(level.rawValue.uppercased())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    private func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= maxBytes else { return }
        let rotated = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SidecarSwitch", isDirectory: true)
        return base.appendingPathComponent("sidecar-switch.log")
    }
}

public enum LogRedaction {
    private static let jwt = try? NSRegularExpression(pattern: "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+")
    private static let query = try? NSRegularExpression(pattern: "(?i)((?:^|[\\s?&])(?:token|code|cf-access-token)=)[^&\\s]+")
    private static let header = try? NSRegularExpression(pattern: "(?i)(CF-Access-Jwt-Assertion\\s*:\\s*)\\S+")

    public static func redact(_ text: String, limit: Int = 4096) -> String {
        var value = text
        if let jwt {
            value = jwt.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
                                                 withTemplate: "<redacted-jwt>")
        }
        if let query {
            value = query.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
                                                   withTemplate: "$1<redacted>")
        }
        if let header {
            value = header.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
                                                    withTemplate: "$1<redacted>")
        }
        if value.count > limit {
            value = String(value.prefix(limit)) + "<troncato>"
        }
        return value
    }
}
