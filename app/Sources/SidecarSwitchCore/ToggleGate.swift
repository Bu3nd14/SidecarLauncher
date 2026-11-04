import Foundation

public actor ToggleGate {
    private var task: Task<TransitionOutcome, Never>?
    private var token: CancellationToken?
    private let logging: any SwitchLogging

    public init(logging: any SwitchLogging = NoopLogging()) {
        self.logging = logging
    }

    public var isTransitioning: Bool { task != nil }

    public func run(
        transitionID: UUID,
        _ work: @Sendable @escaping (CancellationToken) async -> TransitionOutcome
    ) async -> TransitionOutcome? {
        guard task == nil else {
            logging.log(.warning, "[\(transitionID.uuidString.prefix(8))] toggle scartato: transizione già in corso")
            return nil
        }
        let token = CancellationToken()
        self.token = token
        let task = Task.detached { await work(token) }
        self.task = task
        let outcome = await task.value
        self.task = nil
        self.token = nil
        return outcome
    }

    public func cancelCurrent() {
        token?.cancel()
    }

    public func waitForIdle(timeout: Duration) async -> Bool {
        let deadline = Deadline(after: timeout)
        while task != nil && !deadline.isExpired {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return task == nil
    }
}
