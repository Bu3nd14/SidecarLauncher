import Foundation

public enum ControlSocket {
    public static let controlPersistSeconds = 20
    public static let controlCommandTimeout: Duration = .seconds(5)
    public static let maxPathBytes = 86
    public static let maxRemoteGapSeconds = 10

    public static var controlPersistExceedsMaxGap: Bool {
        controlPersistSeconds > maxRemoteGapSeconds
    }

    public static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    public static func hex16(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }

    public static func socketName(host: String, user: String, port: Int) -> String {
        "ssc-\(hex16(fnv1a64("\(user)@\(host):\(port)"))).sock"
    }

    public static func path(runDirectory: String, host: String, user: String, port: Int) -> String {
        (runDirectory as NSString).appendingPathComponent(socketName(host: host, user: user, port: port))
    }

    public static func pathLengthValid(_ path: String) -> Bool {
        path.utf8.count <= maxPathBytes
    }

    public static func pathContainsPercent(_ path: String) -> Bool {
        path.contains("%")
    }
}

public final class RemoteSession: @unchecked Sendable {
    public let controlPath: String
    private let lock = NSLock()
    private var didIssueFirstCommand = false
    private var muxDisabled = false

    public init(controlPath: String) {
        self.controlPath = controlPath
    }

    public var issuedFirstCommand: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didIssueFirstCommand
    }

    public var disabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return muxDisabled
    }

    @discardableResult
    func claimFirstCommand() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didIssueFirstCommand { return false }
        didIssueFirstCommand = true
        return true
    }

    func disable() {
        lock.lock()
        muxDisabled = true
        lock.unlock()
    }
}
