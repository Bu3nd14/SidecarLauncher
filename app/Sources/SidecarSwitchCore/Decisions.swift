import Foundation

public enum Classifier {
    public static func classify(_ state: ProbeState, configuredName: String) -> ClassifiedProbe {
        switch state {
        case .connected(let devices):
            let names = devices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !names.isEmpty else { return .unknown }
            if names.count > 1 { return .tooMany }
            let expected = configuredName.trimmingCharacters(in: .whitespacesAndNewlines)
            return names[0].caseInsensitiveCompare(expected) == .orderedSame ? .connectediPad : .foreignDevice
        case .disconnected:
            return .disconnected
        case .unknown:
            return .unknown
        case .unreachable:
            return .unreachable
        }
    }

    public static func resolve(local: ClassifiedProbe, remote: ClassifiedProbe) -> Resolution {
        if local == .foreignDevice || remote == .foreignDevice { return .incoherent }
        if local == .tooMany || remote == .tooMany { return .incoherent }

        switch (local, remote) {
        case (.connectediPad, .connectediPad):
            return .incoherent
        case (.connectediPad, .disconnected), (.connectediPad, .unknown), (.connectediPad, .unreachable):
            return .location(.lavoro)
        case (.disconnected, .connectediPad):
            return .location(.personale)
        case (.disconnected, .disconnected):
            return .location(.nowhere)
        case (.disconnected, .unknown), (.disconnected, .unreachable):
            return .location(.unknown)
        case (.unknown, .connectediPad), (.unknown, .disconnected), (.unknown, .unknown), (.unknown, .unreachable):
            return .location(.unknown)
        default:
            return .location(.unknown)
        }
    }

    public static func decide(actual: Location, target: Host) -> Action {
        switch actual {
        case .unknown:
            return .abort(.unknownHolder)
        case .lavoro:
            return target == .lavoro ? .noop(.lavoro) : .disconnectThenConnect(source: .lavoro, target: .personale)
        case .personale:
            return target == .personale ? .noop(.personale) : .disconnectThenConnect(source: .personale, target: .lavoro)
        case .nowhere:
            return .connectOnly(target: target == .lavoro ? .lavoro : .personale)
        }
    }

    public static func deviceMatches(_ names: [String], configuredName: String) -> Bool {
        let expected = configuredName.trimmingCharacters(in: .whitespacesAndNewlines)
        return names.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(expected) == .orderedSame }
    }
}

public enum HotkeyDirection {
    public static func target(actual: Location, lastLocation: Location,
                              personaleDisabled: Bool = false) -> Host? {
        switch actual {
        case .lavoro:
            return .personale
        case .personale:
            return .lavoro
        case .nowhere:
            if personaleDisabled { return .lavoro }
            switch lastLocation {
            case .lavoro: return .personale
            case .personale: return .lavoro
            case .nowhere, .unknown: return nil
            }
        case .unknown:
            return nil
        }
    }
}

public struct StartupPlan: Sendable, Equatable {
    public var actual: Location
    public var persistence: PersistencePlan
    public var banner: String?
    public var switchEnabled: Bool
    public var needsReconcile: Bool

    public init(actual: Location, persistence: PersistencePlan, banner: String?, switchEnabled: Bool, needsReconcile: Bool) {
        self.actual = actual
        self.persistence = persistence
        self.banner = banner
        self.switchEnabled = switchEnabled
        self.needsReconcile = needsReconcile
    }
}

public enum StartupPlanner {
    public static func plan(
        local: ProbeState,
        remote: ProbeState,
        configuredName: String,
        lastLocation: Location,
        needsReconcile: Bool
    ) -> StartupPlan {
        let classifiedLocal = Classifier.classify(local, configuredName: configuredName)
        let classifiedRemote = Classifier.classify(remote, configuredName: configuredName)

        if classifiedLocal == .foreignDevice || classifiedRemote == .foreignDevice {
            return StartupPlan(actual: .unknown, persistence: .unchanged,
                               banner: Reason.foreignDevice.displayMessage,
                               switchEnabled: false, needsReconcile: needsReconcile)
        }
        if classifiedLocal == .tooMany || classifiedRemote == .tooMany {
            return StartupPlan(actual: .unknown, persistence: PersistencePlan(needsReconcile: true),
                               banner: "Più di un device connesso: invariante violata.",
                               switchEnabled: false, needsReconcile: true)
        }

        switch Classifier.resolve(local: classifiedLocal, remote: classifiedRemote) {
        case .incoherent:
            return StartupPlan(actual: .unknown, persistence: PersistencePlan(needsReconcile: true),
                               banner: "Stato incoerente: iPad segnalato su entrambi i Mac.",
                               switchEnabled: false, needsReconcile: true)
        case .location(let location):
            switch location {
            case .unknown:
                return StartupPlan(actual: .unknown, persistence: .unchanged,
                                   banner: "Stato sconosciuto: nessuna azione eseguita.",
                                   switchEnabled: false, needsReconcile: needsReconcile)
            case .lavoro, .personale, .nowhere:
                var banner: String?
                var update = LocationUpdate.unchanged
                if location != lastLocation {
                    update = .set(location)
                    banner = "Rilevato: iPad su \(location.displayName) (prima \(lastLocation.displayName))."
                }
                return StartupPlan(actual: location,
                                   persistence: PersistencePlan(
                                       lastLocation: update,
                                       needsReconcile: needsReconcile ? false : nil
                                   ),
                                   banner: banner,
                                   switchEnabled: true,
                                   needsReconcile: false)
            }
        }
    }
}

public struct DockMenuState: Sendable, Equatable {
    public var lavoroEnabled: Bool
    public var personaleEnabled: Bool
    public var checkmark: Location?

    public init(lavoroEnabled: Bool, personaleEnabled: Bool, checkmark: Location?) {
        self.lavoroEnabled = lavoroEnabled
        self.personaleEnabled = personaleEnabled
        self.checkmark = checkmark
    }
}

public enum DockMenuPlanner {
    public static func plan(actual: Location,
                            lastLocation: Location,
                            isTransitioning: Bool,
                            personaleGateDisabled: Bool) -> DockMenuState {
        let validLocation: (Location) -> Bool = { $0 == .lavoro || $0 == .personale }
        let current: Location? = {
            if validLocation(actual) { return actual }
            if actual == .nowhere, validLocation(lastLocation) { return lastLocation }
            return nil
        }()

        if actual == .unknown {
            return DockMenuState(lavoroEnabled: false, personaleEnabled: false, checkmark: nil)
        }
        if isTransitioning {
            return DockMenuState(lavoroEnabled: false, personaleEnabled: false, checkmark: current)
        }

        let personaleEnabled = !personaleGateDisabled
        switch actual {
        case .lavoro:
            return DockMenuState(lavoroEnabled: true, personaleEnabled: personaleEnabled, checkmark: .lavoro)
        case .personale:
            return DockMenuState(lavoroEnabled: true, personaleEnabled: personaleEnabled, checkmark: .personale)
        case .nowhere:
            return DockMenuState(lavoroEnabled: true, personaleEnabled: personaleEnabled, checkmark: current)
        case .unknown:
            return DockMenuState(lavoroEnabled: false, personaleEnabled: false, checkmark: nil)
        }
    }
}
