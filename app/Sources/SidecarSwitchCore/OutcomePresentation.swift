import Foundation

public enum OutcomePresentation {
    public enum Severity: Sendable, Equatable {
        case info
        case warning
        case error
    }

    public static func severity(for state: TransitionState) -> Severity {
        switch state {
        case .done:
            return .info
        case .failed(_, .incoherent), .failed(_, .foreignDevice):
            return .error
        case .failed:
            return .warning
        default:
            return .info
        }
    }
}
