import XCTest
@testable import SidecarSwitchCore

final class ReopenDecisionTests: XCTestCase {
    func testVisibleWindowsNoop() {
        XCTAssertEqual(ReopenDecision.plan(hasVisibleWindows: true, hasMainCapableWindow: true), .noop)
        XCTAssertEqual(ReopenDecision.plan(hasVisibleWindows: true, hasMainCapableWindow: false), .noop)
    }

    func testHiddenMainCapableWindowShowsExisting() {
        XCTAssertEqual(ReopenDecision.plan(hasVisibleWindows: false, hasMainCapableWindow: true), .showExisting)
    }

    func testHiddenWithoutMainCapableWindowDefersToSystem() {
        XCTAssertEqual(ReopenDecision.plan(hasVisibleWindows: false, hasMainCapableWindow: false), .systemDefault)
    }
}
