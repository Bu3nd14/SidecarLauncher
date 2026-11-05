import Foundation

public protocol DockIconScheduler {
    @MainActor func schedule(interval: Duration,
                             handler: @escaping @MainActor () -> Void) -> DockIconScheduleHandle
}

public protocol DockIconScheduleHandle {
    nonisolated func invalidate()
}
