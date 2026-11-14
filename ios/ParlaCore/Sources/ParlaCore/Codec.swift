import Foundation

/// JSON conversion between the server/cache format and the model (same format as shared/data/Codec.kt).
/// Uses JSONSerialization and lenient accessors, like org.json in the Kotlin apps.
public enum Codec {

    public struct FormatError: Error, CustomStringConvertible {
        public let description: String
    }

    // ------------------------------------------------------------------ helpers

    static func object(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FormatError(description: "JSON object expected")
        }
        return o
    }

    static func array(_ text: String) throws -> [Any] {
        guard let data = text.data(using: .utf8),
              let a = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw FormatError(description: "JSON array expected")
        }
        return a
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func string(_ o: [String: Any], _ key: String) throws -> String {
        guard let v = o[key] as? String else { throw FormatError(description: "\(key) missing") }
        return v
    }

    static func optString(_ o: [String: Any], _ key: String, _ fallback: String = "") -> String {
        if let s = o[key] as? String { return s }
        if let n = o[key] as? NSNumber { return n.stringValue }
        return fallback
    }

    static func optInt(_ o: [String: Any], _ key: String, _ fallback: Int = 0) -> Int {
        if let n = o[key] as? NSNumber { return n.intValue }
        if let s = o[key] as? String, let i = Int(s) { return i }
        return fallback
    }

    static func optInt64(_ o: [String: Any], _ key: String, _ fallback: Int64 = 0) -> Int64 {
        if let n = o[key] as? NSNumber { return n.int64Value }
        if let s = o[key] as? String, let i = Int64(s) { return i }
        return fallback
    }

    static func optDouble(_ o: [String: Any], _ key: String, _ fallback: Double = 0) -> Double {
        if let n = o[key] as? NSNumber { return n.doubleValue }
        if let s = o[key] as? String, let d = Double(s) { return d }
        return fallback
    }

    static func optBool(_ o: [String: Any], _ key: String, _ fallback: Bool) -> Bool {
        if let b = o[key] as? Bool { return b }
        if let n = o[key] as? NSNumber { return n.boolValue }
        return fallback
    }

    static func strings(_ v: Any?) -> [String] {
        (v as? [Any] ?? []).compactMap { $0 as? String }
    }

    static func stringMap(_ v: Any?) -> [String: String] {
        guard let o = v as? [String: Any] else { return [:] }
        var m: [String: String] = [:]
        for (k, value) in o {
            if let s = value as? String { m[k.lowercased()] = s }
        }
        return m
    }

    // ------------------------------------------------------------------ course content

    public static func parseCourse(_ text: String, hash: String) throws -> Course {
        let o = try object(text)
        let lessonSize = min(20, max(1, optInt(o, "lessonSize", 4)))
        guard let skillsJson = o["skills"] as? [Any] else { throw FormatError(description: "skills missing") }
        var skills: [Skill] = []
        for item in skillsJson {
            guard let s = item as? [String: Any] else { throw FormatError(description: "skill is not an object") }
            let id = try string(s, "id")
            var words: [WordPair] = []
            for w in (s["words"] as? [Any] ?? []) {
                let pair = strings(w)
                if pair.count >= 2 { words.append(WordPair(target: pair[0], german: pair[1])) }
            }
            guard let sentencesJson = s["sentences"] as? [Any] else { throw FormatError(description: "sentences missing in \(id)") }
            var sentences: [Sentence] = []
            for sj in sentencesJson {
                guard let so = sj as? [String: Any] else { throw FormatError(description: "sentence is not an object") }
                let t = strings(so["t"])
                let de = strings(so["de"])
                guard !t.isEmpty, !de.isEmpty else { throw FormatError(description: "empty sentence in \(id)") }
                sentences.append(Sentence(target: t, german: de, skillId: id))
            }
            guard let row = (s["row"] as? NSNumber)?.intValue else { throw FormatError(description: "row missing in \(id)") }
            let level = optString(s, "level")
            skills.append(Skill(
                id: id,
                title: try string(s, "title"),
                icon: optString(s, "icon", "⭐"),
                row: row,
                color: parseColor(optString(s, "color", "#1cb0f6")),
                words: words,
                sentences: sentences,
                lessonSize: lessonSize,
                level: level.isEmpty ? nil : level
            ))
        }
        return Course(
            id: try string(o, "id"),
            name: try string(o, "name"),
            flag: optString(o, "flag"),
            version: optInt64(o, "version", 1),
            hash: hash,
            tts: try string(o, "tts"),
            chars: strings(o["chars"]),
            keepCap: Set(strings(o["keepCap"])),
            skills: skills,
            gloss: stringMap(o["gloss"]),
            glossDe: stringMap(o["glossDe"])
        )
    }

    static func parseColor(_ hex: String) -> UInt32 {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if h.count == 6, let v = UInt32(h, radix: 16) { return v }
        return 0x1CB0F6
    }

    // ------------------------------------------------------------------ course list

    public struct CourseInfo: Equatable, Sendable {
        public let id: String
        public let name: String
        public let flag: String
        public let version: Int64
        public let hash: String
    }

    public static func parseCourseList(_ text: String) throws -> (hash: String, list: [CourseInfo]) {
        let o = try object(text)
        guard let arr = o["courses"] as? [Any] else { throw FormatError(description: "courses missing") }
        var list: [CourseInfo] = []
        for item in arr {
            guard let c = item as? [String: Any] else { continue }
            list.append(CourseInfo(id: try string(c, "id"), name: try string(c, "name"), flag: optString(c, "flag"),
                                   version: optInt64(c, "version"), hash: try string(c, "hash")))
        }
        return (try string(o, "hash"), list)
    }

    public static func courseListJson(hash: String, list: [CourseInfo]) -> String {
        json([
            "hash": hash,
            "courses": list.map { ["id": $0.id, "name": $0.name, "flag": $0.flag, "version": $0.version, "hash": $0.hash] as [String: Any] },
        ] as [String: Any])
    }

    // ------------------------------------------------------------------ progress

    public static func parseProgress(_ o: [String: Any]) -> LearnerProgress {
        var courses: [String: [String: SkillProgress]] = [:]
        for (cid, value) in (o["courses"] as? [String: Any] ?? [:]) {
            var skills: [String: SkillProgress] = [:]
            for (sid, sv) in (value as? [String: Any] ?? [:]) {
                guard let p = sv as? [String: Any] else { continue }
                skills[sid] = SkillProgress(
                    lessons: optInt(p, "lessons"), lastPracticed: optInt64(p, "lastPracticed"), reps: optInt(p, "reps"),
                    accuracy: optDouble(p, "accuracy"), answers: optInt(p, "answers"))
            }
            courses[cid] = skills
        }
        var xp: [String: Int] = [:]
        for (day, v) in (o["xp"] as? [String: Any] ?? [:]) {
            if let n = v as? NSNumber { xp[day] = n.intValue }
        }
        return LearnerProgress(courses: courses, xp: xp)
    }

    public static func parseProgress(_ text: String) throws -> LearnerProgress { parseProgress(try object(text)) }

    public static func progressObject(_ p: LearnerProgress) -> [String: Any] {
        var courses: [String: Any] = [:]
        for (cid, skills) in p.courses {
            var sj: [String: Any] = [:]
            for (sid, s) in skills {
                sj[sid] = ["lessons": s.lessons, "lastPracticed": s.lastPracticed, "reps": s.reps,
                           "accuracy": s.accuracy, "answers": s.answers] as [String: Any]
            }
            courses[cid] = sj
        }
        return ["courses": courses, "xp": p.xp]
    }

    public static func progressJson(_ p: LearnerProgress) -> String { json(progressObject(p)) }

    // ------------------------------------------------------------------ events

    public static func eventObject(_ e: LearnEvent) -> [String: Any] {
        var o: [String: Any] = ["id": e.id, "course": e.course, "at": e.at]
        switch e.kind {
        case let .lesson(skill, lesson):
            o["type"] = "lesson"
            o["skill"] = skill
            o["lesson"] = lesson
            o["xp"] = e.xp
            o["day"] = e.day
            o["correct"] = e.correct
            o["total"] = e.total
        case let .practice(skills):
            o["type"] = "practice"
            o["skills"] = skills
            o["xp"] = e.xp
            o["day"] = e.day
            o["correct"] = e.correct
            o["total"] = e.total
        case .reset:
            o["type"] = "reset"
            o["day"] = e.day
        }
        return o
    }

    public static func parseEvent(_ o: [String: Any]) -> LearnEvent? {
        guard let id = o["id"] as? String, let course = o["course"] as? String else { return nil }
        let at = optInt64(o, "at")
        let day = optString(o, "day")
        switch optString(o, "type") {
        case "lesson":
            guard let skill = o["skill"] as? String else { return nil }
            return LearnEvent(id: id, course: course, kind: .lesson(skill: skill, lesson: optInt(o, "lesson")),
                              xp: optInt(o, "xp"), day: day, at: at, correct: optInt(o, "correct"), total: optInt(o, "total"))
        case "practice":
            return LearnEvent(id: id, course: course, kind: .practice(skills: strings(o["skills"])),
                              xp: optInt(o, "xp"), day: day, at: at, correct: optInt(o, "correct"), total: optInt(o, "total"))
        case "reset":
            return LearnEvent(id: id, course: course, kind: .reset, xp: 0, day: day, at: at)
        default:
            return nil
        }
    }

    public static func eventsArray(_ list: [LearnEvent]) -> [Any] { list.map { eventObject($0) } }

    public static func eventsJson(_ list: [LearnEvent]) -> String { json(eventsArray(list)) }

    public static func parseEvents(_ text: String) throws -> [LearnEvent] {
        try array(text).compactMap { ($0 as? [String: Any]).flatMap(parseEvent) }
    }

    // ------------------------------------------------------------------ settings

    public struct Settings: Equatable, Sendable {
        public var goal: Int
        public var sound: Bool
        public var listen: Bool
        public var course: String?

        public init(goal: Int = 20, sound: Bool = true, listen: Bool = true, course: String? = nil) {
            self.goal = goal
            self.sound = sound
            self.listen = listen
            self.course = course
        }
    }

    public static func parseSettings(_ o: [String: Any]) -> Settings {
        let course = o["course"] as? String
        return Settings(goal: optInt(o, "goal", 20), sound: optBool(o, "sound", true), listen: optBool(o, "listen", true),
                        course: (course?.isEmpty ?? true) ? nil : course)
    }

    public static func parseSettings(_ text: String) throws -> Settings { parseSettings(try object(text)) }

    public static func settingsObject(_ s: Settings) -> [String: Any] {
        let course: Any = s.course.map { $0 as Any } ?? NSNull()
        return ["goal": s.goal, "sound": s.sound, "listen": s.listen, "course": course]
    }

    public static func settingsJson(_ s: Settings) -> String { json(settingsObject(s)) }
}
