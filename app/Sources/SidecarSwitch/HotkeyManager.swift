import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var callback: (() -> Void)?
    private let signature: OSType = 0x53435357
    static let hotKeyExistsError = OSStatus(-9878)

    func installCallback(_ callback: @escaping () -> Void) {
        self.callback = callback
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, pointer, &handlerRef)
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        unregister()
        let identifier = EventHotKeyID(signature: signature, id: 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        if status == noErr {
            hotKeyRef = reference
        }
        return status
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    func removeHandler() {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    fileprivate func dispatch() {
        callback?()
    }

    static func carbonModifiers(_ names: [String]) -> UInt32 {
        var value: UInt32 = 0
        if names.contains("control") { value |= UInt32(controlKey) }
        if names.contains("option") { value |= UInt32(optionKey) }
        if names.contains("command") { value |= UInt32(cmdKey) }
        if names.contains("shift") { value |= UInt32(shiftKey) }
        return value
    }
}

private func hotKeyEventHandler(
    _ call: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.dispatch()
    }
    return noErr
}
