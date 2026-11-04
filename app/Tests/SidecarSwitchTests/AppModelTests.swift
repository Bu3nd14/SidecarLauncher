import XCTest
@testable import SidecarSwitch
@testable import SidecarSwitchCore

@MainActor
final class AppModelTests: XCTestCase {
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

    private func makeModel(home: URL, ops: (any SidecarOperations)? = nil,
                           opener: OpenURL? = nil) -> AppModel {
        AppModel(
            paths: AppPaths(home: home),
            logURL: home.appendingPathComponent("sidecar-switch.log"),
            resourcesDirectory: nil,
            bundledToolsVersion: "test",
            opener: opener,
            operationsFactory: ops.map { operations in { _ in operations } },
            timings: .fast
        )
    }

    func testK50AppModelHandleSetsUnknownForIncoherentAndUnknownHolder() throws {
        let home = try makeTempDirectory("appmodel-incoherent")
        defer { try? FileManager.default.removeItem(at: home) }
        let model = makeModel(home: home)

        model.handle(TransitionOutcome(state: .done(.lavoro), persistence: .success(.lavoro), actual: .lavoro))
        XCTAssertEqual(model.actual, .lavoro)

        model.handle(TransitionOutcome(state: .failed(nil, .incoherent),
                                       persistence: PersistencePlan(needsReconcile: true), actual: nil))
        XCTAssertEqual(model.actual, .unknown)
        XCTAssertTrue(model.needsReconcile)
        let dock = DockMenuPlanner.plan(actual: model.actual, lastLocation: model.settings.lastLocation,
                                        isTransitioning: model.isTransitioning,
                                        personaleGateDisabled: model.personaleGateDisabled)
        XCTAssertFalse(dock.lavoroEnabled)
        XCTAssertFalse(dock.personaleEnabled)

        model.handle(TransitionOutcome(state: .done(.personale), persistence: .success(.personale), actual: .personale))
        model.handle(TransitionOutcome(state: .failed(nil, .unknownHolder), persistence: .unchanged, actual: nil))
        XCTAssertEqual(model.actual, .unknown)
    }

    func testK33GatePersonaleIsRejectedWithoutAnyOperation() throws {
        let home = try makeTempDirectory("appmodel-gate")
        defer { try? FileManager.default.removeItem(at: home) }
        let ops = RecordingOperations()
        let model = makeModel(home: home, ops: ops)

        XCTAssertTrue(model.personaleGateDisabled)
        model.toggle(.personale)
        XCTAssertFalse(model.isTransitioning)
        XCTAssertEqual(model.banner?.message, "Configura config.json")
        XCTAssertTrue(ops.operations.isEmpty, "zero ssh quando il gate è disabilitato")

        model.handle(TransitionOutcome(state: .done(.lavoro), persistence: .success(.lavoro), actual: .lavoro))
        model.handleHotkey()
        XCTAssertEqual(model.banner?.message, "Configura config.json")
        XCTAssertTrue(ops.operations.isEmpty, "la hotkey non deve fare ssh con config incompleta")
    }

    func testK33InitialProbeGateReplacesRemoteProbe() async throws {
        let home = try makeTempDirectory("appmodel-initial-gate")
        defer { try? FileManager.default.removeItem(at: home) }
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])
        let model = makeModel(home: home, ops: ops)

        await model.start()

        XCTAssertEqual(ops.operations, [.probe(.lavoro)])
        XCTAssertEqual(model.banner?.message, "Configura config.json")
        XCTAssertTrue(model.personaleGateDisabled)
        XCTAssertEqual(model.actual, .nowhere)
        let dock = DockMenuPlanner.plan(actual: model.actual, lastLocation: model.settings.lastLocation,
                                        isTransitioning: model.isTransitioning,
                                        personaleGateDisabled: model.personaleGateDisabled)
        XCTAssertTrue(dock.lavoroEnabled)
        XCTAssertFalse(dock.personaleEnabled)

        model.handleHotkey()
        XCTAssertTrue(model.isTransitioning)
        var spins = 0
        while model.isTransitioning && spins < 20000 {
            spins += 1
            await Task.yield()
        }
        XCTAssertFalse(ops.operations.contains { $0.description.contains("(personale") })
        XCTAssertTrue(ops.operations.contains(.connect(.lavoro, "iPad")))
    }

    func testK35ReloadReregistersHotkey() throws {
        let home = try makeTempDirectory("appmodel-hotkey")
        defer { try? FileManager.default.removeItem(at: home) }
        let model = makeModel(home: home)
        let store = SettingsStore(directory: model.supportDirectory, home: home)

        try store.save(validSettings())
        XCTAssertTrue(model.reloadConfig())
        let logURL = home.appendingPathComponent("sidecar-switch.log")
        let first = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(first.components(separatedBy: "ri-registrazione hotkey").count - 1, 1)

        try store.save(validSettings())
        XCTAssertTrue(model.reloadConfig())
        let second = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(second.components(separatedBy: "ri-registrazione hotkey").count - 1, 2)
    }

    func testK36OpenConfigUsesInjectedOpener() throws {
        let home = try makeTempDirectory("appmodel-opener")
        defer { try? FileManager.default.removeItem(at: home) }
        var opened: URL?
        let model = makeModel(home: home, opener: { url in
            opened = url
            return true
        })

        model.openConfig()
        XCTAssertEqual(opened, model.configURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.configURL.path))
    }

    func testK35ReloadAppliesValidConfigAndPreservesInvalidFile() throws {
        let home = try makeTempDirectory("appmodel-reload")
        defer { try? FileManager.default.removeItem(at: home) }
        let model = makeModel(home: home)
        let store = SettingsStore(directory: model.supportDirectory, home: home)

        try store.save(validSettings())
        XCTAssertTrue(model.reloadConfig())
        XCTAssertEqual(model.settings.remote.host, "personale.local")
        XCTAssertFalse(model.personaleGateDisabled)

        let invalid = Data("{ non valido".utf8)
        try invalid.write(to: model.configURL)
        XCTAssertFalse(model.reloadConfig())
        XCTAssertEqual(model.settings.remote.host, "personale.local")
        XCTAssertEqual(try Data(contentsOf: model.configURL), invalid)
        XCTAssertTrue(model.banner?.message.contains(model.configURL.path) ?? false)
    }

    func testK44UIHintForUnrecognizedTransportFailure() throws {
        let home = try makeTempDirectory("appmodel-hint")
        defer { try? FileManager.default.removeItem(at: home) }
        let model = makeModel(home: home)
        model.handle(TransitionOutcome(state: .failed(.lavoro, .targetUnreachable),
                                       persistence: .unchanged, actual: .lavoro))
        XCTAssertTrue(model.banner?.message.contains("config SSH o proxy/CA non applicati? controlla VPN/rete") ?? false)
    }

    func testK38DockMenuHasTwoEntriesAndUsesModelToggle() throws {
        let home = try makeTempDirectory("appmodel-dock")
        defer { try? FileManager.default.removeItem(at: home) }
        let model = makeModel(home: home)
        model.handle(TransitionOutcome(state: .failed(.nowhere, .targetFailed),
                                       persistence: PersistencePlan(lastLocation: .set(.nowhere)),
                                       actual: .nowhere))
        let delegate = AppDelegate(model: model)
        let menu = delegate.makeDockMenu()

        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items.count, 2)
        XCTAssertEqual(menu.items.map(\.title), ["Passa a Lavoro", "Passa a Personale"])
        XCTAssertTrue(menu.items[0].isEnabled)
        XCTAssertFalse(menu.items[1].isEnabled)
        XCTAssertEqual(menu.items[0].state, .off)
        XCTAssertEqual(menu.items[1].state, .off)

        delegate.dockSwitch(menu.items[1])
        XCTAssertEqual(model.banner?.message, "Configura config.json")
        XCTAssertFalse(model.isTransitioning)
    }

    func testK35ReloadRejectedDuringTransitionWithoutDeferredApply() async throws {
        let home = try makeTempDirectory("appmodel-reload-busy")
        defer { try? FileManager.default.removeItem(at: home) }
        let ops = BlockingOperations()
        let model = makeModel(home: home, ops: ops)
        model.handle(TransitionOutcome(state: .done(.lavoro), persistence: .success(.lavoro), actual: .lavoro))

        model.toggle(.lavoro)
        XCTAssertTrue(model.isTransitioning)
        XCTAssertFalse(model.reloadConfig())
        XCTAssertTrue(model.banner?.message.contains("transizione in corso") ?? false)

        ops.release()
        var spins = 0
        while model.isTransitioning && spins < 20000 {
            spins += 1
            await Task.yield()
        }
        XCTAssertFalse(model.isTransitioning)
    }
}


final class BlockingOperations: SidecarOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var probeCalls = 0
    private var releaseRequested = false

    func release() {
        lock.lock()
        releaseRequested = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    private func shouldBlock() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        probeCalls += 1
        return probeCalls == 2
    }

    func probe(_ host: SidecarSwitchCore.Host, timeout: Duration) async -> ProbeReport {
        let block = shouldBlock()
        if block {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if releaseRequested {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
        return ProbeReport(state: .disconnected)
    }

    func devices(_ host: SidecarSwitchCore.Host, timeout: Duration) async -> DevicesReport {
        DevicesReport(status: .ok, names: ["iPad"], report: CommandReport(status: .ok))
    }

    func displays(_ host: SidecarSwitchCore.Host, timeout: Duration) async -> DisplaysReport {
        DisplaysReport(status: .ok, displays: [DisplayInfo(id: 1, vendor: 0x610, builtin: true, active: true)],
                       report: CommandReport(status: .ok))
    }

    func disconnect(_ host: SidecarSwitchCore.Host, device: String, timeout: Duration) async -> CommandOutcome {
        CommandOutcome(status: .ok, report: CommandReport(status: .ok))
    }

    func connect(_ host: SidecarSwitchCore.Host, device: String, timeout: Duration) async -> CommandOutcome {
        return CommandOutcome(status: .ok, report: CommandReport(status: .ok))
    }

    func harden(_ host: SidecarSwitchCore.Host, timeout: Duration) async -> HardenOutcome { .ok }
}
