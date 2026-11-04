import Foundation

public enum DockIconVariant: Sendable, Equatable {
    case normal
    case switching
}

public enum DockIconPlanner {
    public static func plan(isTransitioning: Bool, switchingAssetAvailable: Bool) -> DockIconVariant {
        guard isTransitioning, switchingAssetAvailable else { return .normal }
        return .switching
    }
}
