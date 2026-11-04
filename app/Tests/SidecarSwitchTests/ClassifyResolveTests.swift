import XCTest
@testable import SidecarSwitchCore

final class ClassifyResolveTests: XCTestCase {
    func testClassifyConnectedMatchingDevice() {
        XCTAssertEqual(Classifier.classify(.connected(devices: ["iPad"]), configuredName: "iPad"), .connectediPad)
        XCTAssertEqual(Classifier.classify(.connected(devices: ["ipad"]), configuredName: "iPad"), .connectediPad)
        XCTAssertEqual(Classifier.classify(.connected(devices: ["iPad "]), configuredName: " iPad"), .connectediPad)
    }

    func testClassifyForeignDevice() {
        XCTAssertEqual(Classifier.classify(.connected(devices: ["MacBook Pro"]), configuredName: "iPad"), .foreignDevice)
    }

    func testClassifyTooMany() {
        XCTAssertEqual(Classifier.classify(.connected(devices: ["iPad", "iPad 2"]), configuredName: "iPad"), .tooMany)
    }

    func testClassifyEmptyConnectedIsUnknown() {
        XCTAssertEqual(Classifier.classify(.connected(devices: []), configuredName: "iPad"), .unknown)
    }

    func testClassifySimpleStates() {
        XCTAssertEqual(Classifier.classify(.disconnected, configuredName: "iPad"), .disconnected)
        XCTAssertEqual(Classifier.classify(.unknown, configuredName: "iPad"), .unknown)
        XCTAssertEqual(Classifier.classify(.unreachable, configuredName: "iPad"), .unreachable)
    }

    func testResolveTotalTable() {
        let table: [(ClassifiedProbe, ClassifiedProbe, Resolution)] = [
            (.connectediPad, .connectediPad, .incoherent),
            (.connectediPad, .disconnected, .location(.lavoro)),
            (.connectediPad, .unknown, .location(.lavoro)),
            (.connectediPad, .unreachable, .location(.lavoro)),
            (.disconnected, .connectediPad, .location(.personale)),
            (.disconnected, .disconnected, .location(.nowhere)),
            (.disconnected, .unknown, .location(.unknown)),
            (.disconnected, .unreachable, .location(.unknown)),
            (.unknown, .connectediPad, .location(.unknown)),
            (.unknown, .disconnected, .location(.unknown)),
            (.unknown, .unknown, .location(.unknown)),
            (.unknown, .unreachable, .location(.unknown))
        ]
        for row in table {
            XCTAssertEqual(Classifier.resolve(local: row.0, remote: row.1), row.2,
                           "resolve \(row.0)/\(row.1)")
        }
    }

    func testResolveIsTotalForAllPairs() {
        let states: [ClassifiedProbe] = [.connectediPad, .foreignDevice, .tooMany, .disconnected, .unknown, .unreachable]
        for local in states {
            for remote in states {
                let resolution = Classifier.resolve(local: local, remote: remote)
                if local == .foreignDevice || remote == .foreignDevice || local == .tooMany || remote == .tooMany {
                    XCTAssertEqual(resolution, .incoherent, "\(local)/\(remote)")
                } else if local == .unreachable {
                    XCTAssertEqual(resolution, .location(.unknown), "\(local)/\(remote)")
                }
            }
        }
    }

    func testResolveIncoherentWhenBothConnected() {
        XCTAssertEqual(Classifier.resolve(local: .connectediPad, remote: .connectediPad), .incoherent)
    }

    func testDecisionTable() {
        XCTAssertEqual(Classifier.decide(actual: .lavoro, target: .lavoro), .noop(.lavoro))
        XCTAssertEqual(Classifier.decide(actual: .personale, target: .personale), .noop(.personale))
        XCTAssertEqual(Classifier.decide(actual: .nowhere, target: .lavoro), .connectOnly(target: .lavoro))
        XCTAssertEqual(Classifier.decide(actual: .nowhere, target: .personale), .connectOnly(target: .personale))
        XCTAssertEqual(Classifier.decide(actual: .lavoro, target: .personale),
                       .disconnectThenConnect(source: .lavoro, target: .personale))
        XCTAssertEqual(Classifier.decide(actual: .personale, target: .lavoro),
                       .disconnectThenConnect(source: .personale, target: .lavoro))
        XCTAssertEqual(Classifier.decide(actual: .unknown, target: .lavoro), .abort(.unknownHolder))
        XCTAssertEqual(Classifier.decide(actual: .unknown, target: .personale), .abort(.unknownHolder))
    }

    func testDecisionTableIsTotal() {
        for actual in Location.allCases {
            for target in SwitchHost.allCases {
                let expected: Action
                switch (actual, target) {
                case (.lavoro, .lavoro): expected = .noop(.lavoro)
                case (.personale, .personale): expected = .noop(.personale)
                case (.lavoro, .personale): expected = .disconnectThenConnect(source: .lavoro, target: .personale)
                case (.personale, .lavoro): expected = .disconnectThenConnect(source: .personale, target: .lavoro)
                case (.nowhere, .lavoro): expected = .connectOnly(target: .lavoro)
                case (.nowhere, .personale): expected = .connectOnly(target: .personale)
                case (.unknown, _): expected = .abort(.unknownHolder)
                }
                XCTAssertEqual(Classifier.decide(actual: actual, target: target), expected,
                               "decide \(actual)/\(target)")
            }
        }
    }

    func testHotkeyDirection() {
        XCTAssertEqual(HotkeyDirection.target(actual: .lavoro, lastLocation: .personale), .personale)
        XCTAssertEqual(HotkeyDirection.target(actual: .personale, lastLocation: .lavoro), .lavoro)
        XCTAssertEqual(HotkeyDirection.target(actual: .nowhere, lastLocation: .lavoro), .personale)
        XCTAssertEqual(HotkeyDirection.target(actual: .nowhere, lastLocation: .personale), .lavoro)
        XCTAssertNil(HotkeyDirection.target(actual: .nowhere, lastLocation: .unknown))
        XCTAssertNil(HotkeyDirection.target(actual: .nowhere, lastLocation: .nowhere))
        XCTAssertNil(HotkeyDirection.target(actual: .unknown, lastLocation: .lavoro))
        XCTAssertNil(HotkeyDirection.target(actual: .unknown, lastLocation: .personale))
        XCTAssertEqual(HotkeyDirection.target(actual: .nowhere, lastLocation: .unknown,
                                              personaleDisabled: true), .lavoro)
        XCTAssertEqual(HotkeyDirection.target(actual: .nowhere, lastLocation: .personale,
                                              personaleDisabled: true), .lavoro)
    }

    func testStartupPlanUpdatesStaleLastLocation() {
        let plan = StartupPlanner.plan(local: .connected(devices: ["iPad"]), remote: .disconnected,
                                       configuredName: "iPad", lastLocation: .personale,
                                       needsReconcile: true)
        XCTAssertEqual(plan.actual, .lavoro)
        XCTAssertEqual(plan.persistence.lastLocation, .set(.lavoro))
        XCTAssertEqual(plan.persistence.needsReconcile, false)
        XCTAssertTrue(plan.switchEnabled)
        XCTAssertNotNil(plan.banner)
    }

    func testStartupPlanClearsReconcileWhenConfirmed() {
        let plan = StartupPlanner.plan(local: .connected(devices: ["iPad"]), remote: .disconnected,
                                       configuredName: "iPad", lastLocation: .lavoro,
                                       needsReconcile: true)
        XCTAssertEqual(plan.persistence.lastLocation, .unchanged)
        XCTAssertEqual(plan.persistence.needsReconcile, false)
        XCTAssertNil(plan.banner)
    }

    func testStartupPlanUnknownKeepsLastLocation() {
        let plan = StartupPlanner.plan(local: .unknown, remote: .disconnected,
                                       configuredName: "iPad", lastLocation: .lavoro,
                                       needsReconcile: false)
        XCTAssertEqual(plan.actual, .unknown)
        XCTAssertEqual(plan.persistence, .unchanged)
        XCTAssertFalse(plan.switchEnabled)
    }

    func testStartupPlanForeignDevice() {
        let plan = StartupPlanner.plan(local: .connected(devices: ["MacBook"]), remote: .disconnected,
                                       configuredName: "iPad", lastLocation: .lavoro,
                                       needsReconcile: false)
        XCTAssertEqual(plan.actual, .unknown)
        XCTAssertFalse(plan.switchEnabled)
        XCTAssertEqual(plan.banner, Reason.foreignDevice.displayMessage)
    }
}
