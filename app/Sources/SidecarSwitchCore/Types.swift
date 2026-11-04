import Foundation

public enum Host: String, Sendable, Codable, CaseIterable, Hashable {
    case lavoro
    case personale

    public var displayName: String {
        switch self {
        case .lavoro: return "Lavoro"
        case .personale: return "Personale"
        }
    }

    public var other: Host { self == .lavoro ? .personale : .lavoro }

    public var location: Location {
        switch self {
        case .lavoro: return .lavoro
        case .personale: return .personale
        }
    }
}

public enum Location: String, Sendable, Codable, CaseIterable, Hashable {
    case lavoro
    case personale
    case nowhere
    case unknown

    public var displayName: String {
        switch self {
        case .lavoro: return "Lavoro"
        case .personale: return "Personale"
        case .nowhere: return "Nessuno"
        case .unknown: return "Sconosciuto"
        }
    }

    public var holder: Holder? { Holder(location: self) }
}

public enum Holder: String, Sendable, Codable, CaseIterable, Hashable {
    case lavoro
    case personale

    public var host: Host {
        switch self {
        case .lavoro: return .lavoro
        case .personale: return .personale
        }
    }

    public var location: Location {
        switch self {
        case .lavoro: return .lavoro
        case .personale: return .personale
        }
    }

    public var displayName: String { location.displayName }

    public init?(location: Location) {
        switch location {
        case .lavoro: self = .lavoro
        case .personale: self = .personale
        case .nowhere, .unknown: return nil
        }
    }
}

public enum ProbeState: Sendable, Equatable, Hashable {
    case connected(devices: [String])
    case disconnected
    case unknown
    case unreachable

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public enum ClassifiedProbe: Sendable, Equatable, Hashable {
    case connectediPad
    case foreignDevice
    case tooMany
    case disconnected
    case unknown
    case unreachable
}

public enum VerifyOutcome: Sendable, Equatable, Hashable {
    case connected
    case disconnected
    case displayUnverified
    case unknown
}

public enum Reason: String, Sendable, Equatable, Hashable, CaseIterable {
    case targetUnreachable
    case cannotRelease
    case localPrivateAPI
    case deviceNotFound
    case foreignDevice
    case unknownHolder
    case preflightRemote
    case preflightRemoteVdispMissing
    case localLidClosed
    case targetFailed
    case targetFailedRolledBack
    case targetUnknown
    case displayUnverified
    case incoherent
    case stateChanged
    case remoteBootstrap
    case remoteCrashed
    case authFailed
    case hostKeyMismatch
    case cancelled

    public var displayMessage: String {
        switch self {
        case .targetUnreachable: return "Mac personale non raggiungibile — controlla VPN/rete/tunnel. config SSH o proxy/CA non applicati? controlla VPN/rete"
        case .cannotRelease: return "Impossibile rilasciare la sessione sull'host di origine."
        case .localPrivateAPI: return "La private API Sidecar non risponde sul Mac di lavoro."
        case .deviceNotFound: return "iPad non presente nella lista dei device."
        case .foreignDevice: return "Un altro device detiene la sessione."
        case .unknownHolder: return "Stato sconosciuto (private API rotta o Mac personale irraggiungibile). Nessuna azione eseguita."
        case .preflightRemote: return "Pre-flight remoto fallito: tool o device non disponibili sul Mac personale."
        case .preflightRemoteVdispMissing: return "Display virtuale 0x5644 assente sul Mac personale (LaunchAgent local.sidecar.vdisp)."
        case .localLidClosed: return "Coperchio chiuso o display integrato non rilevato sul Mac di lavoro."
        case .targetFailed: return "Connessione al target fallita."
        case .targetFailedRolledBack: return "Connessione al target fallita: sessione ripristinata."
        case .targetUnknown: return "Stato del target non determinabile: nessuna azione distruttiva eseguita."
        case .displayUnverified: return "Sessione connessa ma display non verificato."
        case .incoherent: return "Stato incoerente: serve una riconciliazione manuale."
        case .stateChanged: return "Stato cambiato durante la transizione: nessuna azione eseguita."
        case .remoteBootstrap: return "Tool remoti non installati o non arm64 sul Mac personale: esegui tools/build.sh (o chmod 755)."
        case .remoteCrashed: return "Il comando remoto è terminato per segnale."
        case .authFailed: return "Autenticazione SSH fallita: verifica la chiave dedicata."
        case .hostKeyMismatch: return "Host key SSH non corrispondente: nessuna modifica automatica."
        case .cancelled: return "Annullato."
        }
    }
}

public enum TransitionState: Sendable, Equatable {
    case idle
    case probing
    case preflight
    case disconnectingSource(Holder)
    case connectingTarget(Holder, attempt: Int)
    case verifyingTarget(Holder, display: Bool)
    case hardening(Holder)
    case rollingBack(Holder)
    case done(Holder)
    case failed(Location?, Reason)
}

public enum Action: Sendable, Equatable {
    case noop(Holder)
    case abort(Reason)
    case disconnectThenConnect(source: Holder, target: Holder)
    case connectOnly(target: Holder)
    case incoherent
}

public enum Resolution: Sendable, Equatable {
    case location(Location)
    case incoherent

    public var location: Location? {
        if case .location(let value) = self { return value }
        return nil
    }
}

public enum LocationUpdate: Sendable, Equatable {
    case unchanged
    case set(Location)
}

public struct PersistencePlan: Sendable, Equatable {
    public var lastLocation: LocationUpdate
    public var needsReconcile: Bool?

    public init(lastLocation: LocationUpdate = .unchanged, needsReconcile: Bool? = nil) {
        self.lastLocation = lastLocation
        self.needsReconcile = needsReconcile
    }

    public static let unchanged = PersistencePlan()

    public static func success(_ location: Location) -> PersistencePlan {
        PersistencePlan(lastLocation: .set(location), needsReconcile: false)
    }
}

public struct TransitionOutcome: Sendable, Equatable {
    public var state: TransitionState
    public var persistence: PersistencePlan
    public var message: String?
    public var actual: Location?

    public init(state: TransitionState, persistence: PersistencePlan, message: String? = nil, actual: Location? = nil) {
        self.state = state
        self.persistence = persistence
        self.message = message
        self.actual = actual
    }

    public var succeeded: Bool {
        if case .done = state { return true }
        return false
    }

    public func replacing(reason: Reason, message: String? = nil) -> TransitionOutcome {
        guard case .failed(let location, _) = state else { return self }
        return TransitionOutcome(state: .failed(location, reason), persistence: persistence, message: message ?? self.message, actual: actual)
    }
}

public enum CommandStatus: Sendable, Equatable {
    case ok
    case exited(Int32)
    case crashed(signal: Int32)
    case timedOut
    case launchFailed(String)
    case transport(Reason)

    public var isOK: Bool { self == .ok }
}

public struct CommandReport: Sendable, Equatable {
    public var status: CommandStatus
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32?

    public init(status: CommandStatus, stdout: String = "", stderr: String = "", exitCode: Int32? = nil) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public struct ProbeReport: Sendable, Equatable {
    public var state: ProbeState
    public var reason: Reason?
    public var detail: String?

    public init(state: ProbeState, reason: Reason? = nil, detail: String? = nil) {
        self.state = state
        self.reason = reason
        self.detail = detail
    }
}

public struct DevicesReport: Sendable, Equatable {
    public var status: CommandStatus
    public var names: [String]
    public var report: CommandReport

    public init(status: CommandStatus, names: [String], report: CommandReport) {
        self.status = status
        self.names = names
        self.report = report
    }
}

public struct DisplayInfo: Sendable, Equatable, Hashable {
    public var id: UInt32
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var builtin: Bool
    public var main: Bool
    public var active: Bool
    public var mirrors: UInt32
    public var asleep: Bool
    public var width: Int
    public var height: Int

    public init(id: UInt32, vendor: UInt32, model: UInt32 = 0, serial: UInt32 = 0,
                builtin: Bool = false, main: Bool = false, active: Bool = false,
                mirrors: UInt32 = 0, asleep: Bool = false, width: Int = 0, height: Int = 0) {
        self.id = id
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.builtin = builtin
        self.main = main
        self.active = active
        self.mirrors = mirrors
        self.asleep = asleep
        self.width = width
        self.height = height
    }
}

public struct DisplaysReport: Sendable, Equatable {
    public var status: CommandStatus
    public var displays: [DisplayInfo]
    public var report: CommandReport

    public init(status: CommandStatus, displays: [DisplayInfo], report: CommandReport) {
        self.status = status
        self.displays = displays
        self.report = report
    }
}

public struct CommandOutcome: Sendable, Equatable {
    public var status: CommandStatus
    public var report: CommandReport

    public init(status: CommandStatus, report: CommandReport) {
        self.status = status
        self.report = report
    }
}

public enum HardenOutcome: Sendable, Equatable {
    case ok
    case warning(String)
    case unsupported(String)
}

public extension TransitionState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
