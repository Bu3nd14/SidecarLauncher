import XCTest
@testable import SidecarSwitchCore

final class ExitCodeTests: XCTestCase {
    func testLocalStatusMapping() {
        XCTAssertEqual(ExitCodes.local(.launched(exitCode: 0)), .ok)
        XCTAssertEqual(ExitCodes.local(.launched(exitCode: 3)), .exited(3))
        XCTAssertEqual(ExitCodes.local(CommandResult(exitCode: 0, signal: 9)), .crashed(signal: 9))
        XCTAssertEqual(ExitCodes.local(CommandResult(exitCode: 0, timedOut: true)), .timedOut)
        XCTAssertEqual(ExitCodes.local(CommandResult(launchError: "not found")), .launchFailed("not found"))
    }

    func testSSHPropagatedExits() {
        XCTAssertEqual(ExitCodes.ssh(.launched(exitCode: 0)), .ok)
        XCTAssertEqual(ExitCodes.ssh(.launched(exitCode: 1)), .exited(1))
        XCTAssertEqual(ExitCodes.ssh(.launched(exitCode: 2)), .exited(2))
        XCTAssertEqual(ExitCodes.ssh(.launched(exitCode: 125)), .exited(125))
    }

    func testSSH126And127() {
        XCTAssertEqual(ExitCodes.ssh(.launched(exitCode: 126)), .transport(.remoteBootstrap))
        XCTAssertEqual(ExitCodes.ssh(.launched(exitCode: 127)), .transport(.remoteBootstrap))
    }

    func testSSHSignalWindow() {
        XCTAssertEqual(ExitCodes.ssh(.launched(exitCode: 128)), .transport(.remoteCrashed))
        XCTAssertEqual(ExitCodes.ssh(.launched(exitCode: 137)), .transport(.remoteCrashed))
        XCTAssertEqual(ExitCodes.ssh(.launched(exitCode: 254)), .transport(.remoteCrashed))
    }

    func testSSH255HostKey() {
        let result = CommandResult.launched(exitCode: 255, stderr: "SwitchHost key verification failed.")
        XCTAssertEqual(ExitCodes.ssh(result), .transport(.hostKeyMismatch))
        let changed = CommandResult.launched(exitCode: 255, stderr: "REMOTE HOST IDENTIFICATION HAS CHANGED!")
        XCTAssertEqual(ExitCodes.ssh(changed), .transport(.hostKeyMismatch))
    }

    func testSSH255Auth() {
        XCTAssertEqual(ExitCodes.ssh(.launched(exitCode: 255, stderr: "Permission denied (publickey).")),
                       .transport(.authFailed))
        XCTAssertEqual(ExitCodes.ssh(.launched(exitCode: 255, stderr: "Too many authentication failures")),
                       .transport(.authFailed))
    }

    func testConnectExit4TransientMarkers() {
        XCTAssertTrue(ExitCodes.connectExit4IsTransient(stderr: "error -455 SidecarErrorDisplayAWDLDegraded"))
        XCTAssertTrue(ExitCodes.connectExit4IsTransient(stderr: "SidecarErrorServiceDisconnected -101"))
        XCTAssertTrue(ExitCodes.connectExit4IsTransient(stderr: "-203 SidecarErrorDeviceWiFiNotEnabled"))
        XCTAssertFalse(ExitCodes.connectExit4IsTransient(stderr: "-501 SidecarErrorVirtualDisplayFailed"))
    }

    func testTransportWhitelist() {
        XCTAssertTrue(ExitCodes.isTransportWhitelisted(stderr: "Connection timed out during banner exchange"))
        XCTAssertTrue(ExitCodes.isTransportWhitelisted(stderr: "Operation timed out"))
        XCTAssertTrue(ExitCodes.isTransportWhitelisted(stderr: "Connection reset by peer"))
        XCTAssertTrue(ExitCodes.isTransportWhitelisted(stderr: "kex_exchange_identification: read: Connection reset"))
        XCTAssertTrue(ExitCodes.isTransportWhitelisted(stderr: "Connection closed by 1.2.3.4 port 22"))
        XCTAssertTrue(ExitCodes.isTransportWhitelisted(stderr: "ProxyCommand /opt/homebrew/bin/cloudflared exited with status 1"))
        XCTAssertFalse(ExitCodes.isTransportWhitelisted(stderr: "remote command exited with status 1"))
        XCTAssertFalse(ExitCodes.isTransportWhitelisted(stderr: "Permission denied (publickey)."))
        XCTAssertFalse(ExitCodes.isTransportWhitelisted(stderr: "REMOTE HOST IDENTIFICATION HAS CHANGED"))
    }

    func testSSH255Unreachable() {
        XCTAssertEqual(ExitCodes.ssh(.launched(exitCode: 255, stderr: "Connection refused")),
                       .transport(.targetUnreachable))
        XCTAssertEqual(ExitCodes.ssh(.launched(exitCode: 255)), .transport(.targetUnreachable))
    }

    func testSSHTimeout() {
        XCTAssertEqual(ExitCodes.ssh(CommandResult(exitCode: 0, timedOut: true)),
                       .transport(.targetUnreachable))
    }

    func testSSHKilledByUs() {
        XCTAssertEqual(ExitCodes.ssh(CommandResult(exitCode: 0, signal: SIGKILL)),
                       .transport(.targetUnreachable))
        XCTAssertEqual(ExitCodes.ssh(CommandResult(exitCode: 0, signal: SIGSEGV)),
                       .transport(.remoteCrashed))
    }

    func testProbeReportFromConnected() {
        let result = CommandResult.launched(exitCode: 0, stdout: "connected=1\ndevice=iPad\n")
        XCTAssertEqual(ExitCodes.probeReport(host: .lavoro, result: result),
                       ProbeReport(state: .connected(devices: ["iPad"])))
    }

    func testProbeReportCountMismatchIsUnknown() {
        let result = CommandResult.launched(exitCode: 0, stdout: "connected=2\ndevice=iPad\n")
        XCTAssertEqual(ExitCodes.probeReport(host: .lavoro, result: result).state, .unknown)
    }

    func testProbeReportDisconnected() {
        XCTAssertEqual(ExitCodes.probeReport(host: .lavoro, result: .launched(exitCode: 1, stdout: "connected=0\n")).state,
                       .disconnected)
    }

    func testProbeReportPrivateAPIAndTimeoutAreDistinct() {
        XCTAssertEqual(ExitCodes.probeReport(host: .lavoro, result: .launched(exitCode: 3)).state, .unknown)
        XCTAssertTrue(ExitCodes.probeReport(host: .lavoro, result: .launched(exitCode: 3)).detail?.contains("private API") ?? false)
        XCTAssertTrue(ExitCodes.probeReport(host: .lavoro, result: CommandResult(timedOut: true)).detail?.contains("timeout") ?? false)
    }

    func testRemoteProbeExit3IsUnknown() {
        let report = ExitCodes.probeReport(host: .personale, result: .launched(exitCode: 3))
        XCTAssertEqual(report.state, .unknown)
    }

    func testRemoteProbe255MapsReason() {
        let result = CommandResult.launched(exitCode: 255, stderr: "Permission denied (publickey).")
        let report = ExitCodes.probeReport(host: .personale, result: result)
        XCTAssertEqual(report.state, .unreachable)
        XCTAssertEqual(report.reason, .authFailed)
    }

    func testHardenMappingArrange() {
        XCTAssertEqual(ExitCodes.harden(status: .ok, stderr: ""), .ok)
        XCTAssertEqual(ExitCodes.harden(status: .exited(3), stderr: ""),
                       .warning("arrange: layout applicato ma non verificato"))
        XCTAssertEqual(ExitCodes.harden(status: .exited(2), stderr: ""),
                       .warning("arrange: nessun display Sidecar/virtuale"))
        guard case .warning = ExitCodes.harden(status: .exited(1), stderr: "") else {
            return XCTFail("arrange exit 1 deve essere warning")
        }
    }
}
