import Foundation

/// Finds the shared App Group container.
/// Sideloading tools (SideStore/AltStore) can rename app groups and bundle IDs when they re-sign
/// with a free Apple ID, so the ID is discovered at run time instead of being hard-coded.
enum AppGroup {
    static let declared = "group.com.samuelmontagut.lexi"

    /// Candidate group IDs, most specific first.
    static var candidates: [String] {
        var out: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        if let alt = info["ALTAppGroups"] as? [String] { out += alt }          // written by AltStore/SideStore
        if let mine = info["LexiAppGroup"] as? String { out.append(mine) }
        if let id = mainAppBundleID {
            out.append("group.\(id)")
        }
        out.append(declared)
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Bundle ID of the containing app (the widget extension's ID minus its last component).
    static var mainAppBundleID: String? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return id.split(separator: ".").dropLast().joined(separator: ".")
        }
        return id
    }

    static let identifier: String? = candidates.first {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    }

    /// Shared container, or the app's own Application Support folder when no group is available
    /// (simulator without entitlements, unit tests). In that case widgets cannot see app data.
    static let containerURL: URL = {
        if let id = identifier, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return url
        }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lexi", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var isShared: Bool { identifier != nil }

    static let defaults: UserDefaults = identifier.flatMap(UserDefaults.init(suiteName:)) ?? .standard
}
