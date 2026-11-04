import Foundation
import XCTest
@testable import SidecarSwitchCore

enum Op: Equatable, CustomStringConvertible {
    case probe(SwitchHost)
    case devices(SwitchHost)
    case displays(SwitchHost)
    case disconnect(SwitchHost, String)
    case connect(SwitchHost, String)
    case harden(SwitchHost)
    case batch(RemoteBatchKind)

    var description: String {
        switch self {
        case .probe(let host): return "connected(\(host.rawValue))"
        case .devices(let host): return "devices(\(host.rawValue))"
        case .displays(let host): return "dispid(\(host.rawValue))"
        case .disconnect(let host, let device): return "disconnect(\(host.rawValue), \(device))"
        case .connect(let host, let device): return "connect(\(host.rawValue), \(device))"
        case .harden(let host): return "harden(\(host.rawValue))"
        case .batch(let kind): return "batch(\(kind.rawValue))"
        }
    }
}

final class RecordingOperations: SidecarOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Op] = []
    private var probes: [SwitchHost: [ProbeReport]] = [:]
    private var devices: [SwitchHost: [DevicesReport]] = [:]
    private var displays: [SwitchHost: [DisplaysReport]] = [:]
    private var connectStatuses: [CommandStatus] = []
    private var connectOutcomes: [CommandOutcome] = []
    private var disconnectStatuses: [CommandStatus] = []
    private var hardenOutcomes: [SwitchHost: [HardenOutcome]] = [:]

    var probeDelay: Duration = .zero
    var devicesDelay: Duration = .zero
    var devicesSleeper: (any Sleeping)?
    var batchExecutor: (@Sendable (RemoteBatchKind) -> BatchExecution)?
    private var recordedHardenSkips: [SwitchHost: Bool] = [:]
    private var sessionEnabled = false
    private var recordedLifecycle: [String] = []
    private var recordedSessionOps: [(Op, Bool)] = []
    private var sessionBegins = 0
    private var sessionEnds = 0
    var onOperation: (@Sendable (Op) -> Void)?
    private var recordedDeviceTimeouts: [Duration] = []
    var deviceTimeouts: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDeviceTimeouts
    }

    var operations: [Op] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func count(of op: Op) -> Int {
        operations.filter { $0 == op }.count
    }

    private func append(_ op: Op) {
        lock.lock()
        recorded.append(op)
        recordedLifecycle.append("do:\(op.description)")
        lock.unlock()
        onOperation?(op)
    }

    func setProbes(_ host: SwitchHost, _ reports: [ProbeReport]) {
        lock.lock(); probes[host] = reports; lock.unlock()
    }

    func setDevices(_ host: SwitchHost, _ reports: [DevicesReport]) {
        lock.lock(); devices[host] = reports; lock.unlock()
    }

    func setDisplays(_ host: SwitchHost, _ reports: [DisplaysReport]) {
        lock.lock(); displays[host] = reports; lock.unlock()
    }

    func setConnectStatuses(_ statuses: [CommandStatus]) {
        lock.lock(); connectStatuses = statuses; lock.unlock()
    }

    func setConnectOutcomes(_ outcomes: [CommandOutcome]) {
        lock.lock(); connectOutcomes = outcomes; lock.unlock()
    }

    func setDisconnectStatuses(_ statuses: [CommandStatus]) {
        lock.lock(); disconnectStatuses = statuses; lock.unlock()
    }

    func setHarden(_ host: SwitchHost, _ outcomes: [HardenOutcome]) {
        lock.lock(); hardenOutcomes[host] = outcomes; lock.unlock()
    }

    func setSessionEnabled(_ enabled: Bool) {
        lock.lock(); sessionEnabled = enabled; lock.unlock()
    }

    var lifecycle: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedLifecycle
    }

    var sessionOperations: [(op: Op, session: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSessionOps
    }

    var begins: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessionBegins
    }

    var ends: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessionEnds
    }

    private func noteSession(_ op: Op, _ session: RemoteSession?) {
        lock.lock()
        recordedLifecycle.append("\(op.description)[\(session == nil ? "plain" : "session")]")
        recordedSessionOps.append((op, session != nil))
        lock.unlock()
    }

    private func recordSessionBegin() -> (enabled: Bool, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        sessionBegins += 1
        recordedLifecycle.append("begin")
        return (sessionEnabled, sessionBegins)
    }

    private func recordSessionEnd(_ session: RemoteSession?) {
        lock.lock()
        sessionEnds += 1
        recordedLifecycle.append("end[\(session == nil ? "nil" : "session")]")
        lock.unlock()
    }

    func beginRemoteSession() async -> RemoteSession? {
        let value = recordSessionBegin()
        return value.enabled ? RemoteSession(controlPath: "/tmp/ssc-recording-\(value.count).sock") : nil
    }

    func endRemoteSession(_ session: RemoteSession?) async {
        recordSessionEnd(session)
    }

    func probe(_ host: SwitchHost, timeout: Duration, session: RemoteSession?) async -> ProbeReport {
        noteSession(.probe(host), session)
        return await probe(host, timeout: timeout)
    }

    func probe(_ host: SwitchHost, timeout: Duration, retry: Bool,
               session: RemoteSession?) async -> ProbeReport {
        noteSession(.probe(host), session)
        return await probe(host, timeout: timeout, retry: retry)
    }

    func devices(_ host: SwitchHost, timeout: Duration, session: RemoteSession?) async -> DevicesReport {
        noteSession(.devices(host), session)
        return await devices(host, timeout: timeout)
    }

    func devices(_ host: SwitchHost, timeout: Duration, retry: Bool,
                 session: RemoteSession?) async -> DevicesReport {
        noteSession(.devices(host), session)
        return await devices(host, timeout: timeout, retry: retry)
    }

    func displays(_ host: SwitchHost, timeout: Duration, session: RemoteSession?) async -> DisplaysReport {
        noteSession(.displays(host), session)
        return await displays(host, timeout: timeout)
    }

    func disconnect(_ host: SwitchHost, device: String, timeout: Duration,
                    session: RemoteSession?) async -> CommandOutcome {
        noteSession(.disconnect(host, device), session)
        return await disconnect(host, device: device, timeout: timeout)
    }

    func connect(_ host: SwitchHost, device: String, timeout: Duration,
                 session: RemoteSession?) async -> CommandOutcome {
        noteSession(.connect(host, device), session)
        return await connect(host, device: device, timeout: timeout)
    }

    func harden(_ host: SwitchHost, timeout: Duration, skipArrange: Bool,
                session: RemoteSession?) async -> HardenOutcome {
        noteSession(.harden(host), session)
        return await harden(host, timeout: timeout, skipArrange: skipArrange)
    }

    func remoteBatch(_ kind: RemoteBatchKind, nonce: String, settle: Duration,
                     timeout: Duration, session: RemoteSession?) async -> BatchExecution {
        noteSession(.batch(kind), session)
        return await remoteBatch(kind, nonce: nonce, settle: settle, timeout: timeout)
    }

    private func popProbe(_ host: SwitchHost) -> ProbeReport {
        lock.lock()
        defer { lock.unlock() }
        var queue = probes[host] ?? []
        if queue.isEmpty { return ProbeReport(state: .disconnected) }
        let value = queue.removeFirst()
        probes[host] = queue
        return value
    }

    private func popDevices(_ host: SwitchHost) -> DevicesReport {
        lock.lock()
        defer { lock.unlock() }
        var queue = devices[host] ?? []
        if queue.isEmpty {
            return DevicesReport(status: .ok, names: ["iPad"], report: CommandReport(status: .ok))
        }
        let value = queue.removeFirst()
        devices[host] = queue
        return value
    }

    private func popDisplays(_ host: SwitchHost) -> DisplaysReport {
        lock.lock()
        defer { lock.unlock() }
        var queue = displays[host] ?? []
        if queue.isEmpty {
            return DisplaysReport(status: .ok, displays: [Fixtures.virtual],
                                  report: CommandReport(status: .ok))
        }
        let value = queue.removeFirst()
        displays[host] = queue
        return value
    }

    private func popConnect() -> CommandOutcome {
        lock.lock()
        defer { lock.unlock() }
        if !connectOutcomes.isEmpty { return connectOutcomes.removeFirst() }
        let status: CommandStatus = connectStatuses.isEmpty ? .ok : connectStatuses.removeFirst()
        return CommandOutcome(status: status, report: CommandReport(status: status))
    }

    private func popDisconnect() -> CommandStatus {
        lock.lock()
        defer { lock.unlock() }
        if disconnectStatuses.isEmpty { return .ok }
        return disconnectStatuses.removeFirst()
    }

    private func popHarden(_ host: SwitchHost) -> HardenOutcome {
        lock.lock()
        defer { lock.unlock() }
        var queue = hardenOutcomes[host] ?? []
        if queue.isEmpty { return .ok }
        let value = queue.removeFirst()
        hardenOutcomes[host] = queue
        return value
    }

    func probe(_ host: SwitchHost, timeout: Duration) async -> ProbeReport {
        append(.probe(host))
        if probeDelay > .zero {
            try? await Task.sleep(for: probeDelay)
        }
        return popProbe(host)
    }

    private func recordDeviceTimeout(_ value: Duration) {
        lock.lock()
        recordedDeviceTimeouts.append(value)
        lock.unlock()
    }

    func devices(_ host: SwitchHost, timeout: Duration) async -> DevicesReport {
        append(.devices(host))
        recordDeviceTimeout(timeout)
        return popDevices(host)
    }

    func devices(_ host: SwitchHost, timeout: Duration, retry: Bool) async -> DevicesReport {
        if !retry, devicesDelay > .zero, let devicesSleeper {
            recordDeviceTimeout(timeout)
            await devicesSleeper.sleep(min(devicesDelay, timeout))
        }
        return await devices(host, timeout: timeout)
    }

    func displays(_ host: SwitchHost, timeout: Duration) async -> DisplaysReport {
        append(.displays(host))
        return popDisplays(host)
    }

    func disconnect(_ host: SwitchHost, device: String, timeout: Duration) async -> CommandOutcome {
        append(.disconnect(host, device))
        let status = popDisconnect()
        return CommandOutcome(status: status, report: CommandReport(status: status))
    }

    func connect(_ host: SwitchHost, device: String, timeout: Duration) async -> CommandOutcome {
        append(.connect(host, device))
        return popConnect()
    }

    func harden(_ host: SwitchHost, timeout: Duration) async -> HardenOutcome {
        await harden(host, timeout: timeout, skipArrange: false)
    }

    private func recordHardenSkip(_ host: SwitchHost, _ skipArrange: Bool) {
        lock.lock()
        recordedHardenSkips[host] = skipArrange
        lock.unlock()
    }

    func harden(_ host: SwitchHost, timeout: Duration, skipArrange: Bool) async -> HardenOutcome {
        recordHardenSkip(host, skipArrange)
        append(.harden(host))
        return popHarden(host)
    }

    func hardenSkip(_ host: SwitchHost) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return recordedHardenSkips[host]
    }

    func remoteBatch(_ kind: RemoteBatchKind, nonce: String, settle: Duration,
                     timeout: Duration) async -> BatchExecution {
        guard let batchExecutor else {
            return .parseFailed(.invalidStructure("batch non configurato"))
        }
        append(.batch(kind))
        return batchExecutor(kind)
    }
}

final class StateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TransitionState] = []

    func append(_ state: TransitionState) {
        lock.lock()
        items.append(state)
        lock.unlock()
    }

    var states: [TransitionState] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

struct TestSleeper: Sleeping {
    func sleep(_ duration: Duration) async {}
}

final class RecordingSleeper: Sleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    var durations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ duration: Duration) {
        lock.lock()
        recorded.append(duration)
        lock.unlock()
    }

    func sleep(_ duration: Duration) async {
        record(duration)
    }
}

enum Fixtures {
    static let virtual = DisplayInfo(id: 3, vendor: 0x5644, active: true, width: 1321, height: 918)
    static let builtin = DisplayInfo(id: 1, vendor: 0x0610, builtin: true, main: true, active: true)
    static let sidecarLive = DisplayInfo(id: 4, vendor: 0x6161706c, active: true, asleep: false)
    static let sidecarMirrored = DisplayInfo(id: 4, vendor: 0x6161706c, active: false, mirrors: 3, asleep: false)
    static let sidecarAsleep = DisplayInfo(id: 4, vendor: 0x6161706c, active: true, asleep: true)

    static func connected(_ names: [String] = ["iPad"]) -> ProbeReport {
        ProbeReport(state: .connected(devices: names))
    }

    static func disconnected() -> ProbeReport {
        ProbeReport(state: .disconnected)
    }

    static func unknown(_ detail: String? = nil) -> ProbeReport {
        ProbeReport(state: .unknown, detail: detail)
    }

    static func unreachable(_ reason: Reason? = nil) -> ProbeReport {
        ProbeReport(state: .unreachable, reason: reason)
    }

    static func devicesOK(_ names: [String] = ["iPad"]) -> DevicesReport {
        DevicesReport(status: .ok, names: names, report: CommandReport(status: .ok))
    }

    static func devicesFailed(_ status: CommandStatus) -> DevicesReport {
        DevicesReport(status: status, names: [], report: CommandReport(status: status))
    }

    static func displaysOK(_ list: [DisplayInfo]) -> DisplaysReport {
        DisplaysReport(status: .ok, displays: list, report: CommandReport(status: .ok))
    }

    static func displaysFailed(_ status: CommandStatus) -> DisplaysReport {
        DisplaysReport(status: status, displays: [], report: CommandReport(status: status))
    }
}

func makeTempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sidecar-switch-tests", isDirectory: true)
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class ClosureRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CommandSpec] = []
    private let handler: @Sendable (CommandSpec) -> CommandResult

    init(_ handler: @escaping @Sendable (CommandSpec) -> CommandResult) {
        self.handler = handler
    }

    var specs: [CommandSpec] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ spec: CommandSpec) {
        lock.lock()
        recorded.append(spec)
        lock.unlock()
    }

    func run(_ spec: CommandSpec, timeout: Duration) async -> CommandResult {
        record(spec)
        return handler(spec)
    }
}

func makeMachine(
    _ ops: RecordingOperations,
    timings: Timings = .fast,
    logging: any SwitchLogging = NoopLogging(),
    observer: (@Sendable (TransitionState) -> Void)? = nil
) -> StateMachine {
    StateMachine(ops: ops, timings: timings, sleeper: TestSleeper(),
                 deviceName: "iPad", logging: logging, observer: observer)
}

extension XCTestCase {
    func assertOperations(_ ops: RecordingOperations, _ expected: [Op], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ops.operations.map(\.description), expected.map(\.description), file: file, line: line)
    }
}
