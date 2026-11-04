import XCTest
@testable import SidecarSwitchCore

final class CommandBuilderTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")
    private var remote: RemoteSettings {
        RemoteSettings(
            host: "personale.local",
            user: "utente",
            port: 22,
            identityFile: "~/.ssh/id_ed25519_sidecar_switch",
            binaryPath: "/Users/utente/SidecarLauncher/tools/bin/SidecarLauncher",
            connectedPath: "/Users/utente/SidecarLauncher/tools/bin/connected",
            dispidPath: "/Users/utente/SidecarLauncher/tools/bin/dispid",
            mirrorPath: "/Users/utente/SidecarLauncher/tools/bin/mirror",
            arrangePath: "/Users/utente/SidecarLauncher/tools/bin/arrange"
        )
    }
    private let ssh = SSHSettings.standard
    private let knownHosts = "/Users/test/.sidecar-switch/known_hosts"

    func testShellQuotePlain() {
        XCTAssertEqual(CommandBuilder.shellQuote("iPad"), "'iPad'")
        XCTAssertEqual(CommandBuilder.shellQuote(""), "''")
    }

    func testShellQuoteApostrophe() {
        XCTAssertEqual(CommandBuilder.shellQuote("a'b"), "'a'\\''b'")
    }

    func testShellQuoteInjectionStaysLiteral() {
        let hostile = "iPad'$(touch /tmp/pwn)"
        let quoted = CommandBuilder.shellQuote(hostile)
        XCTAssertEqual(quoted, "'iPad'\\''$(touch /tmp/pwn)'")
    }

    func testLocalConnectArgumentIsSingleLiteralElement() {
        let hostile = "a\"b\\c"
        let spec = CommandBuilder.localSpec(executable: "/tmp/SidecarLauncher", verb: "connect", device: hostile)
        XCTAssertEqual(spec.executable, "/tmp/SidecarLauncher")
        XCTAssertEqual(spec.arguments, ["connect", hostile])
        XCTAssertEqual(spec.arguments.count, 2)
    }

    func testLocalDisconnectAndDevicesArguments() {
        XCTAssertEqual(CommandBuilder.localSpec(executable: "/x", verb: "devices", device: nil).arguments, ["devices"])
        let spec = CommandBuilder.localSpec(executable: "/x", verb: "disconnect", device: "iPad'$(touch /tmp/pwn)")
        XCTAssertEqual(spec.arguments, ["disconnect", "iPad'$(touch /tmp/pwn)"])
    }

    func testRemoteCommandQuotesDevice() {
        let command = CommandBuilder.remoteCommand(
            remoteExecutable: "/Users/utente/SidecarLauncher/tools/bin/SidecarLauncher",
            verb: "connect",
            device: "iPad'$(touch /tmp/pwn)"
        )
        XCTAssertEqual(
            command,
            "'/Users/utente/SidecarLauncher/tools/bin/SidecarLauncher' connect 'iPad'\\''$(touch /tmp/pwn)'"
        )
    }

    func testRemoteCommandWithoutDevice() {
        let command = CommandBuilder.remoteCommand(remoteExecutable: "/x/connected", verb: "", device: nil)
        XCTAssertEqual(command, "'/x/connected' ")
    }

    func testSSHArgumentsDefaultPort() throws {
        let args = try CommandBuilder.sshArguments(remote: remote, ssh: ssh, knownHostsPath: knownHosts,
                                                   command: "'/x/connected'", firstConnect: true, home: home)
        XCTAssertEqual(args.first, "/usr/bin/ssh")
        XCTAssertFalse(args.contains("/usr/bin/env"))
        XCTAssertTrue(args.contains("-i"))
        let identity = try XCTUnwrap(args.firstIndex(of: "-i"))
        XCTAssertEqual(args[identity + 1], "/Users/test/.ssh/id_ed25519_sidecar_switch")
        XCTAssertFalse(args.contains("~/.ssh/id_ed25519_sidecar_switch"))
        XCTAssertTrue(args.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ConnectTimeout=15"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(args.contains("UserKnownHostsFile=\(knownHosts)"))
        XCTAssertTrue(args.contains("LogLevel=INFO"))
        XCTAssertTrue(args.contains("-T"))
        XCTAssertFalse(args.contains("-p"))
        XCTAssertFalse(args.contains("-F"))
        XCTAssertEqual(args[args.count - 2], "utente@personale.local")
        XCTAssertEqual(args.last, "'/x/connected'")
    }

    func testSSHArgumentsCustomPortAndLogLevel() throws {
        var custom = remote
        custom.port = 2222
        let args = try CommandBuilder.sshArguments(remote: custom, ssh: ssh, knownHostsPath: knownHosts,
                                                   command: "'/x/connected'", firstConnect: false, home: home)
        XCTAssertTrue(args.contains("-p"))
        let portIndex = try XCTUnwrap(args.firstIndex(of: "-p"))
        XCTAssertEqual(args[portIndex + 1], "2222")
        XCTAssertTrue(args.contains("LogLevel=ERROR"))
    }

    func testSSHArgumentsWithoutUser() throws {
        var custom = remote
        custom.user = ""
        let args = try CommandBuilder.sshArguments(remote: custom, ssh: ssh, knownHostsPath: knownHosts,
                                                   command: "true", firstConnect: false, home: home)
        XCTAssertEqual(args[args.count - 2], "personale.local")
    }

    func testSSHConfigPathIsExplicitWhenPresent() throws {
        let config = "/Users/test/.ssh/config"
        let args = try CommandBuilder.sshArguments(remote: remote, ssh: ssh, knownHostsPath: knownHosts,
                                                   command: "true", firstConnect: false, home: home,
                                                   sshConfigPath: config)
        let index = try XCTUnwrap(args.firstIndex(of: "-F"))
        XCTAssertEqual(args[index + 1], config)
        XCTAssertFalse(args.contains("/dev/null"))
        XCTAssertFalse(args.contains("ProxyCommand=none"))
    }

    func testQueryArgumentsUseSameConfigAndPort() throws {
        var custom = remote
        custom.port = 2222
        let args = try CommandBuilder.sshQueryArguments(remote: custom, ssh: ssh, home: home,
                                                        sshConfigPath: "/Users/test/.ssh/config")
        XCTAssertEqual(args.first, "/usr/bin/ssh")
        XCTAssertTrue(args.contains("-G"))
        XCTAssertTrue(args.contains("-F"))
        XCTAssertTrue(args.contains("-p"))
        XCTAssertEqual(args.last, "utente@personale.local")
    }

    func testHostValidationRejectsOptionInjection() {
        XCTAssertThrowsError(try CommandBuilder.validateHost("-oProxyCommand=/bin/sh"))
        XCTAssertThrowsError(try CommandBuilder.validateHost("host with space"))
        XCTAssertThrowsError(try CommandBuilder.validateHost("host\nname"))
        XCTAssertThrowsError(try CommandBuilder.validateHost(""))
        XCTAssertThrowsError(try CommandBuilder.validateHost("a@b"))
        XCTAssertThrowsError(try CommandBuilder.validateHost("host;rm"))
    }

    func testHostValidationIPv6() {
        XCTAssertNoThrow(try CommandBuilder.validateHost("[::1]"))
        XCTAssertThrowsError(try CommandBuilder.validateHost("::1"))
        XCTAssertThrowsError(try CommandBuilder.validateHost("[]"))
    }

    func testUserValidation() {
        XCTAssertNoThrow(try CommandBuilder.validateUser("utente"))
        XCTAssertNoThrow(try CommandBuilder.validateUser(""))
        XCTAssertThrowsError(try CommandBuilder.validateUser("a@b"))
        XCTAssertThrowsError(try CommandBuilder.validateUser("-x"))
        XCTAssertThrowsError(try CommandBuilder.validateUser("a b"))
    }

    func testPortValidation() {
        XCTAssertNoThrow(try CommandBuilder.validatePort(1))
        XCTAssertNoThrow(try CommandBuilder.validatePort(65535))
        XCTAssertThrowsError(try CommandBuilder.validatePort(0))
        XCTAssertThrowsError(try CommandBuilder.validatePort(65536))
        XCTAssertThrowsError(try CommandBuilder.validatePort(-1))
    }

    func testPathValidation() {
        XCTAssertNoThrow(try CommandBuilder.validateAbsolutePath("/Users/test/tool"))
        XCTAssertThrowsError(try CommandBuilder.validateAbsolutePath("relative/tool"))
        XCTAssertThrowsError(try CommandBuilder.validateAbsolutePath("/tmp/a\nb"))
    }

    func testSettingsValidationRejectsStrictHostKeyNo() {
        var settings = Settings.default
        settings.ssh.strictHostKeyChecking = "no"
        XCTAssertThrowsError(try settings.validate())
    }

    func testRemoteValidationRejectsInvalidPort() {
        var custom = remote
        custom.port = 65536
        XCTAssertThrowsError(try CommandBuilder.validate(custom, home: home))
    }

    func testRemoteValidationAllowsEmptyHostAndPaths() {
        let empty = RemoteSettings.standard
        XCTAssertNoThrow(try CommandBuilder.validate(empty, home: home))
    }

    func testRemoteValidationRejectsRemoteTilde() {
        var custom = remote
        custom.binaryPath = "~/bin/SidecarLauncher"
        XCTAssertThrowsError(try CommandBuilder.validate(custom, home: home))
    }

    func testEmptyIdentityIsBlockingAndNeverEmitsDashI() throws {
        var custom = remote
        custom.identityFile = ""
        XCTAssertThrowsError(try CommandBuilder.validate(custom, home: home))
        XCTAssertThrowsError(try CommandBuilder.sshArguments(remote: custom, ssh: ssh, knownHostsPath: knownHosts,
                                                             command: "true", firstConnect: false, home: home))
    }

    func testHostileRemoteCommandDoesNotCreateFiles() throws {
        let directory = try makeTempDirectory("command-builder")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("pwn")
        let device = "iPad'$(touch \(marker.path))"
        let spec = CommandBuilder.localSpec(executable: "/bin/echo", verb: "connect", device: device)
        XCTAssertEqual(spec.arguments[1], device)
        let command = CommandBuilder.remoteCommand(remoteExecutable: "/bin/echo", verb: "connect", device: device)
        XCTAssertTrue(command.contains("'\\''"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
