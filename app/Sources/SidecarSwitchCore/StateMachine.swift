import Foundation

public struct StateMachine: Sendable {
    public var ops: any SidecarOperations
    public var timings: Timings
    public var sleeper: any Sleeping
    public var deviceName: String
    public var logging: any SwitchLogging
    public var observer: (@Sendable (TransitionState) -> Void)?
    public var nonceProvider: any NonceProviding

    public init(
        ops: any SidecarOperations,
        timings: Timings = .standard,
        sleeper: any Sleeping = RealSleeper(),
        deviceName: String = "iPad",
        logging: any SwitchLogging = NoopLogging(),
        nonceProvider: any NonceProviding = SystemNonceProvider(),
        observer: (@Sendable (TransitionState) -> Void)? = nil
    ) {
        self.ops = ops
        self.timings = timings
        self.sleeper = sleeper
        self.deviceName = deviceName
        self.logging = logging
        self.nonceProvider = nonceProvider
        self.observer = observer
    }

    private enum ConnectResult: Equatable {
        case ok
        case degraded
        case exhausted
        case insufficientBudget
        case transportFailure(Reason)
    }

    public func toggle(target: Host, transitionID: UUID, token: CancellationToken,
                       personaleGateDisabled: Bool = false) async -> TransitionOutcome {
        log(.info, transitionID, "toggle verso \(target.rawValue) gate=\(personaleGateDisabled)")
        emit(.probing)

        if personaleGateDisabled && target == .personale {
            return finish(failed(nil, .targetUnreachable, .unchanged, false))
        }

        let deadline = Deadline(after: timings.transitionDeadline)
        let session = await ops.beginRemoteSession()
        let scope = RemoteSessionScope(ops: ops, session: session)
        let outcome = await toggleBody(target: target, transitionID: transitionID, token: token,
                                       personaleGateDisabled: personaleGateDisabled,
                                       deadline: deadline, scope: scope)
        await scope.close()
        return outcome
    }

    private func toggleBody(target: Host, transitionID: UUID, token: CancellationToken,
                            personaleGateDisabled: Bool, deadline: Deadline,
                            scope: RemoteSessionScope) async -> TransitionOutcome {
        let localReport = await ops.probe(.lavoro, timeout: timings.probeTimeout)
        let remoteReport = personaleGateDisabled
            ? ProbeReport(state: .disconnected, detail: "config.json non configurato")
            : await ops.probe(.personale, timeout: timings.remoteProbeTimeout, session: scope.current)

        if token.isCancelled {
            return finish(failed(nil, .cancelled, .unchanged, nil, message: "Annullato."))
        }

        let local = classify(localReport)
        let remote = classify(remoteReport)
        log(.info, transitionID, "probe local=\(local) remote=\(remote)")

        if local == .foreignDevice || remote == .foreignDevice {
            return finish(failed(nil, .foreignDevice, .unchanged, nil))
        }
        if local == .tooMany || remote == .tooMany {
            return finish(failed(nil, .incoherent, .unchanged, true))
        }

        let resolution = Classifier.resolve(local: local, remote: remote)
        guard case .location(let actual) = resolution else {
            return finish(failed(nil, .incoherent, .unchanged, true))
        }
        if actual == .unknown {
            return finish(failed(nil, .unknownHolder, .unchanged, nil,
                                 message: Reason.unknownHolder.displayMessage))
        }

        if target == .lavoro && actual == .lavoro {
            await harden(target, transitionID: transitionID, session: scope.current)
            return finish(TransitionOutcome(state: .done(holder(target)), persistence: .success(.lavoro),
                                            message: "Sessione già su Lavoro.", actual: .lavoro))
        }
        if target == .personale && actual == .personale {
            await harden(target, transitionID: transitionID, session: scope.current)
            return finish(TransitionOutcome(state: .done(holder(target)), persistence: .success(.personale),
                                            message: "Sessione già su Personale.", actual: .personale))
        }

        let source = actual.holder

        if token.isCancelled {
            return finish(cancelledBeforeRelease(actual: actual))
        }

        emit(.preflight)
        if let reason = await preflight(target: target, localReport: localReport, remoteReport: remoteReport,
                                        local: local, remote: remote, deadline: deadline,
                                        transitionID: transitionID, session: scope.current) {
            return finish(failed(source?.location, reason,
                                 source.map { LocationUpdate.set($0.location) } ?? .unchanged,
                                 false))
        }

        if token.isCancelled {
            return finish(cancelledBeforeRelease(actual: actual))
        }

        if let source {
            let secondReport = await ops.probe(source.host, timeout: timings.probeTimeout(for: source.host),
                                               session: source.host == .personale ? scope.current : nil)
            let second = classify(secondReport)
            let initial = source == .lavoro ? local : remote
            if second != initial || second == .unknown || second == .unreachable {
                return finish(failed(actual, .stateChanged, .unchanged, nil))
            }
        }

        var settleConsumed: Duration = .zero
        if let source {
            emit(.disconnectingSource(source))
            if let reason = await release(source: source, deadline: deadline, transitionID: transitionID,
                                          session: scope.current) {
                return finish(failed(source.location, reason, .set(source.location), false))
            }
            if source == .personale && target == .lavoro {
                await scope.close()
            }
            let postDisconnect = min(timings.postDisconnectSettle, min(timings.settleBudget, deadline.remaining))
            if postDisconnect > .zero {
                await sleeper.sleep(postDisconnect)
                settleConsumed = postDisconnect
            }
        }

        if token.isCancelled {
            if let source {
                let rolledBack = await rollback(source: source, transitionID: transitionID, token: token, scope: scope)
                return finish(rolledBack.replacing(
                    reason: .cancelled,
                    message: "Annullato: sessione ripristinata su \(source.location.displayName)."
                ))
            }
            return finish(failed(.nowhere, .cancelled, .set(.nowhere), false, message: "Annullato."))
        }

        await settleRecheck(target, deadline: deadline, transitionID: transitionID, consumed: settleConsumed,
                            session: scope.current)

        if token.isCancelled {
            if let source {
                let rolledBack = await rollback(source: source, transitionID: transitionID, token: token, scope: scope)
                return finish(rolledBack.replacing(
                    reason: .cancelled,
                    message: "Annullato: sessione ripristinata su \(source.location.displayName)."
                ))
            }
            return finish(failed(.nowhere, .cancelled, .set(.nowhere), false, message: "Annullato."))
        }

        emit(.connectingTarget(holder(target), attempt: 1))
        let connectResult = await connectWithRetry(target, deadline: deadline, transitionID: transitionID,
                                                   session: scope.current)
        var connectFailure: Reason?
        switch connectResult {
        case .insufficientBudget:
            connectFailure = .targetUnknown
            log(.error, transitionID, "budget esaurito prima del connect: verifico comunque il target")
        case .transportFailure(let reason):
            connectFailure = reason
            log(.warning, transitionID, "trasporto fallito dopo il release: verifico comunque il target")
        case .ok, .degraded, .exhausted:
            break
        }

        if token.isCancelled {
            let post = await verify(target, transitionID: transitionID, session: scope.current)
            if post.outcome == .connected {
                let location: Location = target == .lavoro ? .lavoro : .personale
                return finish(TransitionOutcome(state: .done(holder(target)), persistence: .success(location),
                                                message: "Annullato: sessione già su \(target.displayName).",
                                                actual: location))
            }
            if let source {
                let rolledBack = await rollback(source: source, transitionID: transitionID, token: token, scope: scope)
                return finish(rolledBack.replacing(reason: .cancelled,
                                                   message: "Annullato: sessione ripristinata su \(source.location.displayName)."))
            }
            return finish(failed(.nowhere, .cancelled, .set(.nowhere), false, message: "Annullato."))
        }

        let post = await verify(target, transitionID: transitionID, session: scope.current)
        switch post.outcome {
        case .connected:
            if connectResult != .ok {
                log(.warning, transitionID, "connect riportava errore ma la sessione è attiva")
            }
            if token.isCancelled {
                let location: Location = target == .lavoro ? .lavoro : .personale
                return finish(TransitionOutcome(state: .done(holder(target)), persistence: .success(location),
                                                message: "Annullato: sessione già su \(target.displayName).",
                                                actual: location))
            }
            await harden(target, transitionID: transitionID, skipArrange: post.sidecarMirroringVirtual,
                         session: scope.current)
            let location: Location = target == .lavoro ? .lavoro : .personale
            return finish(TransitionOutcome(state: .done(holder(target)), persistence: .success(location),
                                            message: "Sessione su \(target.displayName).", actual: location))
        case .disconnected:
            guard let source else {
                return finish(failed(.nowhere, connectFailure ?? .targetFailed, .set(.nowhere), false,
                                     message: connectFailure?.displayMessage))
            }
            return finish(await rollback(source: source, transitionID: transitionID, token: token, scope: scope))
        case .displayUnverified:
            return finish(failed(actual, .displayUnverified, .unchanged, true))
        case .unknown:
            return finish(failed(actual, .targetUnknown, .unchanged, true))
        }
    }

    public func reconcile(target: Host, transitionID: UUID, token: CancellationToken,
                          personaleGateDisabled: Bool = false) async -> TransitionOutcome {
        let deadline = Deadline(after: timings.transitionDeadline)
        log(.info, transitionID, "reconcile verso \(target.rawValue) gate=\(personaleGateDisabled)")
        emit(.probing)

        if personaleGateDisabled && target == .personale {
            return finish(failed(nil, .targetUnreachable, .unchanged, false))
        }

        _ = await ops.disconnect(.lavoro, device: deviceName,
                                 timeout: deadline.capped(timings.disconnectCommandTimeout))
        if !personaleGateDisabled {
            _ = await ops.disconnect(.personale, device: deviceName,
                                     timeout: deadline.capped(timings.disconnectCommandTimeout))
        }

        let session = await ops.beginRemoteSession()
        let scope = RemoteSessionScope(ops: ops, session: session)
        let outcome = await reconcileBody(target: target, transitionID: transitionID, token: token,
                                          personaleGateDisabled: personaleGateDisabled,
                                          deadline: deadline, scope: scope)
        await scope.close()
        return outcome
    }

    private func reconcileBody(target: Host, transitionID: UUID, token: CancellationToken,
                               personaleGateDisabled: Bool, deadline: Deadline,
                               scope: RemoteSessionScope) async -> TransitionOutcome {
        let localReport = await ops.probe(.lavoro, timeout: timings.probeTimeout)
        let remoteReport = personaleGateDisabled
            ? ProbeReport(state: .disconnected)
            : await ops.probe(.personale, timeout: timings.remoteProbeTimeout, session: scope.current)
        let resolution = Classifier.resolve(local: classify(localReport), remote: classify(remoteReport))
        let actual: Location = resolution.location ?? .unknown

        if token.isCancelled {
            return finish(failed(actual, .cancelled, .set(actual), false, message: "Annullato."))
        }

        emit(.connectingTarget(holder(target), attempt: 1))
        _ = await connectWithRetry(target, deadline: deadline, transitionID: transitionID,
                                   session: scope.current)

        let post = await verify(target, transitionID: transitionID, session: scope.current)
        if post.outcome == .connected {
            await harden(target, transitionID: transitionID, session: scope.current)
            let location: Location = target == .lavoro ? .lavoro : .personale
            return finish(TransitionOutcome(state: .done(holder(target)), persistence: .success(location),
                                            message: "Riconciliato: sessione su \(target.displayName).",
                                            actual: location))
        }
        let reason: Reason = post.outcome == .displayUnverified ? .displayUnverified : .targetUnknown
        return finish(failed(actual, reason, .unchanged, true))
    }

    public func forceConnectLavoro(transitionID: UUID, token: CancellationToken) async -> TransitionOutcome {
        let deadline = Deadline(after: timings.transitionDeadline)
        log(.warning, transitionID, "force connect Lavoro (confermato dalla UI)")
        emit(.probing)

        let localReport = await ops.probe(.lavoro, timeout: timings.probeTimeout)
        if token.isCancelled {
            return finish(failed(nil, .cancelled, .unchanged, nil, message: "Annullato."))
        }
        if localReport.state == .unknown {
            return finish(failed(nil, .localPrivateAPI, .unchanged, nil))
        }

        emit(.preflight)
        if let reason = await localPreflight(deadline: deadline) {
            return finish(failed(nil, reason, .unchanged, nil))
        }

        emit(.connectingTarget(.lavoro, attempt: 1))
        _ = await connectWithRetry(.lavoro, deadline: deadline, transitionID: transitionID, session: nil)
        let post = await verify(.lavoro, transitionID: transitionID, session: nil)
        if post.outcome == .connected {
            await harden(.lavoro, transitionID: transitionID)
            return finish(TransitionOutcome(state: .done(.lavoro), persistence: .success(.lavoro),
                                            message: "Connesso a Lavoro (forzato).", actual: .lavoro))
        }
        let reason: Reason = post.outcome == .displayUnverified ? .displayUnverified : .targetUnknown
        return finish(failed(nil, reason, .unchanged, nil))
    }

    private func preflight(
        target: Host,
        localReport: ProbeReport,
        remoteReport: ProbeReport,
        local: ClassifiedProbe,
        remote: ClassifiedProbe,
        deadline: Deadline,
        transitionID: UUID,
        session: RemoteSession?
    ) async -> Reason? {
        switch target {
        case .personale:
            if remoteReport.state == .unreachable {
                return remoteReport.reason ?? .targetUnreachable
            }
            if remoteReport.state == .unknown {
                return .targetUnreachable
            }
            return await remotePrereqs(deadline: deadline, transitionID: transitionID, session: session)
        case .lavoro:
            if localReport.state == .unknown {
                return .localPrivateAPI
            }
            return await localPreflight(deadline: deadline)
        }
    }

    private func localPreflight(deadline: Deadline) async -> Reason? {
        let devices = await ops.devices(.lavoro, timeout: deadline.capped(timings.probeTimeout))
        switch devices.status {
        case .ok:
            break
        case .exited(4), .crashed, .launchFailed:
            return .localPrivateAPI
        default:
            return .deviceNotFound
        }
        if !Classifier.deviceMatches(devices.names, configuredName: deviceName) {
            return .deviceNotFound
        }

        let displays = await ops.displays(.lavoro, timeout: deadline.capped(timings.probeTimeout))
        switch displays.status {
        case .ok:
            if !DisplayRule.hasBuiltin(displays.displays) { return .localLidClosed }
        default:
            return .localLidClosed
        }
        return nil
    }

    private func remotePrereqs(deadline: Deadline, transitionID: UUID,
                               session: RemoteSession?) async -> Reason? {
        await ops.beginRemoteGroup(.prereqs)
        let result = await remotePrereqsBody(deadline: deadline, transitionID: transitionID, session: session)
        await ops.endRemoteGroup(.prereqs)
        return result
    }

    private func remotePrereqsBody(deadline: Deadline, transitionID: UUID,
                                   session: RemoteSession?) async -> Reason? {
        let batch = await ops.remoteBatch(
            .prereqs,
            nonce: nonceProvider.makeNonce(),
            settle: .zero,
            timeout: deadline.capped(timings.remoteProbeTimeout),
            session: session
        )
        switch batch {
        case .transport(let reason):
            return reason
        case .parseFailed(let error):
            log(.warning, transitionID, "preflight batch non valido, fallback separato: \(error)")
            return await remotePrereqsSeparate(deadline, session: session)
        case .sections(let sections):
            guard sections.count == 2,
                  sections[0].section == "devices",
                  sections[1].section == "dispid" else {
                log(.warning, transitionID, "preflight batch incompleto, fallback separato")
                return await remotePrereqsSeparate(deadline, session: session)
            }
            return classifyPrereqsSections(devices: sections[0], dispid: sections[1])
        }
    }

    private func classifyPrereqsSections(devices section: RemoteSectionResult,
                                         dispid dispidSection: RemoteSectionResult) -> Reason? {
        let devices = BatchClassification.devices(section)
        switch devices.status {
        case .ok:
            if !Classifier.deviceMatches(devices.names, configuredName: deviceName) {
                return .preflightRemote
            }
        case .transport(let reason):
            return reason
        case .exited(126), .exited(127):
            return .remoteBootstrap
        case .timedOut, .crashed, .launchFailed, .exited(_):
            return .preflightRemote
        }

        let displays = BatchClassification.displays(dispidSection)
        switch displays.status {
        case .ok:
            return DisplayRule.hasVirtual(displays.displays) ? nil : .preflightRemoteVdispMissing
        case .transport(let reason):
            return reason
        case .exited(126), .exited(127):
            return .remoteBootstrap
        case .timedOut, .crashed, .launchFailed, .exited(_):
            return .preflightRemoteVdispMissing
        }
    }

    private func remotePrereqsSeparate(_ deadline: Deadline, session: RemoteSession?) async -> Reason? {
        let devices = await ops.devices(.personale, timeout: deadline.capped(timings.remoteProbeTimeout),
                                        session: session)
        switch devices.status {
        case .ok:
            if !Classifier.deviceMatches(devices.names, configuredName: deviceName) {
                return .preflightRemote
            }
        case .transport(let reason):
            return reason
        case .exited(126), .exited(127):
            return .remoteBootstrap
        case .timedOut, .crashed, .launchFailed, .exited(_):
            return .preflightRemote
        }

        let displays = await ops.displays(.personale, timeout: deadline.capped(timings.remoteProbeTimeout),
                                          session: session)
        switch displays.status {
        case .ok:
            return DisplayRule.hasVirtual(displays.displays) ? nil : .preflightRemoteVdispMissing
        case .transport(let reason):
            return reason
        case .exited(126), .exited(127):
            return .remoteBootstrap
        case .timedOut, .crashed, .launchFailed, .exited(_):
            return .preflightRemoteVdispMissing
        }
    }

    private func release(source: Holder, deadline: Deadline, transitionID: UUID,
                         session: RemoteSession?) async -> Reason? {
        let session = source.host == .personale ? session : nil
        var attempt = 0
        while attempt < 2 {
            let outcome = await ops.disconnect(source.host, device: deviceName,
                                               timeout: deadline.capped(timings.disconnectCommandTimeout),
                                               session: session)
            switch outcome.status {
            case .ok:
                return await pollUntilDisconnected(source, session: session) ? nil : .cannotRelease
            case .exited(3):
                return .deviceNotFound
            case .exited(4), .exited(2):
                let report = await ops.probe(source.host, timeout: timings.probeTimeout(for: source.host), session: session)
                if classify(report) == .disconnected { return nil }
                attempt += 1
                continue
            case .exited(let code):
                let report = await ops.probe(source.host, timeout: timings.probeTimeout(for: source.host), session: session)
                if classify(report) == .disconnected { return nil }
                log(.error, transitionID, "disconnect exit \(code): source non rilasciato")
                return .cannotRelease
            case .crashed(let signal):
                let report = await ops.probe(source.host, timeout: timings.probeTimeout(for: source.host), session: session)
                if classify(report) == .disconnected { return nil }
                log(.error, transitionID, "disconnect terminato da segnale \(signal)")
                return source.host == .lavoro ? .localPrivateAPI : .remoteCrashed
            case .timedOut:
                let report = await ops.probe(source.host, timeout: timings.probeTimeout(for: source.host), session: session)
                if classify(report) == .disconnected { return nil }
                return .cannotRelease
            case .launchFailed:
                return .cannotRelease
            case .transport(let reason):
                return releaseReason(reason)
            }
        }
        return .cannotRelease
    }

    private func releaseReason(_ reason: Reason) -> Reason {
        switch reason {
        case .targetUnreachable, .incoherent, .targetUnknown, .targetFailed, .stateChanged, .cancelled:
            return .cannotRelease
        default:
            return reason
        }
    }

    private func pollUntilDisconnected(_ source: Holder, session: RemoteSession?) async -> Bool {
        let attempts = max(1, timings.disconnectPollAttempts)
        for index in 0..<attempts {
            let report = await ops.probe(source.host, timeout: timings.probeTimeout(for: source.host), session: session)
            if classify(report) == .disconnected { return true }
            if index + 1 < attempts {
                await sleeper.sleep(timings.disconnectPollInterval)
            }
        }
        return false
    }

    private func connectWithRetry(_ host: Host, deadline: Deadline, transitionID: UUID,
                                  session: RemoteSession?) async -> ConnectResult {
        let session = host == .personale ? session : nil
        var attempt = 1
        while true {
            if deadline.remaining < timings.connectCommandTimeout {
                log(.error, transitionID, "budget insufficiente per connect su \(host.rawValue)")
                return .insufficientBudget
            }
            emit(.connectingTarget(holder(host), attempt: attempt))
            let outcome = await ops.connect(host, device: deviceName,
                                            timeout: deadline.capped(timings.connectCommandTimeout),
                                            session: session)
            let transientExit4 = ExitCodes.connectExit4IsTransient(stderr: outcome.report.stderr + "\n" + outcome.report.stdout)
            switch outcome.status {
            case .ok:
                return .ok
            case .exited(2), .exited(3):
                if attempt >= timings.connectAttempts { return .exhausted }
                await settleRecheck(host, deadline: deadline, transitionID: transitionID, consumed: .zero,
                                    session: session)
                attempt += 1
                await sleeper.sleep(timings.retryBackoff)
            case .exited(4) where transientExit4:
                if attempt >= timings.connectAttempts { return .exhausted }
                await settleRecheck(host, deadline: deadline, transitionID: transitionID, consumed: .zero,
                                    session: session)
                attempt += 1
                await sleeper.sleep(timings.retryBackoff)
            case .exited(4), .exited(1), .exited(_):
                return .degraded
            case .crashed, .timedOut, .launchFailed:
                return .degraded
            case .transport(let reason):
                return reason == .remoteCrashed ? .degraded : .transportFailure(reason)
            }

            if deadline.remaining < timings.sshConnectTimeout + timings.connectRetryMargin {
                log(.warning, transitionID, "budget insufficiente per un secondo tentativo su \(host.rawValue)")
                return .exhausted
            }
        }
    }

    private func settleRecheck(_ host: Host, deadline: Deadline, transitionID: UUID,
                               consumed: Duration, session: RemoteSession?) async {
        let session = host == .personale ? session : nil
        let allowance = timings.settleBudget - consumed
        let budget = min(allowance > .zero ? allowance : .zero, deadline.remaining)
        guard budget > .zero else {
            log(.warning, transitionID, "settle-poll saltato: budget/deadline esaurito su \(host.rawValue)")
            return
        }
        let settleDeadline = Deadline(after: budget)
        let attempts = max(1, timings.settlePollAttempts)
        for index in 0..<attempts {
            let remaining = settleDeadline.remaining
            if remaining <= .zero { break }
            let timeout = min(timings.remoteProbeTimeout, min(remaining, timings.settleBudget))
            let report = await ops.devices(host, timeout: timeout, retry: false, session: session)
            if report.status == .ok, Classifier.deviceMatches(report.names, configuredName: deviceName) {
                return
            }
            if index < timings.settlePollBackoffs.count {
                let backoff = min(timings.settlePollBackoffs[index], settleDeadline.remaining)
                if backoff > .zero {
                    await sleeper.sleep(backoff)
                }
            }
            if settleDeadline.isExpired { break }
        }
        log(.warning, transitionID, "settle-poll senza device su \(host.rawValue) entro \(budget.inSeconds)s")
    }

    private func verify(_ host: Host, transitionID: UUID, session: RemoteSession?) async -> VerifyReport {
        if host == .lavoro {
            return await verifySeparate(host, transitionID: transitionID, session: nil)
        }

        emit(.verifyingTarget(holder(host), display: false))
        let batch = await ops.remoteBatch(
            .verify,
            nonce: nonceProvider.makeNonce(),
            settle: timings.settle,
            timeout: timings.remoteProbeTimeout,
            session: session
        )
        switch batch {
        case .transport(let reason):
            log(.warning, transitionID, "verify batch: trasporto fallito (\(reason.rawValue)), nessun fallback")
            return VerifyReport(outcome: .unknown)
        case .parseFailed(let error):
            log(.warning, transitionID, "verify batch non valido, fallback separato: \(error)")
            return await verifySeparate(host, transitionID: transitionID, session: session)
        case .sections(let sections):
            guard sections.count == 3,
                  sections[0].section == "connected_a",
                  sections[1].section == "connected_b",
                  sections[2].section == "dispid" else {
                log(.warning, transitionID, "verify batch incompleto, fallback separato")
                return await verifySeparate(host, transitionID: transitionID, session: session)
            }
            return await verifyBatched(sections, host: host, transitionID: transitionID, session: session)
        }
    }

    private func verifyBatched(_ sections: [RemoteSectionResult], host: Host,
                               transitionID: UUID, session: RemoteSession?) async -> VerifyReport {
        let first = BatchClassification.probe(sections[0])
        let second = BatchClassification.probe(sections[1])
        let a = classify(first)
        let b = classify(second)
        if a == .disconnected && b == .disconnected { return VerifyReport(outcome: .disconnected) }
        guard a == .connectediPad && b == .connectediPad else {
            log(.warning, transitionID, "verify batch campioni incoerenti: \(a)/\(b)")
            return VerifyReport(outcome: .unknown)
        }

        emit(.verifyingTarget(holder(host), display: true))
        var last = BatchClassification.displays(sections[2])
        let start = ContinuousClock().now
        while true {
            if last.status == .ok, DisplayRule.hasLiveSidecar(last.displays) {
                return VerifyReport(outcome: .connected,
                                    sidecarMirroringVirtual: DisplayRule.isSidecarMirroringVirtual(last.displays))
            }
            await sleeper.sleep(timings.displayPollInterval)
            last = await ops.displays(host, timeout: timings.probeTimeout(for: host), session: session)
            if last.status == .ok, DisplayRule.hasLiveSidecar(last.displays) {
                return VerifyReport(outcome: .connected,
                                    sidecarMirroringVirtual: DisplayRule.isSidecarMirroringVirtual(last.displays))
            }
            if ContinuousClock().now - start >= timings.displayWait {
                return VerifyReport(outcome: .displayUnverified)
            }
        }
    }

    private func verifySeparate(_ host: Host, transitionID: UUID,
                                session: RemoteSession?) async -> VerifyReport {
        emit(.verifyingTarget(holder(host), display: false))
        let first = await ops.probe(host, timeout: timings.verifyProbeTimeout(for: host), session: session)
        await sleeper.sleep(timings.settle)
        let second = await ops.probe(host, timeout: timings.verifyProbeTimeout(for: host), session: session)
        let a = classify(first)
        let b = classify(second)
        if a == .disconnected && b == .disconnected { return VerifyReport(outcome: .disconnected) }
        guard a == .connectediPad && b == .connectediPad else {
            log(.warning, transitionID, "verify campioni incoerenti: \(a)/\(b)")
            return VerifyReport(outcome: .unknown)
        }

        emit(.verifyingTarget(holder(host), display: true))
        let start = ContinuousClock().now
        var iterations = 0
        while iterations < 1000 {
            iterations += 1
            let displays = await ops.displays(host, timeout: timings.probeTimeout(for: host), session: session)
            if displays.status == .ok, DisplayRule.hasLiveSidecar(displays.displays) {
                return VerifyReport(outcome: .connected,
                                    sidecarMirroringVirtual: DisplayRule.isSidecarMirroringVirtual(displays.displays))
            }
            if ContinuousClock().now - start >= timings.displayWait {
                return VerifyReport(outcome: .displayUnverified)
            }
            await sleeper.sleep(timings.displayPollInterval)
        }
        return VerifyReport(outcome: .displayUnverified)
    }

    private func rollback(source: Holder, transitionID: UUID, token: CancellationToken,
                          scope: RemoteSessionScope) async -> TransitionOutcome {
        emit(.rollingBack(source))
        if scope.current == nil {
            await scope.reopen()
        }
        let session = source.host == .personale ? scope.current : nil
        let budget = Deadline(after: timings.rollbackBudget)
        let probeTimeout = min(timings.remoteProbeTimeout, budget.remaining)
        let report = await ops.probe(source.host, timeout: probeTimeout, retry: false, session: session)
        let state = classify(report)

        if state == .connectediPad {
            let post = await verify(source.host, transitionID: transitionID, session: session)
            return await rollbackOutcome(post.outcome, source: source, transitionID: transitionID, session: session)
        }
        if state == .unknown || state == .unreachable || state == .foreignDevice || state == .tooMany {
            return failed(nil, .incoherent, .unchanged, true)
        }

        guard let connectBudget = timings.rollbackConnectBudget(remaining: budget.remaining, host: source.host) else {
            return failed(nil, .incoherent, .unchanged, true)
        }

        let connectDeadline = Deadline(after: connectBudget)
        _ = await connectWithRetry(source.host, deadline: connectDeadline, transitionID: transitionID,
                                   session: session)
        let post = await verify(source.host, transitionID: transitionID, session: session)
        return await rollbackOutcome(post.outcome, source: source, transitionID: transitionID, session: session)
    }

    private func rollbackOutcome(_ post: VerifyOutcome, source: Holder, transitionID: UUID,
                                 session: RemoteSession?) async -> TransitionOutcome {
        switch post {
        case .connected:
            await harden(source.host, transitionID: transitionID, session: session)
            return TransitionOutcome(state: .failed(source.location, .targetFailedRolledBack),
                                     persistence: PersistencePlan(lastLocation: .set(source.location), needsReconcile: false),
                                     message: "Connessione al target fallita: sessione ripristinata su \(source.location.displayName).",
                                     actual: source.location)
        case .displayUnverified:
            return failed(source.location, .displayUnverified, .set(source.location), true)
        case .disconnected, .unknown:
            return failed(nil, .incoherent, .unchanged, true)
        }
    }

    private func harden(_ host: Host, transitionID: UUID, skipArrange: Bool = false,
                        session: RemoteSession? = nil) async {
        if host == .lavoro {
            log(.info, transitionID, "harden Lavoro: no-op (layout esteso lasciato a macOS)")
            return
        }
        emit(.hardening(.personale))
        _ = await ops.harden(host, timeout: timings.hardeningTimeout, skipArrange: skipArrange, session: session)
    }

    private func cancelledBeforeRelease(actual: Location) -> TransitionOutcome {
        failed(actual, .cancelled, .set(actual), false, message: "Annullato.")
    }

    private func classify(_ report: ProbeReport) -> ClassifiedProbe {
        Classifier.classify(report.state, configuredName: deviceName)
    }

    private func holder(_ host: Host) -> Holder {
        host == .lavoro ? .lavoro : .personale
    }

    private func failed(
        _ location: Location?,
        _ reason: Reason,
        _ lastLocation: LocationUpdate = .unchanged,
        _ needsReconcile: Bool? = nil,
        message: String? = nil
    ) -> TransitionOutcome {
        let defaultMessage: String
        switch reason {
        case .targetFailedRolledBack:
            defaultMessage = "Connessione al target fallita: sessione ripristinata su \(location?.displayName ?? "?")."
        case .cancelled:
            defaultMessage = "Annullato."
        default:
            defaultMessage = reason.displayMessage
        }
        return TransitionOutcome(
            state: .failed(location, reason),
            persistence: PersistencePlan(lastLocation: lastLocation, needsReconcile: needsReconcile),
            message: message ?? defaultMessage,
            actual: location
        )
    }

    private func emit(_ state: TransitionState) {
        observer?(state)
    }

    private func finish(_ outcome: TransitionOutcome) -> TransitionOutcome {
        emit(outcome.state)
        return outcome
    }

    private func log(_ level: LogLevel, _ id: UUID, _ message: String) {
        logging.log(level, "[\(id.uuidString.prefix(8))] \(message)")
    }
}

private final class RemoteSessionScope: @unchecked Sendable {
    private let ops: any SidecarOperations
    private(set) var current: RemoteSession?
    private(set) var ended = false

    init(ops: any SidecarOperations, session: RemoteSession?) {
        self.ops = ops
        self.current = session
    }

    func close() async {
        guard !ended else { return }
        ended = true
        let session = current
        current = nil
        await ops.endRemoteSession(session)
    }

    func reopen() async {
        current = await ops.beginRemoteSession()
        ended = false
    }
}
