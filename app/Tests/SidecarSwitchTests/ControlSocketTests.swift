import XCTest
@testable import SidecarSwitchCore

final class ControlSocketTests: XCTestCase {
    func testK82FnvDeterministicAndKnownVectors() {
        XCTAssertEqual(ControlSocket.fnv1a64(""), 0xcbf29ce484222325)
        XCTAssertEqual(ControlSocket.hex16(ControlSocket.fnv1a64("")), "cbf29ce484222325")
        XCTAssertEqual(ControlSocket.hex16(ControlSocket.fnv1a64("utente@host:22")), "06ee206c4b4387e0")
        XCTAssertEqual(ControlSocket.hex16(ControlSocket.fnv1a64("tester@127.0.0.1:2222")), "057ae485945f9bff")
        XCTAssertEqual(ControlSocket.fnv1a64("a"), ControlSocket.fnv1a64("a"))
        XCTAssertNotEqual(ControlSocket.fnv1a64("a"), ControlSocket.fnv1a64("b"))
    }

    func testK82SocketNameIsDeterministicAndSafe() {
        let name = ControlSocket.socketName(host: "personale.local", user: "utente", port: 22)
        XCTAssertEqual(name, ControlSocket.socketName(host: "personale.local", user: "utente", port: 22))
        XCTAssertTrue(name.hasPrefix("ssc-"))
        XCTAssertTrue(name.hasSuffix(".sock"))
        XCTAssertEqual(name.count, 4 + 16 + 5)
        XCTAssertFalse(name.contains("%"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertEqual(name.dropFirst(4).dropLast(5).count, 16)
        XCTAssertTrue(name.dropFirst(4).dropLast(5).allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testK82DifferentIdentityProducesDifferentName() {
        let base = ControlSocket.socketName(host: "h", user: "u", port: 22)
        XCTAssertNotEqual(base, ControlSocket.socketName(host: "h2", user: "u", port: 22))
        XCTAssertNotEqual(base, ControlSocket.socketName(host: "h", user: "u2", port: 22))
        XCTAssertNotEqual(base, ControlSocket.socketName(host: "h", user: "u", port: 2222))
        XCTAssertNotEqual(base, ControlSocket.socketName(host: "h", user: "", port: 22))
    }

    func testK82PathComposition() {
        let path = ControlSocket.path(runDirectory: "/Users/utente/.sidecar-switch/run",
                                      host: "personale.local", user: "utente", port: 22)
        XCTAssertTrue(path.hasPrefix("/Users/utente/.sidecar-switch/run/ssc-"))
        XCTAssertTrue(path.hasSuffix(".sock"))
        XCTAssertEqual(path.utf8.count, 53 + "utente".utf8.count)
        XCTAssertEqual(ControlSocket.pathLengthValid(path), true)
        XCTAssertEqual(ControlSocket.pathContainsPercent(path), false)
    }

    func testK82LengthBoundary86And87() {
        let run86 = String(repeating: "a", count: 60)
        let path86 = ControlSocket.path(runDirectory: run86, host: "h", user: "u", port: 22)
        XCTAssertEqual(path86.utf8.count, 86)
        XCTAssertTrue(ControlSocket.pathLengthValid(path86))

        let run87 = String(repeating: "a", count: 61)
        let path87 = ControlSocket.path(runDirectory: run87, host: "h", user: "u", port: 22)
        XCTAssertEqual(path87.utf8.count, 87)
        XCTAssertFalse(ControlSocket.pathLengthValid(path87))
    }

    func testK82PercentCheckIsSeparate() {
        let path = "/Users/utente/%run/ssc-0123456789abcdef.sock"
        XCTAssertTrue(ControlSocket.pathContainsPercent(path))
        XCTAssertTrue(ControlSocket.pathLengthValid(path))
        XCTAssertFalse(ControlSocket.pathContainsPercent("/Users/utente/run/ssc-0123456789abcdef.sock"))
    }

    func testK82ControlPersistExceedsMaxGap() {
        XCTAssertEqual(ControlSocket.controlPersistSeconds, 20)
        XCTAssertEqual(ControlSocket.maxRemoteGapSeconds, 10)
        XCTAssertTrue(ControlSocket.controlPersistExceedsMaxGap)
        XCTAssertEqual(ControlSocket.controlCommandTimeout, .seconds(5))
        XCTAssertEqual(ControlSocket.maxPathBytes, 86)
    }

    func testRunDirectoryPath() {
        let home = URL(fileURLWithPath: "/Users/test")
        XCTAssertEqual(AppPaths(home: home).runDirectory.path, "/Users/test/.sidecar-switch/run")
    }

    func testRemoteSessionFirstCommandAndDisable() {
        let session = RemoteSession(controlPath: "/tmp/ssc.sock")
        XCTAssertFalse(session.issuedFirstCommand)
        XCTAssertFalse(session.disabled)
        XCTAssertTrue(session.claimFirstCommand())
        XCTAssertFalse(session.claimFirstCommand())
        XCTAssertTrue(session.issuedFirstCommand)
        session.disable()
        XCTAssertTrue(session.disabled)
    }
}
