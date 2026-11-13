import Carbon.HIToolbox
import Foundation

/// Modifier-only combos. Never F1/F2/F10-F12 or media keys: those must reach the system untouched.
enum HotKeyChoice: String, CaseIterable, Identifiable {
    case off
    case controlOptionCommandB
    case controlOptionCommandL
    case controlOptionCommandUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .controlOptionCommandB: return "⌃⌥⌘B"
        case .controlOptionCommandL: return "⌃⌥⌘L"
        case .controlOptionCommandUp: return "⌃⌥⌘↑"
        }
    }

    fileprivate var keyCode: UInt32? {
        switch self {
        case .off: return nil
        case .controlOptionCommandB: return UInt32(kVK_ANSI_B)
        case .controlOptionCommandL: return UInt32(kVK_ANSI_L)
        case .controlOptionCommandUp: return UInt32(kVK_UpArrow)
        }
    }
}

/// Carbon RegisterEventHotKey: delivers only our own combo. No CGEventTap, no IOHIDManager,
/// nothing else on the keyboard is observed or swallowed.
final class GlobalHotKey {
    private static let signature: OSType = 0x4D42_4C4E // "MBLN"
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    func apply(_ choice: HotKeyChoice) {
        unregister()
        guard let keyCode = choice.keyCode else { return }
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
