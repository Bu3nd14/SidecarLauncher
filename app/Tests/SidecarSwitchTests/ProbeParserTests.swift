import XCTest
@testable import SidecarSwitchCore

final class ProbeParserTests: XCTestCase {
    func testConnectedParser() {
        let parsed = ConnectedParser.parse("connected=1\ndevice=iPad\n")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.devices, ["iPad"])
    }

    func testConnectedParserMultipleDevices() {
        let parsed = ConnectedParser.parse("connected=2\ndevice=iPad\ndevice=iPhone\n")
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.devices, ["iPad", "iPhone"])
    }

    func testConnectedParserNoOutput() {
        let parsed = ConnectedParser.parse("")
        XCTAssertNil(parsed.count)
        XCTAssertTrue(parsed.devices.isEmpty)
    }

    func testDeviceListParserTrimsEmptyLines() {
        XCTAssertEqual(DeviceListParser.parse("iPad\n\n  iPad 2  \n"), ["iPad", "iPad 2"])
    }

    func testDisplayParserRealLine() throws {
        let line = "id=3 vendor=0x6161706c model=0x69506164 serial=0 builtin=false main=false active=true mirror_of=0 asleep=false 1321x918"
        let displays = DisplayParser.parse(line)
        XCTAssertEqual(displays.count, 1)
        let display = try XCTUnwrap(displays.first)
        XCTAssertEqual(display.id, 3)
        XCTAssertEqual(display.vendor, 0x6161706c)
        XCTAssertEqual(display.model, 0x69506164)
        XCTAssertFalse(display.builtin)
        XCTAssertTrue(display.active)
        XCTAssertFalse(display.asleep)
        XCTAssertEqual(display.mirrors, 0)
        XCTAssertEqual(display.width, 1321)
        XCTAssertEqual(display.height, 918)
    }

    func testDisplayParserVirtualRow() throws {
        let line = "id=9 vendor=0x5644 model=0x1 serial=0 builtin=false main=true active=true mirror_of=0 asleep=false 1321x918"
        let display = try XCTUnwrap(DisplayParser.parse(line).first)
        XCTAssertEqual(display.vendor, 0x5644)
        XCTAssertTrue(display.main)
    }

    func testDisplayParserSkipsMalformedLines() {
        XCTAssertTrue(DisplayParser.parse("garbage\nid=x vendor=zz").isEmpty)
    }

    func testDisplayParserBuiltinTrue() throws {
        let line = "id=1 vendor=0x610 model=0x1 serial=0 builtin=true main=true active=true mirror_of=0 asleep=false 3024x1964"
        let display = try XCTUnwrap(DisplayParser.parse(line).first)
        XCTAssertTrue(display.builtin)
    }

    func testDisplayRuleLiveSidecar() {
        XCTAssertTrue(DisplayRule.isLiveSidecar(Fixtures.sidecarLive))
        XCTAssertTrue(DisplayRule.isLiveSidecar(Fixtures.sidecarMirrored))
        XCTAssertFalse(DisplayRule.isLiveSidecar(Fixtures.sidecarAsleep))
        XCTAssertFalse(DisplayRule.isLiveSidecar(DisplayInfo(id: 5, vendor: 0x6161706c, active: false)))
        XCTAssertFalse(DisplayRule.isLiveSidecar(Fixtures.virtual))
    }

    func testDisplayRuleHelpers() {
        XCTAssertTrue(DisplayRule.hasBuiltin([Fixtures.builtin, Fixtures.virtual]))
        XCTAssertFalse(DisplayRule.hasBuiltin([Fixtures.virtual]))
        XCTAssertTrue(DisplayRule.hasVirtual([Fixtures.builtin, Fixtures.virtual]))
        XCTAssertFalse(DisplayRule.hasVirtual([Fixtures.builtin]))
        XCTAssertTrue(DisplayRule.hasSidecar([Fixtures.sidecarLive]))
    }

    func testClassifyForeignAndTooManyFromProbeReport() {
        let foreign = ExitCodes.probeReport(host: .lavoro,
                                            result: .launched(exitCode: 0, stdout: "connected=1\ndevice=MacBook\n"))
        XCTAssertEqual(Classifier.classify(foreign.state, configuredName: "iPad"), .foreignDevice)
        let tooMany = ExitCodes.probeReport(host: .lavoro,
                                            result: .launched(exitCode: 0, stdout: "connected=2\ndevice=iPad\ndevice=iPad 2\n"))
        XCTAssertEqual(Classifier.classify(tooMany.state, configuredName: "iPad"), .tooMany)
    }

    func testTimeoutIsNotPrivateAPI() {
        let timeout = ExitCodes.probeReport(host: .lavoro, result: CommandResult(timedOut: true))
        let privateAPI = ExitCodes.probeReport(host: .lavoro, result: .launched(exitCode: 3))
        XCTAssertEqual(timeout.state, .unknown)
        XCTAssertEqual(privateAPI.state, .unknown)
        XCTAssertNotEqual(timeout.detail, privateAPI.detail)
    }
}
