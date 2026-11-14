import Foundation

/// Progress rules, the same as shared/engine/ProgressLogic.kt. `apply` must stay in sync with the server's
/// progress service so that the optimistic local update matches what the server computes after upload.
public enum ProgressLogic {

    public static let hearts = 3
    public static let baseXp = 10

    public static func apply(_ p: LearnerProgress, _ e: LearnEvent, course: Course?) -> LearnerProgress {
        var skills = p.courses[e.course] ?? [:]
        switch e.kind {
        case let .lesson(skillId, lesson):
            guard let total = course?.skill(skillId)?.lessonCount else { return p }
            let old = skills[skillId] ?? SkillProgress()
            let wasDone = old.lessons >= total
            let lessons = max(old.lessons, lesson + 1)
            var reps = old.reps
            var last = old.lastPracticed
            if !wasDone && lessons >= total { reps = max(1, reps) } else if wasDone { reps += 1 }
            if lessons >= total { last = max(last, e.at) }
            let (acc, answers) = blend(old.accuracy, old.answers, e.correct, e.total)
            skills[skillId] = SkillProgress(lessons: lessons, lastPracticed: last, reps: reps, accuracy: acc, answers: answers)
        case let .practice(ids):
            for id in ids {
                guard var s = skills[id] else { continue }
                let (acc, answers) = blend(s.accuracy, s.answers, e.correct, e.total)
                s.lastPracticed = max(s.lastPracticed, e.at)
                s.reps += 1
                s.accuracy = acc
                s.answers = answers
                skills[id] = s
            }
        case .reset:
            var next = p
            next.courses.removeValue(forKey: e.course)
            return next
        }
        var next = p
        next.courses[e.course] = skills
        if e.xp > 0 { next.xp[e.day] = (p.xp[e.day] ?? 0) + e.xp }
        return next
    }

    public static func isDone(_ p: LearnerProgress, _ course: Course, _ skill: Skill) -> Bool {
        p.skill(course.id, skill.id).lessons >= skill.lessonCount
    }

    public static func rowOpen(_ p: LearnerProgress, _ course: Course, _ row: Int) -> Bool {
        course.skills.filter { $0.row < row }.allSatisfy { isDone(p, course, $0) }
    }

    /// Strength 1...5 for a finished skill (0 if unfinished). It decays over an interval that doubles with
    /// every review: a simple spaced-repetition scheme.
    public static func strength(_ p: LearnerProgress, _ course: Course, _ skill: Skill, now: Int64 = Days.nowMillis()) -> Int {
        let sp = p.skill(course.id, skill.id)
        if sp.lessons < skill.lessonCount { return 0 }
        let days = Double(now - sp.lastPracticed) / 86_400_000.0
        let interval = pow(2.0, Double(min(sp.reps, 6)))
        return max(1, 5 - Int((days / interval * 4).rounded(.down)))
    }

    public static func streak(_ xp: [String: Int], today: Date = Date()) -> Int {
        var day = (xp[Days.key(today)] ?? 0) > 0 ? today : Days.adding(-1, to: today)
        var n = 0
        while (xp[Days.key(day)] ?? 0) > 0 {
            n += 1
            day = Days.adding(-1, to: day)
        }
        return n
    }

    public static func lessonXp(heartsLeft: Int) -> Int { baseXp + heartsLeft }

    // ------------------------------------------------------------------ adaptive difficulty

    /// Weight of the newest session in the running accuracy. Must match the server.
    public static let accuracyWeight = 0.35

    public static func blend(_ accuracy: Double, _ answers: Int, _ correct: Int, _ total: Int) -> (Double, Int) {
        if total <= 0 { return (accuracy, answers) }
        let session = Double(correct) / Double(total)
        let next = answers == 0 ? session : accuracy * (1 - accuracyWeight) + session * accuracyWeight
        return (next, min(1_000_000, answers + total))
    }

    /// Assumed accuracy before we know anything about the learner, and how many answers it is "worth".
    private static let priorAccuracy = 0.75
    private static let priorWeight = 10.0

    /// Estimated accuracy for `skill`: its own history, backed by the learner's results in the rest of the course.
    public static func estimatedAccuracy(_ p: LearnerProgress, _ course: Course, _ skill: Skill) -> Double {
        let all = (p.courses[course.id] ?? [:]).values.filter { $0.answers > 0 }
        let n = Double(all.reduce(0) { $0 + $1.answers })
        let weighted = all.reduce(0.0) { $0 + $1.accuracy * Double($1.answers) }
        let courseEstimate = (weighted + priorAccuracy * priorWeight) / (n + priorWeight)
        let own = p.skill(course.id, skill.id)
        return (own.accuracy * Double(own.answers) + courseEstimate * priorWeight) / (Double(own.answers) + priorWeight)
    }

    /// Difficulty 0...1 for building exercises: 0 = lots of recognition and help, 1 = mostly free typing and
    /// listening with tricky distractors.
    public static func difficulty(_ p: LearnerProgress, _ course: Course, _ skill: Skill) -> Double {
        min(1, max(0, (estimatedAccuracy(p, course, skill) - 0.65) / 0.30))
    }

    public static func difficultyLabel(_ d: Double) -> String {
        if d < 0.34 { return "Leicht" }
        if d < 0.67 { return "Mittel" }
        return "Schwer"
    }
}

/// Local calendar days as "yyyy-MM-dd" (the key format of the XP map) and timestamps in milliseconds.
public enum Days {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func key(_ date: Date = Date()) -> String {
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    public static func adding(_ days: Int, to date: Date) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: date) ?? date
    }

    public static func nowMillis() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}
