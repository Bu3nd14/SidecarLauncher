import XCTest
@testable import SidecarSwitchCore

final class SettingsStoreTests: XCTestCase {
    private func permissions(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    private var personalMarkers: [String] {
        ["ro" + "berto", "Q5" + "19411", "ssh." + "rob" + "etta.uk", "LMAC" + "GW3HW149"]
    }

    private func assertNoPersonalMarkers(_ text: String, checkUsersPath: Bool = true,
                                         file: StaticString = #filePath, line: UInt = #line) {
        for marker in personalMarkers {
            XCTAssertFalse(text.contains(marker), "dato personale \(marker)", file: file, line: line)
        }
        if checkUsersPath {
            XCTAssertFalse(text.contains("/Users/"), file: file, line: line)
        }
    }

    private func validSettings() -> Settings {
        var settings = Settings.default
        settings.remote.host = "personale.local"
        settings.remote.user = "utente"
        settings.remote.binaryPath = "/Users/utente/SidecarLauncher/tools/bin/SidecarLauncher"
        settings.remote.connectedPath = "/Users/utente/SidecarLauncher/tools/bin/connected"
        settings.remote.dispidPath = "/Users/utente/SidecarLauncher/tools/bin/dispid"
        settings.remote.mirrorPath = "/Users/utente/SidecarLauncher/tools/bin/mirror"
        settings.remote.arrangePath = "/Users/utente/SidecarLauncher/tools/bin/arrange"
        return settings
    }

    func testK31FirstLaunchWritesGenericDefaults() throws {
        let directory = try makeTempDirectory("settings-default")
        let home = try makeTempDirectory("settings-home")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: home)
        }
        let store = SettingsStore(directory: directory, home: home)

        let loaded = store.load()
        XCTAssertTrue(loaded.created)
        XCTAssertFalse(loaded.corrupt)
        XCTAssertNil(loaded.warning)
        XCTAssertEqual(loaded.settings.schemaVersion, 2)
        XCTAssertEqual(loaded.settings.device.name, "iPad")
        XCTAssertEqual(loaded.settings.remote.host, "")
        XCTAssertEqual(loaded.settings.remote.user, "")
        XCTAssertEqual(loaded.settings.remote.port, 22)
        XCTAssertEqual(loaded.settings.remote.identityFile, "~/.ssh/id_ed25519_sidecar_switch")
        XCTAssertEqual(loaded.settings.remote.binaryPath, "")
        XCTAssertEqual(loaded.settings.remote.connectedPath, "")
        XCTAssertEqual(loaded.settings.remote.dispidPath, "")
        XCTAssertEqual(loaded.settings.remote.mirrorPath, "")
        XCTAssertEqual(loaded.settings.remote.arrangePath, "")
        XCTAssertEqual(loaded.settings.lastLocation, .unknown)
        XCTAssertEqual(loaded.settings.needsReconcile, false)
        XCTAssertEqual(loaded.settings.hotkey.keyCode, 1)
        XCTAssertEqual(loaded.settings.hotkey.modifiers, ["control", "option", "command"])
        XCTAssertEqual(loaded.settings.ssh.connectTimeout, 15)
        XCTAssertEqual(loaded.settings.ssh.strictHostKeyChecking, "accept-new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.configURL.path))
        XCTAssertEqual(permissions(store.configURL.path) & 0o777, 0o600)
        XCTAssertEqual(permissions(directory.path) & 0o777, 0o700)

        let text = try String(contentsOf: store.configURL, encoding: .utf8)
        assertNoPersonalMarkers(text)
    }

    func testRoundTripAndPermissions() throws {
        let directory = try makeTempDirectory("settings-roundtrip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)

        var settings = validSettings()
        settings.device.name = "iPad Pro"
        settings.remote.port = 2222
        settings.ssh.strictHostKeyChecking = "yes"
        settings.lastLocation = .personale
        settings.needsReconcile = true

        try store.save(settings)
        XCTAssertEqual(permissions(directory.path) & 0o777, 0o700)
        XCTAssertEqual(permissions(store.configURL.path) & 0o777, 0o600)

        let loaded = store.load()
        XCTAssertFalse(loaded.corrupt)
        XCTAssertEqual(loaded.settings, settings)
    }

    func testBackupBeforeRewrite() throws {
        let directory = try makeTempDirectory("settings-backup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)

        var first = validSettings()
        first.device.name = "iPad"
        try store.save(first)

        let firstData = try Data(contentsOf: store.configURL)

        var second = first
        second.device.name = "iPad 2"
        try store.save(second)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.backupURL.path))
        XCTAssertEqual(try Data(contentsOf: store.backupURL), firstData)
        XCTAssertEqual(permissions(store.backupURL.path) & 0o777, 0o600)
    }

    func testCorruptFilePreservedAndDefaultsApplied() throws {
        let directory = try makeTempDirectory("settings-corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try store.ensureDirectory()
        let corrupt = Data("questo non è json".utf8)
        try corrupt.write(to: store.configURL)

        let loaded = store.load()
        XCTAssertTrue(loaded.corrupt)
        XCTAssertNotNil(loaded.warning)
        XCTAssertTrue(loaded.warning?.contains(store.configURL.path) ?? false)
        XCTAssertEqual(loaded.settings.lastLocation, .unknown)
        XCTAssertEqual(loaded.settings.needsReconcile, true)
        XCTAssertEqual(try Data(contentsOf: store.configURL), corrupt, "il file corrotto non deve essere riscritto")
    }

    func testK34InvalidJSONIsPreservedByteForByte() throws {
        let directory = try makeTempDirectory("settings-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try store.ensureDirectory()
        let invalid = Data("{ \"schemaVersion\": 2, \"remote\": ".utf8)
        try invalid.write(to: store.configURL)

        let loaded = store.load()
        XCTAssertTrue(loaded.corrupt)
        XCTAssertEqual(loaded.settings, Settings(lastLocation: .unknown, needsReconcile: true))
        XCTAssertEqual(try Data(contentsOf: store.configURL), invalid)
    }

    func testCorruptFileBecomesBackupOnExplicitSave() throws {
        let directory = try makeTempDirectory("settings-corrupt-save")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try store.ensureDirectory()
        let corrupt = Data("{ rotto".utf8)
        try corrupt.write(to: store.configURL)

        _ = store.load()
        try store.save(validSettings())

        XCTAssertEqual(try Data(contentsOf: store.backupURL), corrupt)
        XCTAssertFalse(store.load().corrupt)
    }

    func testUnknownSchemaIsCorrupt() throws {
        let directory = try makeTempDirectory("settings-schema")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try store.ensureDirectory()
        var settings = Settings.default
        settings.schemaVersion = 1
        let encoder = JSONEncoder()
        try encoder.encode(settings).write(to: store.configURL)

        let loaded = store.load()
        XCTAssertTrue(loaded.corrupt)
        XCTAssertEqual(loaded.settings.lastLocation, .unknown)
    }

    func testAtomicWriteLeavesNoTemporaryFiles() throws {
        let directory = try makeTempDirectory("settings-atomic")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try store.save(validSettings())
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(entries, ["config.json"])
    }

    func testValidationRejectsEmptyDeviceAndBadModifiers() {
        var settings = validSettings()
        settings.device.name = ""
        XCTAssertThrowsError(try settings.validate())
        var modifiers = validSettings()
        modifiers.hotkey.modifiers = ["hyper"]
        XCTAssertThrowsError(try modifiers.validate())
    }

    func testValidationRejectsRelativeIdentity() {
        var settings = validSettings()
        settings.remote.identityFile = "id_ed25519"
        XCTAssertThrowsError(try settings.validate())
    }

    func testEmptyIdentityIsBlocking() {
        var settings = validSettings()
        settings.remote.identityFile = ""
        XCTAssertThrowsError(try settings.validate())
    }

    func testK32TildeIdentityExpandsLocallyButIsNotRewritten() throws {
        let home = URL(fileURLWithPath: "/Users/test")
        var settings = validSettings()
        settings.remote.identityFile = "~/.ssh/id_ed25519_sidecar_switch"
        XCTAssertEqual(settings.expandedIdentityFile(home: home),
                       "/Users/test/.ssh/id_ed25519_sidecar_switch")
        XCTAssertEqual(settings.remote.identityFile, "~/.ssh/id_ed25519_sidecar_switch")
        XCTAssertNoThrow(try settings.validate(home: home))

        settings.remote.identityFile = "~other/.ssh/key"
        XCTAssertEqual(settings.expandedIdentityFile(home: home), "~other/.ssh/key")
        XCTAssertThrowsError(try settings.validate(home: home))
    }

    func testRemoteTildePathIsRejectedAndAbsoluteIsAccepted() {
        var settings = validSettings()
        settings.remote.binaryPath = "~/bin/SidecarLauncher"
        XCTAssertThrowsError(try settings.validate())

        settings.remote.binaryPath = "/Users/utente/bin/SidecarLauncher"
        XCTAssertNoThrow(try settings.validate())

        settings.remote.binaryPath = ""
        XCTAssertNoThrow(try settings.validate(), "path vuoto = warning, non errore")
    }

    func testK33GateUsesHostAndFourPaths() {
        var settings = validSettings()
        XCTAssertFalse(settings.personaleGateDisabled)

        settings.remote.mirrorPath = ""
        XCTAssertFalse(settings.personaleGateDisabled, "mirrorPath è opzionale/ignorato")

        settings.remote.arrangePath = ""
        XCTAssertTrue(settings.personaleGateDisabled)

        var emptyHost = validSettings()
        emptyHost.remote.host = ""
        XCTAssertTrue(emptyHost.personaleGateDisabled)
    }

    func testValidationWarningsAreNonBlocking() {
        var settings = Settings.default
        XCTAssertNoThrow(try settings.validate())
        let warnings = settings.validationWarnings()
        XCTAssertTrue(warnings.contains { $0.contains("remote.host vuoto") })
        XCTAssertFalse(warnings.isEmpty)

        settings.remote.user = ""
        XCTAssertNoThrow(try settings.validate())
    }

    func testK35ReloadReadsNewValues() throws {
        let directory = try makeTempDirectory("settings-reload")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try store.save(validSettings())

        var updated = validSettings()
        updated.remote.host = "altro.local"
        updated.hotkey.keyCode = 2
        try store.save(updated)

        let loaded = store.load()
        XCTAssertFalse(loaded.corrupt)
        XCTAssertEqual(loaded.settings.remote.host, "altro.local")
        XCTAssertEqual(loaded.settings.hotkey.keyCode, 2)
    }

    func testConfigExampleIsDecodableAndValid() throws {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = appDirectory.appendingPathComponent("config.example.json")
        let data = try Data(contentsOf: url)
        let settings = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertNoThrow(try settings.validate(home: URL(fileURLWithPath: "/Users/utente")))
        XCTAssertEqual(settings.schemaVersion, 2)
        XCTAssertEqual(settings.ssh.connectTimeout, 15)
        XCTAssertFalse(settings.personaleGateDisabled)
        let text = String(decoding: data, as: UTF8.self)
        assertNoPersonalMarkers(text, checkUsersPath: false)
    }

    func testLoggerWritesRotatesAndSetsPermissions() throws {
        let directory = try makeTempDirectory("logger")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sidecar-switch.log")
        let logger = SwitchLogger(fileURL: file, maxBytes: 120)

        for index in 0..<10 {
            logger.log(.info, "riga \(index) con un po' di testo")
        }

        XCTAssertEqual(permissions(file.path) & 0o777, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("1").path))
        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(content.contains("[INFO]"))
        XCTAssertTrue(content.contains("riga"))
    }
}
