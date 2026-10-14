import AppKit
import ApplicationServices

/// Marker stored on keystrokes Saynori posts itself.
let syntheticTag: Int64 = 0x544C4D

/// Puts text at the user's cursor in whatever app is focused by briefly borrowing
/// the clipboard and synthesising ⌘V, then restoring the previous clipboard.
enum TextInserter {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func insert(_ text: String) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)
        // Hint to clipboard managers that this is transient.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pb.changeCount

        sendKey(9, flags: .maskCommand) // V

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Only restore if nobody else touched the clipboard in the meantime.
            guard pb.changeCount == ourChange else { return }
            restore(saved, to: pb)
        }
    }

    /// Copies the current selection (⌘C) and returns it, restoring the clipboard afterwards.
    static func copySelection() async -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        sendKey(8, flags: .maskCommand) // C
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if pb.changeCount != before { break }
        }
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string)
        restore(saved, to: pb)
        return (text?.isEmpty ?? true) ? nil : text
    }

    private static func sendKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        // Ignore physically-held modifiers (like the trigger key) so they don't leak into ⌘V.
        src?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        // Tag our own keystrokes so the hotkey listener can tell them from the user's.
        down?.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        up?.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var dict = [NSPasteboard.PasteboardType: Data]()
            for t in item.types { if let d = item.data(forType: t) { dict[t] = d } }
            return dict
        }
    }

    private static func restore(_ snap: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        guard !snap.isEmpty else { return }
        let items = snap.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            return item
        }
        pb.writeObjects(items)
    }
}
