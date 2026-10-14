import AppKit
import SwiftUI

/// "Record…" button: the next key you press (a lone modifier, a function key, or a shortcut
/// like ⌥Space) becomes the dictation key.
struct TriggerRecorder: View {
    @ObservedObject var settings: AppSettings
    @State private var monitor: Any?
    @State private var heldModifier: UInt16?
    @State private var error: String?

    var body: some View {
        HStack(spacing: 8) {
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.yellow) }
            Button(settings.recordingTrigger ? "Press a key…" : "Record…") {
                settings.recordingTrigger ? stop() : start()
            }
            .buttonStyle(ActionButtonStyle(prominent: settings.recordingTrigger))
            .help("Press any key or shortcut to use it for dictation. esc cancels.")
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        error = nil
        heldModifier = nil
        settings.recordingTrigger = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        heldModifier = nil
        if settings.recordingTrigger { settings.recordingTrigger = false }
    }

    private func handle(_ event: NSEvent) {
        let code = event.keyCode
        if event.type == .flagsChanged {
            guard let flag = TriggerKey.modifierFlag(code) else { return }
            let down = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).contains(flag)
            if down {
                heldModifier = code
            } else if heldModifier == code {
                // Pressed and released on its own: the modifier itself is the trigger.
                accept(TriggerKey(keyCode: code, short: Self.modifierName(code)))
            }
            return
        }
        // keyDown
        let mods = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).intersection(TriggerKey.comboMask)
        if code == 53, mods.isEmpty { stop(); return }  // esc cancels
        if code == 57 { error = "Caps Lock can't be held"; return }
        let named = Self.keyNames[code]
        if !Self.bareKeys.contains(code), mods.isEmpty || mods == .maskShift {
            error = "Add ⌘, ⌥ or ⌃ so typing still works"
            return
        }
        if code == 9, mods == [.maskCommand, .maskControl] { error = "⌃⌘V is paste-last"; return }
        let key = named ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        accept(TriggerKey(keyCode: code, modifiers: mods.rawValue, short: Self.symbols(mods) + key))
    }

    private func accept(_ t: TriggerKey) {
        settings.trigger = t
        error = nil
        stop()
    }

    static func symbols(_ m: CGEventFlags) -> String {
        (m.contains(.maskControl) ? "⌃" : "") + (m.contains(.maskAlternate) ? "⌥" : "")
            + (m.contains(.maskShift) ? "⇧" : "") + (m.contains(.maskCommand) ? "⌘" : "")
    }

    static func modifierName(_ code: UInt16) -> String {
        switch code {
        case 63: return "fn"
        case 56: return "left ⇧"
        case 60: return "right ⇧"
        case 58: return "left ⌥"
        case 61: return "right ⌥"
        case 55: return "left ⌘"
        case 54: return "right ⌘"
        case 59: return "left ⌃"
        case 62: return "right ⌃"
        default: return "key \(code)"
        }
    }

    /// Function keys type nothing, so they can be used without a modifier; everything else needs ⌘, ⌥ or ⌃.
    static let bareKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90, 114]

    static let keyNames: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "⌦", 115: "Home", 119: "End",
        116: "Page Up", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑", 114: "Help",
    ]
}
