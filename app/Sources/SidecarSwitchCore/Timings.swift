import Foundation

public struct Timings: Sendable, Equatable {
    public var sshConnectTimeout: Duration
    public var probeTimeout: Duration
    public var remoteProbeTimeout: Duration
    public var remoteAttempts: Int
    public var remoteRetryBudget: Duration
    public var bootstrapCap: Duration
    public var connectRetryMargin: Duration
    public var postDisconnectSettle: Duration
    public var settleBudget: Duration
    public var disconnectCommandTimeout: Duration
    public var disconnectPollAttempts: Int
    public var disconnectPollInterval: Duration
    public var connectCommandTimeout: Duration
    public var connectAttempts: Int
    public var retryBackoff: Duration
    public var settlePollAttempts: Int
    public var settlePollBackoffs: [Duration]
    public var settle: Duration
    public var displayWait: Duration
    public var displayPollInterval: Duration
    public var hardeningTimeout: Duration
    public var transitionDeadline: Duration
    public var rollbackBudget: Duration

    public init(
        sshConnectTimeout: Duration = .seconds(15),
        probeTimeout: Duration = .seconds(10),
        remoteProbeTimeout: Duration = .seconds(25),
        remoteAttempts: Int = 2,
        remoteRetryBudget: Duration = .seconds(40),
        bootstrapCap: Duration = .seconds(40),
        connectRetryMargin: Duration = .seconds(2),
        postDisconnectSettle: Duration = .seconds(3),
        settleBudget: Duration = .seconds(8),
        disconnectCommandTimeout: Duration = .seconds(20),
        disconnectPollAttempts: Int = 10,
        disconnectPollInterval: Duration = .seconds(1),
        connectCommandTimeout: Duration = .seconds(45),
        connectAttempts: Int = 2,
        retryBackoff: Duration = .seconds(2),
        settlePollAttempts: Int = 3,
        settlePollBackoffs: [Duration] = [.seconds(2), .seconds(4), .seconds(8)],
        settle: Duration = .seconds(3),
        displayWait: Duration = .seconds(25),
        displayPollInterval: Duration = .seconds(1),
        hardeningTimeout: Duration = .seconds(15),
        transitionDeadline: Duration = .seconds(360),
        rollbackBudget: Duration = .seconds(180)
    ) {
        self.sshConnectTimeout = sshConnectTimeout
        self.probeTimeout = probeTimeout
        self.remoteProbeTimeout = remoteProbeTimeout
        self.remoteAttempts = remoteAttempts
        self.remoteRetryBudget = remoteRetryBudget
        self.bootstrapCap = bootstrapCap
        self.connectRetryMargin = connectRetryMargin
        self.postDisconnectSettle = postDisconnectSettle
        self.settleBudget = settleBudget
        self.disconnectCommandTimeout = disconnectCommandTimeout
        self.disconnectPollAttempts = disconnectPollAttempts
        self.disconnectPollInterval = disconnectPollInterval
        self.connectCommandTimeout = connectCommandTimeout
        self.connectAttempts = connectAttempts
        self.retryBackoff = retryBackoff
        self.settlePollAttempts = settlePollAttempts
        self.settlePollBackoffs = settlePollBackoffs
        self.settle = settle
        self.displayWait = displayWait
        self.displayPollInterval = displayPollInterval
        self.hardeningTimeout = hardeningTimeout
        self.transitionDeadline = transitionDeadline
        self.rollbackBudget = rollbackBudget
    }

    public static let standard = Timings()

    public static let fast = Timings(
        sshConnectTimeout: .seconds(1),
        probeTimeout: .seconds(1),
        remoteProbeTimeout: .seconds(1),
        remoteAttempts: 2,
        remoteRetryBudget: .seconds(3),
        bootstrapCap: .seconds(3),
        connectRetryMargin: .zero,
        postDisconnectSettle: .zero,
        settleBudget: .seconds(1),
        disconnectCommandTimeout: .seconds(1),
        disconnectPollAttempts: 3,
        disconnectPollInterval: .zero,
        connectCommandTimeout: .seconds(1),
        connectAttempts: 2,
        retryBackoff: .zero,
        settlePollAttempts: 1,
        settlePollBackoffs: [.zero],
        settle: .zero,
        displayWait: .zero,
        displayPollInterval: .zero,
        hardeningTimeout: .seconds(1),
        transitionDeadline: .seconds(120),
        rollbackBudget: .seconds(120)
    )

    public func probeTimeout(for host: Host) -> Duration {
        host == .lavoro ? probeTimeout : remoteProbeTimeout
    }

    public func verifyProbeTimeout(for host: Host) -> Duration {
        host == .lavoro ? probeTimeout : sshConnectTimeout
    }

    public func verifyReserve(for host: Host) -> Duration {
        verifyProbeTimeout(for: host) * 2 + settle + displayWait
    }

    public func rollbackConnectBudget(remaining: Duration, host: Host) -> Duration? {
        let budget = remaining - verifyReserve(for: host)
        return budget >= connectCommandTimeout ? budget : nil
    }
}

public extension Duration {
    var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}

public struct Deadline: Sendable, Equatable {
    private let deadline: ContinuousClock.Instant

    public init(after duration: Duration) {
        self.deadline = ContinuousClock().now + duration
    }

    public var remaining: Duration {
        let value = deadline - ContinuousClock().now
        return value > .zero ? value : .zero
    }

    public var isExpired: Bool { remaining <= .zero }

    public func capped(_ duration: Duration) -> Duration {
        min(duration, remaining)
    }
}

public protocol Sleeping: Sendable {
    func sleep(_ duration: Duration) async
}

public struct RealSleeper: Sleeping {
    public init() {}

    public func sleep(_ duration: Duration) async {
        guard duration > .zero else { return }
        try? await Task.sleep(for: duration)
    }
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
