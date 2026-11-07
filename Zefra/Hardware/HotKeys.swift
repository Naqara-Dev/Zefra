import AppKit
import Carbon.HIToolbox

/// Keys that work whichever app is in front. Carbon's hot keys are still the way, and they need no
/// Accessibility permission, because they only ever see their own key.
@MainActor
final class HotKeys {
    enum Action: UInt32 { case showWindow = 1, toggleBoost, nextProfile }

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onAction: ((Action) -> Void)?
    private static let signature: OSType = 0x5A464B59 // "ZFKY"

    /// Replaces every key with these. Returns the actions whose key another app already holds.
    @discardableResult
    func set(_ keys: [Action: HotKey]) -> [Action] {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        installHandler()
        var taken: [Action] = []
        for (action, key) in keys {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: Self.signature, id: action.rawValue),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { taken.append(action) }
        }
        return taken
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let box = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            let raw = id.id
            MainActor.assumeIsolated {
                if let action = Action(rawValue: raw) { box.onAction?(action) }
            }
            return noErr
        }, 1, &type, me, &handler)
    }

    /// A key press as a hot key, or nil without a modifier: a bare letter would take over typing.
    static func hotKey(from event: NSEvent) -> HotKey? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty, flags != .shift else { return nil }
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        label += (event.charactersIgnoringModifiers ?? "?").uppercased()
        return HotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label)
    }
}
