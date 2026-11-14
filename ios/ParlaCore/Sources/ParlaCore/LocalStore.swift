import Foundation
import Security

/// Small key-value store for settings.
public protocol Prefs: AnyObject {
    func string(_ key: String) -> String?
    func setString(_ key: String, _ value: String?)
    func bool(_ key: String, _ fallback: Bool) -> Bool
    func setBool(_ key: String, _ value: Bool)
}

/// UserDefaults for ordinary values; the login token is kept in the Keychain.
public final class DevicePrefs: Prefs {
    private let defaults: UserDefaults
    private let service = "de.mirranet.parla"
    private static let secretKeys: Set<String> = ["token"]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(_ key: String) -> String? {
        Self.secretKeys.contains(key) ? keychainRead(key) : defaults.string(forKey: key)
    }

    public func setString(_ key: String, _ value: String?) {
        if Self.secretKeys.contains(key) {
            keychainWrite(key, value)
        } else if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    public func setBool(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: key)
    }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    private func keychainRead(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(_ key: String, _ value: String?) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// In-memory preferences, for tests.
public final class MemoryPrefs: Prefs {
    private var values: [String: Any] = [:]
    public init() {}
    public func string(_ key: String) -> String? { values[key] as? String }
    public func setString(_ key: String, _ value: String?) { values[key] = value }
    public func bool(_ key: String, _ fallback: Bool) -> Bool { values[key] as? Bool ?? fallback }
    public func setBool(_ key: String, _ value: Bool) { values[key] = value }
}

/// On-device cache: downloaded courses, last known progress, settings and the queue of events not yet
/// uploaded (same files as shared/data/LocalStore.kt). Files are written atomically.
public final class LocalStore {
    private let prefs: Prefs
    private let root: URL
    private let coursesDir: URL
    private let defaultServerUrl: String
    private let lock = NSLock()

    public init(prefs: Prefs, root: URL, defaultServerUrl: String) {
        self.prefs = prefs
        self.root = root
        self.coursesDir = root.appendingPathComponent("courses", isDirectory: true)
        self.defaultServerUrl = defaultServerUrl
        try? FileManager.default.createDirectory(at: coursesDir, withIntermediateDirectories: true)
    }

    /// Application Support/Parla, excluded from iCloud backup (everything there can be downloaded again).
    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var dir = base.appendingPathComponent("Parla", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    public var serverUrl: String {
        get { prefs.string("server_url") ?? defaultServerUrl }
        set {
            var v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            while v.hasSuffix("/") { v.removeLast() }
            prefs.setString("server_url", v)
        }
    }

    public var token: String? {
        get { prefs.string("token") }
        set { prefs.setString("token", newValue) }
    }

    public var username: String? {
        get { prefs.string("username") }
        set { prefs.setString("username", newValue) }
    }

    /// Device-only accessibility option: larger text.
    public var largeText: Bool {
        get { prefs.bool("large_text", false) }
        set { prefs.setBool("large_text", newValue) }
    }

    /// Settings changed while offline and not yet sent to the server.
    public var settingsDirty: Bool {
        get { prefs.bool("settings_dirty", false) }
        set { prefs.setBool("settings_dirty", newValue) }
    }

    // ------------------------------------------------------------------ courses

    public func courseList() -> (hash: String, list: [Codec.CourseInfo])? {
        guard let text = read("courses.json") else { return nil }
        return try? Codec.parseCourseList(text)
    }

    public func saveCourseList(hash: String, list: [Codec.CourseInfo]) {
        write(root.appendingPathComponent("courses.json"), Codec.courseListJson(hash: hash, list: list))
    }

    public func courseText(_ id: String) -> String? {
        try? String(contentsOf: coursesDir.appendingPathComponent("\(id).json"), encoding: .utf8)
    }

    public func saveCourse(_ id: String, _ text: String) {
        write(coursesDir.appendingPathComponent("\(id).json"), text)
    }

    public func deleteCourse(_ id: String) {
        try? FileManager.default.removeItem(at: coursesDir.appendingPathComponent("\(id).json"))
    }

    // ------------------------------------------------------------------ progress + queue

    public func serverProgress() -> LearnerProgress {
        guard let text = read("progress.json"), let p = try? Codec.parseProgress(text) else { return LearnerProgress() }
        return p
    }

    public func saveServerProgress(_ p: LearnerProgress) {
        write(root.appendingPathComponent("progress.json"), Codec.progressJson(p))
    }

    public func pending() -> [LearnEvent] {
        guard let text = read("pending.json") else { return [] }
        return (try? Codec.parseEvents(text)) ?? []
    }

    public func savePending(_ list: [LearnEvent]) {
        write(root.appendingPathComponent("pending.json"), Codec.eventsJson(list))
    }

    public func settings() -> Codec.Settings {
        guard let text = read("settings.json"), let s = try? Codec.parseSettings(text) else { return Codec.Settings() }
        return s
    }

    public func saveSettings(_ s: Codec.Settings) {
        write(root.appendingPathComponent("settings.json"), Codec.settingsJson(s))
    }

    /// Removes everything tied to the account (courses stay cached – they are not personal).
    public func clearAccount() {
        prefs.setString("token", nil)
        prefs.setString("username", nil)
        prefs.setBool("settings_dirty", false)
        for name in ["progress.json", "pending.json", "settings.json"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private func write(_ url: URL, _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}
