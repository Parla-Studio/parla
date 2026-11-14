import Combine
import Foundation
import os

/// Everything the UI shows.
public struct AppState: Equatable {
    public var loggedIn: Bool
    public var username: String?
    public var serverUrl: String
    /// Downloaded courses in the server's order.
    public var courses: [Course]
    /// Server progress with not-yet-uploaded events applied on top.
    public var progress: LearnerProgress
    public var settings: Codec.Settings
    public var pendingEvents: Int
    /// Device-only: larger text for easier reading.
    public var largeText: Bool = false
    public var syncing: Bool = false
    public var offline: Bool = false
    /// One-off message such as "new lessons available"; cleared by the UI.
    public var message: String?

    public var course: Course? { courses.first { $0.id == settings.course } }
}

/// Single source of truth for the app, the same as shared/data/Repository.kt: content always comes from the
/// server and is cached for offline use; on every sync the app compares content hashes and downloads only
/// courses that changed. Learning results are recorded locally first and uploaded as idempotent events.
@MainActor
public final class Repository: ObservableObject {
    @Published public private(set) var state: AppState

    private let store: LocalStore
    private let api: ApiClient
    private let device: String
    private let log = Logger(subsystem: "de.mirranet.parla", category: "sync")
    /// The sync running now (or last); new syncs wait for it, so syncs never overlap.
    private var lastSync: Task<Void, Never>?

    public init(store: LocalStore, device: String) {
        self.store = store
        self.device = String(device.prefix(100))
        self.api = ApiClient(baseUrl: { store.serverUrl }, token: { store.token })
        let courses = Repository.loadCachedCourses(store)
        let pending = store.pending()
        state = AppState(
            loggedIn: store.token != nil,
            username: store.username,
            serverUrl: store.serverUrl,
            courses: courses,
            progress: Repository.fold(store.serverProgress(), pending, courses),
            settings: store.settings(),
            pendingEvents: pending.count,
            largeText: store.largeText
        )
    }

    private static func loadCachedCourses(_ store: LocalStore) -> [Course] {
        guard let cached = store.courseList() else { return [] }
        return cached.list.compactMap { info in
            guard let text = store.courseText(info.id) else { return nil }
            return try? Codec.parseCourse(text, hash: info.hash)
        }
    }

    private static func fold(_ server: LearnerProgress, _ pending: [LearnEvent], _ courses: [Course]) -> LearnerProgress {
        pending.reduce(server) { p, e in ProgressLogic.apply(p, e, course: courses.first { $0.id == e.course }) }
    }

    public func consumeMessage() { state.message = nil }

    /// Shows a one-off notice in the UI.
    public func showMessage(_ text: String) { state.message = text }

    public func setLargeText(_ on: Bool) {
        store.largeText = on
        state.largeText = on
    }

    // ------------------------------------------------------------------ account

    /// Logs in or registers, then downloads content and progress. Throws `ApiError`/`OfflineError`.
    public func authenticate(serverUrl: String, username: String, password: String, register: Bool) async throws {
        store.serverUrl = serverUrl
        let session = register
            ? try await api.register(username: username, password: password, device: device)
            : try await api.login(username: username, password: password, device: device)
        // A different account on this device must not inherit the previous one's queue.
        if let old = store.username, old.lowercased() != session.username.lowercased() {
            store.clearAccount()
        }
        store.token = session.token
        store.username = session.username
        state.loggedIn = true
        state.username = session.username
        state.serverUrl = store.serverUrl
        state.settings = store.settings()
        state.progress = Repository.fold(store.serverProgress(), store.pending(), state.courses)
        await sync()
    }

    /// Uploads what is left, then signs out. Returns false if unsent progress had to be discarded.
    public func logout() async -> Bool {
        await sync()
        let lost = !store.pending().isEmpty
        try? await api.logout()
        store.clearAccount()
        signedOut()
        return !lost
    }

    public func changePassword(old: String, new: String) async throws {
        try await api.changePassword(old: old, new: new)
    }

    public func deleteAccount(password: String) async throws {
        try await api.deleteAccount(password: password)
        store.clearAccount()
        signedOut()
    }

    private func signedOut() {
        state.loggedIn = false
        state.username = nil
        state.progress = LearnerProgress()
        state.settings = Codec.Settings()
        state.pendingEvents = 0
    }

    private func sessionExpired() {
        store.token = nil
        state.loggedIn = false
        state.message = "Bitte melde dich erneut an."
    }

    // ------------------------------------------------------------------ sync

    public func syncInBackground() {
        Task { await sync() }
    }

    /// Content + progress + settings. Safe to call often; concurrent calls run one after the other.
    public func sync() async {
        let previous = lastSync
        let task = Task { @MainActor in
            await previous?.value
            await self.runSync()
        }
        lastSync = task
        await task.value
    }

    private func runSync() async {
        if store.token == nil { return }
        state.syncing = true
        defer { state.syncing = false }
        do {
            try await syncContent()
            try await syncProgress()
            try await syncSettings()
            state.offline = false
        } catch is OfflineError {
            state.offline = true
        } catch let e as ApiError {
            if e.status == 401 { sessionExpired() } else { log.warning("Sync failed: \(e.code, privacy: .public) \(e.message, privacy: .public)") }
        } catch {
            log.error("Sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func syncContent() async throws {
        let cached = store.courseList()
        let filesComplete = cached.map { c in c.list.allSatisfy { store.courseText($0.id) != nil } } ?? false
        let res = try await api.courseList(etag: filesComplete ? cached?.hash : nil)
        guard let body = res.body else { return } // 304: nothing changed on the server
        let (hash, list) = try Codec.parseCourseList(body)
        var changed = 0
        for info in list {
            let old = cached?.list.first { $0.id == info.id }
            if let old, old.hash == info.hash, store.courseText(info.id) != nil { continue }
            guard let doc = try await api.course(info.id, etag: nil).body else { continue }
            _ = try Codec.parseCourse(doc, hash: info.hash) // validate before replacing the cached copy
            store.saveCourse(info.id, doc)
            changed += 1
        }
        for c in cached?.list ?? [] where !list.contains(where: { $0.id == c.id }) {
            store.deleteCourse(c.id)
        }
        store.saveCourseList(hash: hash, list: list)
        let courses = Repository.loadCachedCourses(store)
        state.courses = courses
        state.progress = Repository.fold(store.serverProgress(), store.pending(), courses)
        if changed > 0 && cached != nil { state.message = "Neue Lerninhalte wurden geladen." }
    }

    private func syncProgress() async throws {
        let sending = store.pending()
        var snapshot: [String: Any]?
        var start = 0
        while start < sending.count {
            let chunk = Array(sending[start..<min(sending.count, start + 200)])
            let r = try await api.postEvents(chunk)
            snapshot = r["progress"] as? [String: Any]
            if let rejected = r["rejected"] as? [Any], !rejected.isEmpty {
                log.warning("Server rejected events: \(String(describing: rejected), privacy: .public)")
            }
            start += 200
        }
        let server = Codec.parseProgress(try await snapshotOrFetch(snapshot))
        store.saveServerProgress(server)
        let sentIds = Set(sending.map { $0.id })
        let remaining = store.pending().filter { !sentIds.contains($0.id) }
        store.savePending(remaining)
        state.progress = Repository.fold(server, remaining, state.courses)
        state.pendingEvents = remaining.count
    }

    private func snapshotOrFetch(_ snapshot: [String: Any]?) async throws -> [String: Any] {
        if let snapshot { return snapshot }
        return try await api.progress()
    }

    private func syncSettings() async throws {
        let s: Codec.Settings
        if store.settingsDirty {
            s = try await api.putSettings(store.settings())
            store.settingsDirty = false
        } else {
            let me = try await api.me()
            store.username = me.username
            s = me.settings
        }
        store.saveSettings(s)
        // Fall back to the first course if the chosen one no longer exists.
        var fixed = s
        if let c = s.course, !state.courses.contains(where: { $0.id == c }) { fixed.course = nil }
        state.settings = fixed
        state.username = store.username
    }

    // ------------------------------------------------------------------ learning

    private func record(_ e: LearnEvent) {
        let list = store.pending() + [e]
        store.savePending(list)
        state.progress = ProgressLogic.apply(state.progress, e, course: state.courses.first { $0.id == e.course })
        state.pendingEvents = list.count
        syncInBackground()
    }

    private func newId() -> String { UUID().uuidString.lowercased() }

    /// `correct`/`total` are the session's graded answers; they drive the adaptive difficulty.
    /// Returns the XP awarded.
    @discardableResult
    public func completeLesson(course: String, skill: String, lesson: Int, heartsLeft: Int, correct: Int, total: Int) -> Int {
        let xp = ProgressLogic.lessonXp(heartsLeft: heartsLeft)
        record(LearnEvent(id: newId(), course: course, kind: .lesson(skill: skill, lesson: lesson), xp: xp,
                          day: Days.key(), at: Days.nowMillis(), correct: correct, total: total))
        return xp
    }

    @discardableResult
    public func completePractice(course: String, skills: [String], correct: Int, total: Int) -> Int {
        let xp = ProgressLogic.baseXp
        record(LearnEvent(id: newId(), course: course, kind: .practice(skills: skills), xp: xp,
                          day: Days.key(), at: Days.nowMillis(), correct: correct, total: total))
        return xp
    }

    public func resetCourse(_ course: String) {
        record(LearnEvent(id: newId(), course: course, kind: .reset, xp: 0, day: Days.key(), at: Days.nowMillis()))
    }

    public func updateSettings(_ transform: (inout Codec.Settings) -> Void) {
        var s = state.settings
        transform(&s)
        store.saveSettings(s)
        store.settingsDirty = true
        state.settings = s
        syncInBackground()
    }
}
