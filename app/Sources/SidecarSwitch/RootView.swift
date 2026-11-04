import SidecarSwitchCore
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switcher
            statusLine
            bannerView
            configLine
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(width: 340, height: 190, alignment: .topLeading)
        .sheet(item: Binding(
            get: { model.diagnostics.map(DiagnosticsPayload.init) },
            set: { if $0 == nil { model.diagnostics = nil } }
        )) { payload in
            DiagnosticsView(text: payload.text) { model.diagnostics = nil }
        }
        .alert("Connettere il Mac di lavoro?", isPresented: $model.showForceConfirm) {
            Button("Annulla", role: .cancel) {}
            Button("Connetti Lavoro") { model.forceConnectLavoro() }
        } message: {
            Text("Operazione di emergenza: solo connect, nessun disconnect. Usala quando lo stato è sconosciuto.")
        }
        .alert("Dimenticare la host key SSH?", isPresented: $model.showForgetHostKeyConfirm) {
            Button("Annulla", role: .cancel) {}
            Button("Dimentica", role: .destructive) {
                Task { await model.forgetHostKey() }
            }
        } message: {
            Text("La prossima connessione riaccetterà la chiave dell'host con accept-new.")
        }
    }

    private var header: some View {
        HStack {
            Text("Sidecar Switch")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
    }

    private var switcher: some View {
        HStack(spacing: 0) {
            segment(for: .lavoro)
            segment(for: .personale)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)))
    }

    private func segment(for host: SwitchHost) -> some View {
        let selected = model.actual == host.location
        let gateDisabled = host == .personale && model.personaleGateDisabled
        return Button {
            model.toggle(host)
        } label: {
            Text(host.displayName)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.10))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(model.isTransitioning || model.actual == .unknown || gateDisabled)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
        }
    }

    private var bannerView: some View {
        Group {
            if let banner = model.banner {
                Text(banner.message)
                    .font(.system(size: 10))
                    .foregroundStyle(bannerColor(banner.kind))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var configLine: some View {
        HStack(spacing: 6) {
            Text(model.configURL.path)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Apri config") { model.openConfig() }
                .font(.system(size: 10))
            Button("Ricarica config") { _ = model.reloadConfig() }
                .font(.system(size: 10))
                .disabled(model.isTransitioning)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button("Apri log") { model.openLog() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))

                Button("Diagnostica") {
                    Task { await model.runDiagnostics() }
                }
                .buttonStyle(.link)
                .font(.system(size: 10))

                Button("Dimentica host key") {
                    model.showForgetHostKeyConfirm = true
                }
                .buttonStyle(.link)
                .font(.system(size: 10))

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                if model.needsReconcile {
                    Button("Riconcilia") {
                        model.reconcile(model.actual.holder?.host ?? .lavoro)
                    }
                    .font(.system(size: 10))
                    .disabled(model.isTransitioning)
                }

                if model.actual == .unknown || model.phase.isFailure {
                    Button("Riprova") { model.retry() }
                        .font(.system(size: 10))
                        .disabled(model.isTransitioning)
                }

                if model.actual == .unknown {
                    Button("Forza su Lavoro") { model.showForceConfirm = true }
                        .font(.system(size: 10))
                        .disabled(model.isTransitioning)
                }
            }
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .failed(_, .incoherent), .failed(_, .foreignDevice):
            return .red
        case .failed:
            return .orange
        case .done:
            return .green
        default:
            if model.actual == .unknown { return .gray }
            return .green
        }
    }

    private var statusText: String {
        if model.isTransitioning {
            switch model.phase {
            case .probing, .idle: return "Sonda in corso…"
            case .preflight: return "Pre-flight…"
            case .disconnectingSource(let holder): return "Rilascio \(holder.location.displayName)…"
            case .connectingTarget(let host, let attempt): return "Connessione \(host.displayName) (tentativo \(attempt))…"
            case .verifyingTarget(let host, let display): return display ? "Verifica display \(host.displayName)…" : "Verifica \(host.displayName)…"
            case .hardening(let host): return "Layout \(host.displayName)…"
            case .rollingBack(let holder): return "Ripristino \(holder.location.displayName)…"
            case .done(let host): return "Sessione su \(host.displayName)"
            case .failed: return "Errore"
            }
        }
        switch model.actual {
        case .lavoro: return "Sessione su Lavoro (display esteso)"
        case .personale: return "Sessione su Personale"
        case .nowhere: return "Nessuna sessione attiva"
        case .unknown: return "Sconosciuto — nessuna azione eseguita"
        }
    }

    private func bannerColor(_ kind: AppModel.Banner.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct DiagnosticsPayload: Identifiable {
    let text: String
    var id: String { text }
}

private struct DiagnosticsView: View {
    let text: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostica (sola lettura)").font(.headline)
            ScrollView {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Chiudi", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(width: 460, height: 300)
    }
}
