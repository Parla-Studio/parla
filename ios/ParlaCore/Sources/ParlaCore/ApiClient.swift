import Foundation

/// Error reported by the server (status + machine code + German message for the user).
public struct ApiError: Error, LocalizedError {
    public let status: Int
    public let code: String
    public let message: String

    public var errorDescription: String? { message }
}

/// The server could not be reached (no network, DNS, timeout, TLS ...). `reason` says why, in German.
public struct OfflineError: Error, LocalizedError {
    public let reason: String

    public var errorDescription: String? { reason }

    public init(reason: String) {
        self.reason = reason
    }

    public init(_ error: Error) {
        guard let e = error as? URLError else {
            reason = "Keine Verbindung zum Server (\(error.localizedDescription))."
            return
        }
        switch e.code {
        case .cannotFindHost, .dnsLookupFailed:
            reason = "Die Serveradresse wurde nicht gefunden. Prüfe die Adresse und die Internetverbindung."
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            reason = "Keine Internetverbindung."
        case .appTransportSecurityRequiresSecureConnection:
            reason = "Unverschlüsselte Verbindungen (http://) sind hier gesperrt. Nutze eine https://-Adresse."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            reason = "Sichere Verbindung fehlgeschlagen: Das Zertifikat des Servers wird nicht akzeptiert."
        case .timedOut:
            reason = "Der Server antwortet nicht (Zeitüberschreitung)."
        case .cannotConnectToHost:
            reason = "Der Server ist unter dieser Adresse nicht erreichbar (Verbindung abgelehnt)."
        case .badURL, .unsupportedURL:
            reason = "Die Serveradresse ist ungültig."
        default:
            reason = "Keine Verbindung zum Server (\(e.localizedDescription))."
        }
    }
}

/// Thin client for the Parla HTTP API (the same endpoints as shared/data/ApiClient.kt).
public final class ApiClient: @unchecked Sendable {
    private let baseUrl: () -> String
    private let token: () -> String?
    private let session: URLSession

    public struct Session: Sendable {
        public let token: String
        public let username: String
    }

    public struct Me: Sendable {
        public let username: String
        public let settings: Codec.Settings
    }

    /// Result of a conditional GET: `body` is nil when the server answered 304 Not Modified.
    public struct Conditional: Sendable {
        public let body: String?
        public let etag: String?
    }

    public init(baseUrl: @escaping () -> String, token: @escaping () -> String?) {
        self.baseUrl = baseUrl
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        // ETags are handled by the app itself; the URL cache would hide the server's 304 answers.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    public func register(username: String, password: String, device: String) async throws -> Session {
        try makeSession(try await post("/api/auth/register", ["username": username, "password": password, "device": device], auth: false))
    }

    public func login(username: String, password: String, device: String) async throws -> Session {
        try makeSession(try await post("/api/auth/login", ["username": username, "password": password, "device": device], auth: false))
    }

    private func makeSession(_ o: [String: Any]) throws -> Session {
        guard let token = o["token"] as? String,
              let user = o["user"] as? [String: Any],
              let name = user["username"] as? String else {
            throw Codec.FormatError(description: "Unexpected login answer")
        }
        return Session(token: token, username: name)
    }

    public func logout() async throws {
        _ = try await post("/api/auth/logout", [:])
    }

    public func changePassword(old: String, new: String) async throws {
        _ = try await post("/api/auth/password", ["oldPassword": old, "newPassword": new])
    }

    public func deleteAccount(password: String) async throws {
        _ = try await request("DELETE", "/api/account", body: ["password": password], auth: true)
    }

    public func me() async throws -> Me {
        let o = try Codec.object(try await request("GET", "/api/me", body: nil, auth: true).body ?? "{}")
        guard let user = o["user"] as? [String: Any], let name = user["username"] as? String else {
            throw Codec.FormatError(description: "Unexpected /api/me answer")
        }
        return Me(username: name, settings: Codec.parseSettings(o["settings"] as? [String: Any] ?? [:]))
    }

    public func putSettings(_ s: Codec.Settings) async throws -> Codec.Settings {
        let text = try await request("PUT", "/api/settings", body: Codec.settingsObject(s), auth: true).body ?? "{}"
        return try Codec.parseSettings(text)
    }

    public func courseList(etag: String?) async throws -> Conditional {
        try await request("GET", "/api/courses", body: nil, auth: false, etag: etag)
    }

    public func course(_ id: String, etag: String?) async throws -> Conditional {
        try await request("GET", "/api/courses/\(id)", body: nil, auth: false, etag: etag)
    }

    public func progress() async throws -> [String: Any] {
        try Codec.object(try await request("GET", "/api/progress", body: nil, auth: true).body ?? "{}")
    }

    /// Uploads events and returns the server's answer: the progress snapshot plus accepted/rejected ids.
    public func postEvents(_ events: [LearnEvent]) async throws -> [String: Any] {
        try await post("/api/progress/events", ["events": Codec.eventsArray(events)])
    }

    private func post(_ path: String, _ body: [String: Any], auth: Bool = true) async throws -> [String: Any] {
        let text = try await request("POST", path, body: body, auth: auth).body ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        return try Codec.object(text)
    }

    private func request(_ method: String, _ path: String, body: [String: Any]?, auth: Bool, etag: String? = nil) async throws -> Conditional {
        var base = baseUrl()
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else {
            throw OfflineError(reason: "Die Serveradresse ist ungültig.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        } else if method == "POST" || method == "PUT" {
            req.httpBody = Data("{}".utf8)
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        if auth, let t = token() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let etag { req.setValue("\"\(etag)\"", forHTTPHeaderField: "If-None-Match") }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: req)
        } catch {
            throw OfflineError(error)
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw OfflineError(reason: "Unerwartete Antwort vom Server.")
        }
        let text = String(data: data, encoding: .utf8)
        if http.statusCode == 304 { return Conditional(body: nil, etag: etag) }
        if (200..<300).contains(http.statusCode) {
            var tag = http.value(forHTTPHeaderField: "ETag")
            tag = tag?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return Conditional(body: text ?? "", etag: tag)
        }
        var code = "http_\(http.statusCode)"
        var message = "Serverfehler (\(http.statusCode))."
        if let text, let o = try? Codec.object(text) {
            code = (o["error"] as? String) ?? code
            message = (o["message"] as? String) ?? "Fehler \(http.statusCode)"
        }
        throw ApiError(status: http.statusCode, code: code, message: message)
    }
}
