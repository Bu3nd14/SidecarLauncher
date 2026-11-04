import AppKit
import XCTest
@testable import SidecarSwitch
@testable import SidecarSwitchCore

final class DockIconPlannerTests: XCTestCase {
    func testK66PlannerMatrix() {
        XCTAssertEqual(DockIconPlanner.plan(isTransitioning: true, switchingAssetAvailable: true), .switching)
        XCTAssertEqual(DockIconPlanner.plan(isTransitioning: false, switchingAssetAvailable: true), .normal)
        XCTAssertEqual(DockIconPlanner.plan(isTransitioning: true, switchingAssetAvailable: false), .normal)
        XCTAssertEqual(DockIconPlanner.plan(isTransitioning: false, switchingAssetAvailable: false), .normal)
    }
}

@MainActor
final class DockIconControllerTests: XCTestCase {
    func testK68ControllerAppliesSwitchingThenNormalAndFallsBack() {
        let normal = NSImage(size: NSSize(width: 16, height: 16))
        let switching = NSImage(size: NSSize(width: 16, height: 16))
        var applied: [NSImage] = []
        let controller = DockIconController(normalImage: normal, switchingImage: switching) { image in
            if let image { applied.append(image) }
        }

        controller.apply(isTransitioning: true)
        XCTAssertTrue(applied.last === switching)
        controller.apply(isTransitioning: false)
        XCTAssertTrue(applied.last === normal)

        var fallbackApplied: [NSImage] = []
        let fallback = DockIconController(normalImage: normal, switchingImage: nil) { image in
            if let image { fallbackApplied.append(image) }
        }
        fallback.apply(isTransitioning: true)
        XCTAssertTrue(fallbackApplied.last === normal)
    }

    func testK68AppModelHookSwitchesAndResets() async throws {
        let home = try makeTempDirectory("dock-icon-model")
        defer { try? FileManager.default.removeItem(at: home) }
        let ops = RecordingOperations()
        ops.setProbes(.lavoro, [Fixtures.disconnected(), Fixtures.disconnected(), Fixtures.disconnected()])
        ops.setDisplays(.lavoro, [Fixtures.displaysOK([Fixtures.builtin])])
        let normal = NSImage(size: NSSize(width: 16, height: 16))
        let switching = NSImage(size: NSSize(width: 16, height: 16))
        var applied: [NSImage] = []
        let controller = DockIconController(normalImage: normal, switchingImage: switching) { image in
            if let image { applied.append(image) }
        }
        let model = AppModel(paths: AppPaths(home: home),
                             logURL: home.appendingPathComponent("log.txt"),
                             resourcesDirectory: nil,
                             bundledToolsVersion: "test",
                             operationsFactory: { _ in ops },
                             timings: .fast,
                             dockIconController: controller)

        model.handle(TransitionOutcome(state: .done(.lavoro), persistence: .success(.lavoro), actual: .lavoro))
        XCTAssertTrue(applied.last === normal)

        model.toggle(.lavoro)
        XCTAssertTrue(applied.last === switching)

        var spins = 0
        while model.isTransitioning && spins < 20000 {
            spins += 1
            await Task.yield()
        }
        XCTAssertFalse(model.isTransitioning)
        XCTAssertTrue(applied.last === normal)
    }
}
