import AppKit
import SidecarSwitchCore
import SwiftUI

@main
struct SidecarSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("SidecarSwitch") {
            RootView(model: delegate.model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 340, height: 190)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model: AppModel
    private var singleInstance: SingleInstance?
    private var terminationPending = false

    override init() {
        self.model = AppModel()
        super.init()
    }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let instance = SingleInstance(directory: model.supportDirectory)
        singleInstance = instance
        switch instance.acquire() {
        case .acquired:
            break
        case .alreadyRunning(let pid):
            if let running = NSRunningApplication(processIdentifier: pid) {
                running.activate()
            }
            NSApp.terminate(nil)
        case .failed(let message):
            model.banner = AppModel.Banner(kind: .warning, message: message)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        Task { await model.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isTransitioning else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        singleInstance?.release()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        makeDockMenu()
    }

    func makeDockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let lavoro = NSMenuItem(title: "Passa a Lavoro", action: #selector(dockSwitch(_:)), keyEquivalent: "")
        lavoro.target = self
        lavoro.representedObject = Host.lavoro.rawValue
        let personale = NSMenuItem(title: "Passa a Personale", action: #selector(dockSwitch(_:)), keyEquivalent: "")
        personale.target = self
        personale.representedObject = Host.personale.rawValue
        menu.addItem(lavoro)
        menu.addItem(personale)
        updateDockMenu(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateDockMenu(menu)
    }

    private func updateDockMenu(_ menu: NSMenu) {
        let state = DockMenuPlanner.plan(
            actual: model.actual,
            lastLocation: model.settings.lastLocation,
            isTransitioning: model.isTransitioning,
            personaleGateDisabled: model.personaleGateDisabled
        )
        for item in menu.items {
            guard let raw = item.representedObject as? String, let host = Host(rawValue: raw) else { continue }
            switch host {
            case .lavoro:
                item.isEnabled = state.lavoroEnabled
                item.state = state.checkmark == .lavoro ? .on : .off
            case .personale:
                item.isEnabled = state.personaleEnabled
                item.state = state.checkmark == .personale ? .on : .off
            }
        }
    }

    @objc func dockSwitch(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let host = Host(rawValue: raw) else { return }
        model.toggle(host)
    }
}
