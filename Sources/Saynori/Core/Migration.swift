import Foundation
import ServiceManagement

/// One-time move from the app's old name (TypeLikeMe, `com.typelikeme.app`) to Saynori. Settings, history,
/// Dictionary, API keys, downloaded models and the log all come along; nothing is deleted that wasn't moved.
enum Migration {
    private static let oldBundleID = "com.typelikeme.app"
    private static let oldName = "TypeLikeMe"

    static func run() {
        // Only the installed app migrates (build helpers and dev runs must not move files under a running app).
        guard Bundle.main.bundleIdentifier == "com.saynori.app" else { return }
        let fm = FileManager.default
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "migratedFromTypeLikeMe") {
            // Settings live in the old app's preferences domain; copy any we don't have yet.
            if let old = defaults.persistentDomain(forName: oldBundleID) {
                for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
            }
            defaults.set(true, forKey: "migratedFromTypeLikeMe")
        }
        // The installer noticed the old app was a login item: register this one in its place.
        if defaults.bool(forKey: "restoreLaunchAtLogin") {
            defaults.removeObject(forKey: "restoreLaunchAtLogin")
            try? SMAppService.mainApp.register()
        }

        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        merge(support.appendingPathComponent(oldName), into: support.appendingPathComponent("Saynori"))

        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        let oldLog = logs.appendingPathComponent("\(oldName).log"), newLog = logs.appendingPathComponent("Saynori.log")
        if fm.fileExists(atPath: oldLog.path), !fm.fileExists(atPath: newLog.path) { try? fm.moveItem(at: oldLog, to: newLog) }
    }

    /// Moves the old folder over, or (if both exist) moves across only what the new one is missing.
    private static func merge(_ old: URL, into new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        guard fm.fileExists(atPath: new.path) else {
            try? fm.moveItem(at: old, to: new)
            return
        }
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] {
            let target = new.appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: old.appendingPathComponent(name), to: target) }
        }
        if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? ["?"]).filter({ $0 != ".DS_Store" }).isEmpty {
            try? fm.removeItem(at: old)
        }
    }
}
