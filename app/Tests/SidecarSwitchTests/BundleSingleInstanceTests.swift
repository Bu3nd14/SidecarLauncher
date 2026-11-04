import XCTest
@testable import SidecarSwitchCore

final class BundleBootstrapTests: XCTestCase {
    private func makeResources(contents: [String: String]? = nil) throws -> URL {
        let resources = try makeTempDirectory("bundle-resources")
        let body = contents ?? Dictionary(uniqueKeysWithValues: BundleBootstrap.toolNames.map { ($0, "#!/bin/sh\necho \($0)\n") })
        for (name, content) in body {
            let url = resources.appendingPathComponent(name)
            try Data(content.utf8).write(to: url)
            chmod(url.path, 0o755)
        }
        return resources
    }

    private func permissions(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    func testFirstSyncInstallsToolsAndVersion() throws {
        let resources = try makeResources()
        let support = try makeTempDirectory("bundle-support")
        defer {
            try? FileManager.default.removeItem(at: resources)
            try? FileManager.default.removeItem(at: support)
        }

        let bootstrap = BundleBootstrap(resourcesDirectory: resources,
                                        supportDirectory: support,
                                        toolsVersion: "abc123")
        try bootstrap.synchronize()

        for name in BundleBootstrap.toolNames {
            let tool = bootstrap.toolsDirectory.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: tool.path))
            XCTAssertEqual(permissions(tool.path) & 0o777, 0o755)
        }
        XCTAssertEqual(permissions(bootstrap.toolsDirectory.path) & 0o777, 0o700)
        XCTAssertEqual(try String(contentsOf: bootstrap.toolsDirectory.appendingPathComponent("VERSION"), encoding: .utf8),
                       "abc123\n")
        XCTAssertEqual(try String(contentsOf: support.appendingPathComponent("VERSION"), encoding: .utf8),
                       "abc123\n")
    }

    func testSecondSyncWithSameVersionIsSkipped() throws {
        let resources = try makeResources()
        let support = try makeTempDirectory("bundle-skip")
        defer {
            try? FileManager.default.removeItem(at: resources)
            try? FileManager.default.removeItem(at: support)
        }
        let bootstrap = BundleBootstrap(resourcesDirectory: resources, supportDirectory: support, toolsVersion: "v1")
        try bootstrap.synchronize()

        let connected = bootstrap.toolsDirectory.appendingPathComponent("connected")
        try Data("modificato-a-mano".utf8).write(to: connected)

        try bootstrap.synchronize()
        XCTAssertEqual(try String(contentsOf: connected, encoding: .utf8), "modificato-a-mano")
    }

    func testVersionChangeSwapsDirectory() throws {
        let resources = try makeResources()
        let support = try makeTempDirectory("bundle-swap")
        defer {
            try? FileManager.default.removeItem(at: resources)
            try? FileManager.default.removeItem(at: support)
        }
        let first = BundleBootstrap(resourcesDirectory: resources, supportDirectory: support, toolsVersion: "v1")
        try first.synchronize()

        let connected = first.toolsDirectory.appendingPathComponent("connected")
        try Data("vecchio".utf8).write(to: connected)

        let second = BundleBootstrap(resourcesDirectory: resources, supportDirectory: support, toolsVersion: "v2")
        try second.synchronize()

        XCTAssertNotEqual(try String(contentsOf: connected, encoding: .utf8), "vecchio")
        XCTAssertEqual(try String(contentsOf: first.toolsDirectory.appendingPathComponent("VERSION"), encoding: .utf8),
                       "v2\n")
        let entries = try FileManager.default.contentsOfDirectory(atPath: support.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".tools.old-") })
        XCTAssertFalse(entries.contains { $0.hasPrefix(".tools.new-") })
    }

    func testMissingToolThrowsAndLeavesNoStaging() throws {
        let resources = try makeResources()
        try FileManager.default.removeItem(at: resources.appendingPathComponent("arrange"))
        let support = try makeTempDirectory("bundle-missing")
        defer {
            try? FileManager.default.removeItem(at: resources)
            try? FileManager.default.removeItem(at: support)
        }
        let bootstrap = BundleBootstrap(resourcesDirectory: resources, supportDirectory: support, toolsVersion: "v1")

        XCTAssertThrowsError(try bootstrap.synchronize())
        XCTAssertFalse(FileManager.default.fileExists(atPath: bootstrap.toolsDirectory.path))
        let entries = try FileManager.default.contentsOfDirectory(atPath: support.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".tools.new-") })
    }

    func testQuarantineRemovedFromCopiedTools() throws {
        let resources = try makeResources()
        let support = try makeTempDirectory("bundle-quarantine")
        defer {
            try? FileManager.default.removeItem(at: resources)
            try? FileManager.default.removeItem(at: support)
        }
        let source = resources.appendingPathComponent("SidecarLauncher")
        let attribute = "com.apple.quarantine"
        let value = Data("0081".utf8)
        let setResult = value.withUnsafeBytes { raw in
            setxattr(source.path, attribute, raw.baseAddress, raw.count, 0, 0)
        }
        XCTAssertEqual(setResult, 0, "setxattr sul file di test")

        let bootstrap = BundleBootstrap(resourcesDirectory: resources, supportDirectory: support, toolsVersion: "v1")
        try bootstrap.synchronize()

        let installed = bootstrap.toolsDirectory.appendingPathComponent("SidecarLauncher")
        let size = getxattr(installed.path, attribute, nil, 0, 0, 0)
        XCTAssertLessThan(size, 0, "la quarantena deve essere rimossa (getxattr=\(size))")
    }

    func testEmptyVersionRejected() throws {
        let resources = try makeResources()
        let support = try makeTempDirectory("bundle-empty")
        defer {
            try? FileManager.default.removeItem(at: resources)
            try? FileManager.default.removeItem(at: support)
        }
        let bootstrap = BundleBootstrap(resourcesDirectory: resources, supportDirectory: support, toolsVersion: "  ")
        XCTAssertThrowsError(try bootstrap.synchronize())
    }
}

final class SingleInstanceTests: XCTestCase {
    func testSecondInstanceIsRejectedAndFirstReacquires() throws {
        let directory = try makeTempDirectory("instance")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SingleInstance(directory: directory)
        XCTAssertEqual(first.acquire(), .acquired)

        let second = SingleInstance(directory: directory)
        XCTAssertEqual(second.acquire(), .alreadyRunning(pid: getpid()))

        let content = try String(contentsOfFile: first.lockPath, encoding: .utf8)
        XCTAssertEqual(Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)), getpid())

        first.release()
        XCTAssertEqual(second.acquire(), .acquired)
        second.release()
    }

    func testLockFilePermissions() throws {
        let directory = try makeTempDirectory("instance-perms")
        defer { try? FileManager.default.removeItem(at: directory) }
        let instance = SingleInstance(directory: directory)
        XCTAssertEqual(instance.acquire(), .acquired)
        defer { instance.release() }

        let attributes = try FileManager.default.attributesOfItem(atPath: instance.lockPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600)
    }
}
