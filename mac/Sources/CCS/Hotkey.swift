// A system-wide shortcut that opens the panel. Carbon's RegisterEventHotKey is
// still the way to do this without asking for Accessibility access.
import AppKit
import Carbon

struct Shortcut: Hashable {
    let label: String
    let keyCode: UInt32
    let modifiers: UInt32

    /// The modifiers as AppKit sees them, to tell when they're let go.
    var flags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        return f
    }

    static let presets: [Shortcut] = [
        Shortcut(label: "⌘1", keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey)),
        Shortcut(label: "⌃⌥C", keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey)),
        Shortcut(label: "⌃⌥⌘C", keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey | cmdKey)),
        Shortcut(label: "⌃⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
        Shortcut(label: "⌥⌘J", keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey | cmdKey)),
    ]
}

final class Hotkey {
    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(_ action: @escaping () -> Void) {
        Hotkey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Hotkey.action?()
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Registers `shortcut`, replacing the previous one. nil turns it off.
    /// Returns false if another app already holds that combination.
    @discardableResult
    func set(_ shortcut: Shortcut?) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let shortcut else { return true }
        let id = EventHotKeyID(signature: OSType(0x4343_5321), id: 1) // "CCS!"
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}
