import Foundation

public struct OperationsCacheKey: Equatable, Sendable {
    public var deviceName: String
    public var remote: RemoteSettings
    public var ssh: SSHSettings
    public var toolsVersion: String
    public var local: LocalToolPaths

    public init(settings: Settings, toolsVersion: String, local: LocalToolPaths) {
        self.deviceName = settings.device.name
        self.remote = settings.remote
        self.ssh = settings.ssh
        self.toolsVersion = toolsVersion
        self.local = local
    }
}
