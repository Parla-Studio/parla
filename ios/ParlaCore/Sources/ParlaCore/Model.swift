import Foundation

/*
 * Plain model of course content and progress, the same as shared/engine/Model.kt in the Kotlin apps.
 */

/// A word and its German translation.
public struct WordPair: Hashable, Sendable {
    public let target: String
    public let german: String

    public init(target: String, german: String) {
        self.target = target
        self.german = german
    }
}

/// One sentence with accepted translations; index 0 is the canonical form shown to the learner.
public struct Sentence: Hashable, Sendable {
    public let target: [String]
    public let german: [String]
    public let skillId: String

    public init(target: [String], german: [String], skillId: String) {
        self.target = target
        self.german = german
        self.skillId = skillId
    }
}

public struct Skill: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let icon: String
    public let row: Int
    /// Colour as 0xRRGGBB.
    public let color: UInt32
    public let words: [WordPair]
    public let sentences: [Sentence]
    public let lessonSize: Int
    /// CEFR-style label from the course file, e.g. "A1", "A2", "B1" (optional).
    public let level: String?

    public init(id: String, title: String, icon: String, row: Int, color: UInt32, words: [WordPair],
                sentences: [Sentence], lessonSize: Int, level: String?) {
        self.id = id
        self.title = title
        self.icon = icon
        self.row = row
        self.color = color
        self.words = words
        self.sentences = sentences
        self.lessonSize = max(1, lessonSize)
        self.level = level
    }

    public var lessonCount: Int { (sentences.count + lessonSize - 1) / lessonSize }

    public func lessonSentences(_ index: Int) -> [Sentence] {
        let start = index * lessonSize
        let end = min(sentences.count, (index + 1) * lessonSize)
        guard start < end else { return [] }
        return Array(sentences[start..<end])
    }
}

public struct Course: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let flag: String
    public let version: Int64
    public let hash: String
    /// BCP-47 language tag for text-to-speech, e.g. "en-GB".
    public let tts: String
    /// Extra characters offered as buttons when typing in the target language.
    public let chars: [String]
    public let keepCap: Set<String>
    public let skills: [Skill]
    /// Word hints: target word -> German, and German word -> target (keys lower-cased).
    public let gloss: [String: String]
    public let glossDe: [String: String]

    public let rows: [Int]
    public let allSentences: [Sentence]

    public init(id: String, name: String, flag: String, version: Int64, hash: String, tts: String, chars: [String],
                keepCap: Set<String>, skills: [Skill], gloss: [String: String], glossDe: [String: String]) {
        self.id = id
        self.name = name
        self.flag = flag
        self.version = version
        self.hash = hash
        self.tts = tts
        self.chars = chars
        self.keepCap = keepCap
        self.skills = skills
        self.gloss = gloss
        self.glossDe = glossDe
        self.rows = Array(Set(skills.map { $0.row })).sorted()
        self.allSentences = skills.flatMap { $0.sentences }
    }

    public func skill(_ id: String) -> Skill? { skills.first { $0.id == id } }

    public static func == (a: Course, b: Course) -> Bool { a.id == b.id && a.hash == b.hash }
}

/// Progress of one skill. `accuracy` is the share of correct answers (0...1), weighted towards recent
/// sessions; `answers` is the number of graded answers so far (0 = no data yet).
public struct SkillProgress: Equatable, Sendable {
    public var lessons: Int
    public var lastPracticed: Int64
    public var reps: Int
    public var accuracy: Double
    public var answers: Int

    public init(lessons: Int = 0, lastPracticed: Int64 = 0, reps: Int = 0, accuracy: Double = 0, answers: Int = 0) {
        self.lessons = lessons
        self.lastPracticed = lastPracticed
        self.reps = reps
        self.accuracy = accuracy
        self.answers = answers
    }
}

/// Learner state: course -> skill -> progress, plus XP per local day ("yyyy-MM-dd").
public struct LearnerProgress: Equatable, Sendable {
    public var courses: [String: [String: SkillProgress]]
    public var xp: [String: Int]

    public init(courses: [String: [String: SkillProgress]] = [:], xp: [String: Int] = [:]) {
        self.courses = courses
        self.xp = xp
    }

    public func skill(_ courseId: String, _ skillId: String) -> SkillProgress {
        courses[courseId]?[skillId] ?? SkillProgress()
    }
}

/// A finished lesson/practice/reset, queued locally and uploaded to the server.
/// `correct`/`total`: graded answers of the session, used to adapt difficulty.
public struct LearnEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case lesson(skill: String, lesson: Int)
        case practice(skills: [String])
        case reset
    }

    public let id: String
    public let course: String
    public let kind: Kind
    public let xp: Int
    public let day: String
    public let at: Int64
    public let correct: Int
    public let total: Int

    public init(id: String, course: String, kind: Kind, xp: Int, day: String, at: Int64, correct: Int = 0, total: Int = 0) {
        self.id = id
        self.course = course
        self.kind = kind
        self.xp = kind == .reset ? 0 : xp
        self.day = day
        self.at = at
        self.correct = correct
        self.total = total
    }
}
