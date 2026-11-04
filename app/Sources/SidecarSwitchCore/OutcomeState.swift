import Foundation

public enum OutcomeStateReducer {
    public static func actual(after outcome: TransitionOutcome, current: Location) -> Location {
        switch outcome.state {
        case .failed(_, .incoherent), .failed(_, .unknownHolder):
            return .unknown
        default:
            return outcome.actual ?? current
        }
    }
}
