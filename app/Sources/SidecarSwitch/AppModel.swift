import AppKit
import SidecarSwitchCore
import SwiftUI

typealias OpenURL = (URL) -> Bool

@MainActor
final class AppModel: ObservableObject {
    struct Banner: Identifiable, Equatable {
        enum Kind: Equatable {
            case info
            case warning
            case error
        }

        let id = UUID()
        var kind: Kind
        var message: String
    }

    @Published private(set) var actual: Location
    @Published private(set) var phase: TransitionState = .idle
    @Published private(set) var isTransitioning = false
    @Published private(set) var needsReconcile: Bool
    @Published var banner: Banner?
    @Published var settings: SwitchSettings
    @Published var diagnostics: String?
    @Published var showForceConfirm = false
    @Published var showForgetHostKeyConfirm = false
    @Published private(set) var toolsReady = false

    let supportDirectory: URL
    let logURL: URL
    let configURL: URL
    let bundledToolsVersion: String
    let logger: SwitchLogger
    let store: SettingsStore
    let paths: AppPaths

    private let gate: ToggleGate
    private let resourcesDirectory: URL?
    private let openURL: OpenURL
    private let operationsFactory: ((SwitchSettings) -> any SidecarOperations)?
    private let timingsOverride: Timings?
    var dockIconController: DockIconController?
    private var cachedOperations: SystemOperations?
    private var cachedOperationsKey: OperationsCacheKey?
    private var hotkeyManager: HotkeyManager?
    private var canPersist: Bool

    init(
        paths: AppPaths = .system,
        logURL: URL? = nil,
        resourcesDirectory: URL? = Bundle.main.resourceURL,
        bundledToolsVersion: String? = AppPaths.bundledToolsVersion(),
        opener: OpenURL? = nil,
        operationsFactory: ((SwitchSettings) -> any SidecarOperations)? = nil,
        timings: Timings? = nil,
        dockIconController: DockIconController? = nil
    ) {
        self.paths = paths
        self.supportDirectory = paths.supportDirectory
        self.logURL = logURL ?? paths.logFileURL
        self.configURL = paths.configURL
        self.resourcesDirectory = resourcesDirectory
        self.bundledToolsVersion = bundledToolsVersion ?? "dev"
        self.logger = SwitchLogger(fileURL: self.logURL)
        self.store = SettingsStore(directory: paths.supportDirectory, home: paths.home)
        self.openURL = opener ?? { NSWorkspace.shared.open($0) }
        self.operationsFactory = operationsFactory
        self.timingsOverride = timings
        self.dockIconController = dockIconController

        let loaded = store.load()
        self.settings = loaded.settings
        self.actual = .unknown
        self.needsReconcile = loaded.settings.needsReconcile
        self.canPersist = !loaded.corrupt
        self.gate = ToggleGate(logging: logger)

        if let warning = loaded.warning {
            self.banner = Banner(kind: .warning, message: warning)
        }
        logger.log(.info, "avvio SidecarSwitch TOOLS_VERSION=\(self.bundledToolsVersion)")
    }

    var currentToolsVersion: String { bundledToolsVersion }

    var personaleGateDisabled: Bool { settings.personaleGateDisabled }

    func start() async {
        bootstrapTools()
        await refreshActual(showBannerOnChange: true)
        dockIconController?.showRest(holder: actual.holder)
        installHotkey()
        logger.log(.info, "stato iniziale actual=\(actual.rawValue) needsReconcile=\(needsReconcile)")
    }

    private func bootstrapTools() {
        guard let resourcesDirectory, let bundled = AppPaths.bundledToolsVersion(resources: resourcesDirectory) else {
            logger.log(.error, "bundle incompleto: Resources o TOOLS_VERSION mancanti")
            banner = Banner(kind: .error, message: "Bundle incompleto: impossibile installare i tool.")
            return
        }
        do {
            let bootstrap = BundleBootstrap(
                resourcesDirectory: resourcesDirectory,
                supportDirectory: supportDirectory,
                toolsVersion: bundled
            )
            try bootstrap.synchronize()
            toolsReady = true
            logger.log(.info, "tool pronti in \(bootstrap.toolsDirectory.path)")
        } catch {
            logger.log(.error, "bootstrap tool fallito: \(error)")
            banner = Banner(kind: .error, message: "Tool non installati: \(error)")
        }
    }

    func prepareForTermination() async {
        await gate.cancelCurrent()
        let idle = await gate.waitForIdle(timeout: .seconds(185))
        if !idle {
            settings.needsReconcile = true
            needsReconcile = true
            persistIfAllowed()
            logger.log(.warning, "quit: transizione non conclusa entro il budget, needsReconcile=true")
        }
        hotkeyManager?.removeHandler()
        logger.log(.info, "quit")
    }

    func toggle(_ target: SwitchHost) {
        guard !isTransitioning else { return }
        if target == .personale && personaleGateDisabled {
            banner = Banner(kind: .warning, message: "Configura config.json")
            return
        }
        let identifier = UUID()
        let snapshot = settings
        let machine = StateMachine(
            ops: transitionOperations(snapshot),
            timings: timings(for: snapshot),
            sleeper: RealSleeper(),
            deviceName: snapshot.device.name,
            logging: logger,
            observer: { [weak self] state in
                Task { @MainActor in
                    self?.phase = state
                }
            }
        )

        let from = actual.holder
        isTransitioning = true
        dockIconController?.beginTransition(from: from)
        banner = nil
        logger.log(.info, "[\(identifier.uuidString.prefix(8))] toggle UI -> \(target.rawValue)")
        let gateDisabled = personaleGateDisabled

        Task {
            let outcome = await gate.run(transitionID: identifier) { token in
                await machine.toggle(target: target, transitionID: identifier, token: token,
                                     personaleGateDisabled: gateDisabled)
            }
            handle(outcome)
        }
    }

    func reconcile(_ target: SwitchHost) {
        guard !isTransitioning else { return }
        if target == .personale && personaleGateDisabled {
            banner = Banner(kind: .warning, message: "Configura config.json")
            return
        }
        let identifier = UUID()
        let snapshot = settings
        let machine = StateMachine(
            ops: transitionOperations(snapshot),
            timings: timings(for: snapshot),
            sleeper: RealSleeper(),
            deviceName: snapshot.device.name,
            logging: logger
        )
        let from = actual.holder
        isTransitioning = true
        dockIconController?.beginTransition(from: from)
        banner = nil
        let gateDisabled = personaleGateDisabled
        Task {
            let outcome = await gate.run(transitionID: identifier) { token in
                await machine.reconcile(target: target, transitionID: identifier, token: token,
                                        personaleGateDisabled: gateDisabled)
            }
            handle(outcome)
        }
    }

    func forceConnectLavoro() {
        guard !isTransitioning else { return }
        let identifier = UUID()
        let snapshot = settings
        let machine = StateMachine(
            ops: transitionOperations(snapshot),
            timings: timings(for: snapshot),
            sleeper: RealSleeper(),
            deviceName: snapshot.device.name,
            logging: logger
        )
        let from = actual.holder
        isTransitioning = true
        dockIconController?.beginTransition(from: from)
        banner = nil
        Task {
            let outcome = await gate.run(transitionID: identifier) { token in
                await machine.forceConnectLavoro(transitionID: identifier, token: token)
            }
            handle(outcome)
        }
    }

    func retry() {
        Task {
            await refreshActual(showBannerOnChange: false)
            if actual == .unknown {
                banner = Banner(kind: .warning, message: "Stato ancora sconosciuto: usa Diagnostica.")
            }
        }
    }

    func handleHotkey() {
        guard !isTransitioning else {
            banner = Banner(kind: .info, message: "Transizione in corso: hotkey ignorata.")
            return
        }
        guard let target = HotkeyDirection.target(actual: actual, lastLocation: settings.lastLocation,
                                                  personaleDisabled: personaleGateDisabled) else {
            banner = Banner(kind: .warning, message: "Stato sconosciuto: hotkey disabilitata.")
            return
        }
        if target == .personale && personaleGateDisabled {
            banner = Banner(kind: .warning, message: "Configura config.json")
            return
        }
        toggle(target)
    }

    func openLog() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: logURL.path) {
            logger.log(.info, "apertura log richiesta")
        }
        if !NSWorkspace.shared.open(logURL) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        }
    }

    func openConfig() {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            do {
                let defaults = SwitchSettings.default
                try store.save(defaults)
                settings = defaults
                needsReconcile = false
                canPersist = true
                invalidateOperationsCache()
                installHotkey()
            } catch {
                banner = Banner(kind: .error, message: "Impossibile creare config.json: \(error)")
                return
            }
        }
        if !openURL(configURL) {
            banner = Banner(kind: .warning, message: "Impossibile aprire \(configURL.path)")
        }
    }

    @discardableResult
    func reloadConfig() -> Bool {
        guard !isTransitioning else {
            banner = Banner(kind: .warning, message: "Ricarica config rifiutata: transizione in corso.")
            logger.log(.warning, "reload config rifiutato: transizione in corso")
            return false
        }

        let loaded = store.load()
        if loaded.corrupt {
            banner = Banner(kind: .error, message: loaded.warning ?? "config.json non valido: \(configURL.path)")
            logger.log(.warning, "reload config rifiutato: file non valido preservato")
            return false
        }

        settings = loaded.settings
        canPersist = true
        needsReconcile = loaded.settings.needsReconcile
        invalidateOperationsCache()
        installHotkey()
        let warnings = loaded.settings.validationWarnings()
        banner = Banner(kind: warnings.isEmpty ? .info : .warning,
                        message: warnings.isEmpty ? "Config ricaricata." : warnings.joined(separator: "; "))
        logger.log(.info, "config ricaricata, hotkey ri-registrata")
        return true
    }

    func runDiagnostics() async {
        let ops = transitionOperations(settings)
        let local = await ops.probe(.lavoro, timeout: Timings.standard.probeTimeout)
        var lines: [String] = []
        lines.append("Lavoro connected: \(describe(local))")
        if personaleGateDisabled {
            lines.append("Personale connected: config.json non configurato (Personale disabilitato)")
            lines.append("Personale dispid: config.json non configurato")
        } else {
            let remote = await ops.probe(.personale, timeout: Timings.standard.remoteProbeTimeout)
            let remoteDisplays = await ops.displays(.personale, timeout: Timings.standard.remoteProbeTimeout)
            lines.append("Personale connected: \(describe(remote))")
            lines.append("Personale dispid: \(describe(displays: remoteDisplays))")
        }
        let localDisplays = await ops.displays(.lavoro, timeout: Timings.standard.probeTimeout)
        lines.append("Lavoro dispid: \(describe(displays: localDisplays))")
        diagnostics = lines.joined(separator: "\n")
    }

    func forgetHostKey() async {
        guard !settings.remote.host.isEmpty else {
            banner = Banner(kind: .warning, message: "Configura config.json")
            return
        }
        let operations = currentOperations()
        let ok = await operations.forgetHostKey()
        banner = Banner(kind: ok ? .info : .warning,
                        message: ok ? "Host key dimenticata." : "Impossibile dimenticare la host key.")
    }

    func handle(_ outcome: TransitionOutcome?) {
        isTransitioning = false
        guard let outcome else {
            dockIconController?.showRest(holder: actual.holder)
            return
        }
        let current = actual
        phase = outcome.state
        actual = OutcomeStateReducer.actual(after: outcome, current: current)
        apply(outcome.persistence)
        dockIconController?.finishTransition(outcome, current: current, needsReconcile: needsReconcile)
        if let message = outcome.message {
            banner = Banner(kind: bannerKind(for: outcome.state), message: message)
        } else if case .failed(_, let reason) = outcome.state {
            banner = Banner(kind: bannerKind(for: outcome.state), message: reason.displayMessage)
        }
        logger.log(.info, "esito \(outcome.state) actual=\(actual.rawValue) needsReconcile=\(needsReconcile)")
    }

    private func bannerKind(for state: TransitionState) -> Banner.Kind {
        switch OutcomePresentation.severity(for: state) {
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }

    private func apply(_ plan: PersistencePlan) {
        if case .set(let location) = plan.lastLocation {
            settings.lastLocation = location
        }
        if let value = plan.needsReconcile {
            settings.needsReconcile = value
            needsReconcile = value
        }
        persistIfAllowed()
    }

    private func persistIfAllowed() {
        guard canPersist else { return }
        do {
            try store.save(settings)
        } catch {
            logger.log(.warning, "persist config fallito: \(error)")
        }
    }

    private func remoteProbe(_ ops: any SidecarOperations) async -> ProbeReport {
        if personaleGateDisabled {
            return ProbeReport(state: .disconnected, detail: "config.json non configurato")
        }
        return await ops.probe(.personale, timeout: Timings.standard.remoteProbeTimeout)
    }

    private func refreshActual(showBannerOnChange: Bool) async {
        let ops = transitionOperations(settings)
        let local = await ops.probe(.lavoro, timeout: Timings.standard.probeTimeout)
        let remote = await remoteProbe(ops)
        let plan = StartupPlanner.plan(
            local: local.state,
            remote: remote.state,
            configuredName: settings.device.name,
            lastLocation: settings.lastLocation,
            needsReconcile: settings.needsReconcile
        )
        actual = plan.actual
        needsReconcile = plan.needsReconcile
        apply(plan.persistence)
        if !isTransitioning {
            dockIconController?.showRest(holder: actual.holder)
        }
        if showBannerOnChange {
            if personaleGateDisabled {
                banner = Banner(kind: .warning, message: "Configura config.json")
            } else if let message = plan.banner {
                banner = Banner(kind: plan.switchEnabled ? .info : .warning, message: message)
            }
        }
    }

    private func timings(for settings: SwitchSettings) -> Timings {
        var timings = timingsOverride ?? Timings.standard
        timings.sshConnectTimeout = .seconds(settings.ssh.connectTimeout)
        return timings
    }

    private func transitionOperations(_ snapshot: SwitchSettings) -> any SidecarOperations {
        if let operationsFactory { return operationsFactory(snapshot) }
        return currentOperations()
    }

    private func currentOperations() -> SystemOperations {
        let local = LocalToolPaths.standard(toolsDirectory: paths.toolsDirectory.path)
        let key = OperationsCacheKey(settings: settings, toolsVersion: bundledToolsVersion, local: local)
        if let cachedOperations, cachedOperationsKey == key {
            return cachedOperations
        }
        let config = OperationsConfig(
            deviceName: settings.device.name,
            local: local,
            remote: settings.remote,
            ssh: settings.ssh,
            knownHostsDirectory: paths.knownHostsDirectory.path,
            legacyKnownHostsPath: paths.legacyKnownHostsPath,
            home: paths.home,
            toolsVersion: bundledToolsVersion,
            timings: timings(for: settings)
        )
        let operations = SystemOperations(config: config, runner: SystemCommandRunner(), logging: logger)
        cachedOperations = operations
        cachedOperationsKey = key
        return operations
    }

    private func invalidateOperationsCache() {
        cachedOperations = nil
        cachedOperationsKey = nil
    }

    private func installHotkey() {
        let manager = hotkeyManager ?? HotkeyManager()
        hotkeyManager = manager
        manager.installCallback { [weak self] in
            self?.handleHotkey()
        }
        logger.log(.info, "ri-registrazione hotkey keyCode=\(settings.hotkey.keyCode)")
        let status = manager.register(
            keyCode: UInt32(settings.hotkey.keyCode),
            modifiers: HotkeyManager.carbonModifiers(settings.hotkey.modifiers)
        )
        if status == noErr {
            logger.log(.info, "hotkey registrata keyCode=\(settings.hotkey.keyCode) modifiers=\(settings.hotkey.modifiers)")
        } else if status == HotkeyManager.hotKeyExistsError {
            logger.log(.warning, "hotkey già usata da un'altra applicazione (err \(status))")
            banner = Banner(kind: .warning, message: "Hotkey già occupata da un'altra app.")
        } else {
            logger.log(.warning, "registrazione hotkey fallita (err \(status))")
        }
    }

    private func describe(_ report: ProbeReport) -> String {
        switch report.state {
        case .connected(let devices):
            return "connected \(devices.joined(separator: ", "))"
        case .disconnected:
            return "disconnected"
        case .unknown:
            return "unknown\(report.detail.map { " (\($0))" } ?? "")"
        case .unreachable:
            return "unreachable\(report.reason.map { " (\($0.rawValue))" } ?? "")"
        }
    }

    private func describe(displays: DisplaysReport) -> String {
        switch displays.status {
        case .ok:
            return displays.displays.map { display in
                "vendor=0x\(String(display.vendor, radix: 16)) builtin=\(display.builtin) active=\(display.active) asleep=\(display.asleep) mirror_of=\(display.mirrors)"
            }.joined(separator: " | ")
        case .transport(let reason):
            return "errore (\(reason.rawValue))"
        default:
            return "errore"
        }
    }
}
