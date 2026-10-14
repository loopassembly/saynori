import AppKit
import ServiceManagement

/// Live view of everything the app needs from macOS, refreshed while the dashboard is open.
final class Permissions: ObservableObject {
    @Published var mic = AudioRecorder.hasPermission
    @Published var accessibility = TextInserter.isTrusted
    @Published var fnUsage = Permissions.readFnUsage()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { timer?.invalidate() }

    func refresh() {
        let m = AudioRecorder.hasPermission, a = TextInserter.isTrusted, f = Self.readFnUsage()
        if m != mic { mic = m }
        if a != accessibility { accessibility = a }
        if f != fnUsage { fnUsage = f }
    }

    /// 0 = Do Nothing, 1 = Change Input Source, 2 = Emoji & Symbols, 3 = Start Dictation.
    static func readFnUsage() -> Int {
        if let get = FnUsage.get { return Int(get()) }
        return (CFPreferencesCopyValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString,
                                       kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Int) ?? 2
    }

    var fnReady: Bool { fnUsage == 0 || AppSettings.shared.trigger != .fn }
    var allGood: Bool { mic && accessibility && fnReady && AppSettings.shared.engineReady }

    func requestMic() {
        if AVAuthorizationStatusIsDenied() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        } else {
            AudioRecorder.requestPermission { [weak self] _ in self?.refresh() }
        }
    }

    func requestAccessibility() {
        TextInserter.promptForAccessibility()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Sets "Press 🌐 key to: Do Nothing" the way System Settings does, so it applies immediately.
    func fixFnKey() {
        FnUsage.setDoNothing(force: true)
        refresh()
        if fnUsage != 0 { open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension") }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Saynori launch-at-login: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

import AVFoundation
private func AVAuthorizationStatusIsDenied() -> Bool {
    let s = AVCaptureDevice.authorizationStatus(for: .audio)
    return s == .denied || s == .restricted
}

/// macOS keeps the globe-key action cached inside TextInputSwitcher (a protected process), so writing
/// the preference file isn't enough — the emoji picker keeps opening until logout. HIToolbox's
/// `TISUpdateFnUsageType` is what System Settings calls: it saves the value and tells every input
/// process to drop its cached copy.
enum FnUsage {
    private typealias Get = @convention(c) () -> Int32
    private typealias Update = @convention(c) (Int32) -> Int32

    private static let lib = dlopen("/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox", RTLD_NOW)
    fileprivate static let get: (() -> Int32)? = dlsym(lib, "TISGetFnUsageType").map { unsafeBitCast($0, to: Get.self) }
    private static let update: ((Int32) -> Int32)? = dlsym(lib, "TISUpdateFnUsageType").map { unsafeBitCast($0, to: Update.self) }

    /// `force` flips the value once so the change is broadcast even when the stored value is already 0.
    static func setDoNothing(force: Bool) {
        guard let update, let get else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            p.arguments = ["write", "com.apple.HIToolbox", "AppleFnUsageType", "-int", "0"]
            try? p.run()
            p.waitUntilExit()
            return
        }
        if get() == 0 && !force { return }
        if force && get() == 0 { _ = update(2) }
        let status = update(0)
        Log.write("fn usage set to Do Nothing via TIS (status \(status), now \(get()))")
    }
}
