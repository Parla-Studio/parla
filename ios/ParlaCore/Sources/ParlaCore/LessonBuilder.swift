import Foundation

// One step of a lesson, the same as shared/engine/LessonBuilder.kt. "Target" is the language being
// learned, "German" the learner's language.

/// Assemble a translation from word chips. `toGerman` = prompt is in the target language.
public struct BankExercise: Equatable, Sendable {
    public let sentence: Sentence
    public let toGerman: Bool
    public let chips: [String]
    public var prompt: String { toGerman ? sentence.target[0] : sentence.german[0] }
    public var accepted: [String] { toGerman ? sentence.german : sentence.target }
}

/// Type a translation.
public struct TypeExercise: Equatable, Sendable {
    public let sentence: Sentence
    public let toGerman: Bool
    public var prompt: String { toGerman ? sentence.target[0] : sentence.german[0] }
    public var accepted: [String] { toGerman ? sentence.german : sentence.target }
}

/// Hear a target-language sentence and type it.
public struct ListenExercise: Equatable, Sendable {
    public let sentence: Sentence
}

/// Pick the right German translation of a target sentence.
public struct ChoiceExercise: Equatable, Sendable {
    public let sentence: Sentence
    public let options: [String]
}

/// "Which of these means X?" – pick the target word.
public struct WordExercise: Equatable, Sendable {
    public let word: WordPair
    public let options: [String]
}

/// Tap matching pairs.
public struct MatchExercise: Equatable, Sendable {
    public let pairs: [WordPair]
}

public enum Exercise: Equatable, Sendable {
    case bank(BankExercise)
    case type(TypeExercise)
    case listen(ListenExercise)
    case choice(ChoiceExercise)
    case word(WordExercise)
    case match(MatchExercise)

    /// The answer shown when the learner gets it wrong.
    public var solution: String {
        switch self {
        case let .bank(e): return e.accepted[0]
        case let .type(e): return e.accepted[0]
        case let .listen(e): return e.sentence.target[0]
        case let .choice(e): return e.sentence.german[0]
        case let .word(e): return e.word.target
        case .match: return ""
        }
    }

    public var isMatch: Bool {
        if case .match = self { return true }
        return false
    }
}

/// Per-course lookup data used to build word banks and hints.
public final class CourseIndex {
    public let course: Course
    /// Words that keep their capital letter in chips (German nouns, names, English "I").
    private var capTarget: Set<String>
    private var capGerman: Set<String> = []
    public private(set) var targetTokens: [String] = []
    public private(set) var germanTokens: [String] = []
    private var targetSeen: Set<String> = []
    private var germanSeen: Set<String> = []
    /// Tokens per skill, so hard word banks can offer look-alike distractors from the same unit.
    public private(set) var targetTokensBySkill: [String: [String]] = [:]
    public private(set) var germanTokensBySkill: [String: [String]] = [:]
    public let glossTarget: [String: String]
    public let glossGerman: [String: String]

    public init(_ course: Course) {
        self.course = course
        self.capTarget = course.keepCap
        var gt = course.gloss
        var gg = course.glossDe
        for sk in course.skills {
            for w in sk.words {
                let t = w.target.lowercased()
                let d = w.german.lowercased()
                if gt[t] == nil { gt[t] = w.german }
                if gg[d] == nil { gg[d] = w.target }
            }
        }
        glossTarget = gt
        glossGerman = gg
        for s in course.allSentences {
            for text in s.target { collect(text, german: false, skill: s.skillId) }
            for text in s.german { collect(text, german: true, skill: s.skillId) }
        }
    }

    private func collect(_ text: String, german: Bool, skill: String) {
        for (i, w) in Grading.tokens(text).enumerated() {
            if i > 0, let first = w.first, first.isUppercase {
                if german { capGerman.insert(w) } else { capTarget.insert(w) }
            }
            if german {
                if germanSeen.insert(w).inserted { germanTokens.append(w) }
                var list = germanTokensBySkill[skill] ?? []
                if !list.contains(w) { list.append(w) }
                germanTokensBySkill[skill] = list
            } else {
                if targetSeen.insert(w).inserted { targetTokens.append(w) }
                var list = targetTokensBySkill[skill] ?? []
                if !list.contains(w) { list.append(w) }
                targetTokensBySkill[skill] = list
            }
        }
    }

    /// Lower-cases sentence-initial words unless they are always capitalised.
    public func display(_ word: String, german: Bool) -> String {
        let caps = german ? capGerman : capTarget
        if caps.contains(word) { return word }
        guard let first = word.first else { return word }
        return first.lowercased() + word.dropFirst()
    }

    public func hint(_ word: String, german: Bool) -> String? {
        let key = Grading.norm(word).replacingOccurrences(of: " ", with: "")
        return (german ? glossGerman : glossTarget)[key]
    }
}

/// Type-erased random number generator, so a seeded generator can be used in tests.
public struct AnyRandom: RandomNumberGenerator {
    private var base: any RandomNumberGenerator

    public init(_ base: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.base = base
    }

    public mutating func next() -> UInt64 { base.next() }
}

/// Builds lessons the classic way: new sentences are first recognised, then produced. The mix adapts to a
/// difficulty value 0...1 (see `ProgressLogic.difficulty`), exactly like the Kotlin LessonBuilder.
public final class LessonBuilder {
    private let index: CourseIndex
    private var random: AnyRandom
    private var course: Course { index.course }

    enum Kind { case bankTo, choice, bankFrom, typeTo, typeFrom, listen }

    public init(_ index: CourseIndex, random: AnyRandom = AnyRandom()) {
        self.index = index
        self.random = random
    }

    private func shuffled<T>(_ list: [T]) -> [T] { list.shuffled(using: &random) }
    private func nextDouble() -> Double { Double.random(in: 0..<1, using: &random) }

    public func lesson(_ skill: Skill, _ lessonIndex: Int, listening: Bool, difficulty: Double = 0.33) -> [Exercise] {
        let d = min(1, max(0, difficulty))
        let fresh = skill.lessonSentences(lessonIndex)
        let reviewCount = Int((1 + 2 * d).rounded())
        let earlier = Array(shuffled(Array(skill.sentences.prefix(lessonIndex * skill.lessonSize))).prefix(reviewCount))
        let words = Array(skill.words.prefix(min(skill.words.count, 3 + (lessonIndex + 1) * 2)))

        // Strong learners skip the recognition step for some new sentences.
        var first: [Exercise] = []
        for s in fresh where d < 0.67 || nextDouble() > (d - 0.6) {
            first.append(make(passiveKind(d), s, d))
        }
        var second: [Exercise] = []
        for s in fresh { second.append(make(activeKind(d, listening), s, d)) }
        for s in earlier { second.append(make(activeKind(d, listening), s, d)) }
        var middle: [Exercise] = []
        if words.count >= 3 { middle.append(.word(word(words, d))) }
        if words.count >= 4 { middle.append(.match(match(words))) }
        return shuffled(first) + middle + shuffled(second)
    }

    public func practice(_ skills: [Skill], listening: Bool, difficulty: Double = 0.33) -> [Exercise] {
        let d = min(1, max(0, difficulty))
        let sentences = Array(shuffled(skills.flatMap { $0.sentences }).prefix(10))
        let words = skills.flatMap { $0.words }
        var list: [Exercise] = []
        for (i, s) in sentences.enumerated() {
            // Practice starts gently and leans on production in the second half.
            list.append(make(i < 3 && d < 0.5 ? passiveKind(d) : activeKind(d, listening), s, d))
        }
        if words.count >= 4 { list.insert(.match(match(words)), at: min(3, list.count)) }
        if words.count >= 3 { list.insert(.word(word(Array(shuffled(words).prefix(6)), d)), at: min(7, list.count)) }
        return list
    }

    private func passiveKind(_ d: Double) -> Kind {
        weighted([(.bankTo, 1.0 + d), (.choice, 1.6 - d)])
    }

    private func activeKind(_ d: Double, _ listening: Bool) -> Kind {
        weighted([
            (.bankFrom, 3.0 - 2.0 * d),
            (.bankTo, 1.2 * (1 - d)),
            (.typeTo, 0.6 + 1.4 * d),
            (.typeFrom, 0.2 + 2.3 * d),
            (.listen, listening ? 0.3 + 1.2 * d : 0.0),
        ])
    }

    private func weighted(_ options: [(Kind, Double)]) -> Kind {
        let total = options.reduce(0.0) { $0 + max(0, $1.1) }
        var r = nextDouble() * total
        for (k, w) in options {
            r -= max(0, w)
            if r <= 0 { return k }
        }
        return options.last(where: { $0.1 > 0 })?.0 ?? options[0].0
    }

    private func make(_ kind: Kind, _ s: Sentence, _ d: Double) -> Exercise {
        switch kind {
        case .bankTo: return .bank(BankExercise(sentence: s, toGerman: true, chips: chips(s, german: true, d)))
        case .bankFrom: return .bank(BankExercise(sentence: s, toGerman: false, chips: chips(s, german: false, d)))
        case .choice: return .choice(ChoiceExercise(sentence: s, options: shuffled([s.german[0]] + distractors(s, 2, d))))
        case .typeTo: return .type(TypeExercise(sentence: s, toGerman: true))
        case .typeFrom: return .type(TypeExercise(sentence: s, toGerman: false))
        case .listen: return .listen(ListenExercise(sentence: s))
        }
    }

    // ------------------------------------------------------------------ in-session adjustment

    /// Converts listening exercises into word-bank exercises (when the learner can't listen right now).
    public func withoutListening(_ list: [Exercise]) -> [Exercise] {
        list.map { e in
            if case let .listen(l) = e {
                return .bank(BankExercise(sentence: l.sentence, toGerman: false, chips: chips(l.sentence, german: false, 0.5)))
            }
            return e
        }
    }

    /// Makes the next `count` exercises after `from` easier (after repeated mistakes) or harder (after a run of
    /// correct answers). Exercises before `from` are untouched.
    public func adjust(_ list: [Exercise], from: Int, harder: Bool, count: Int = 3) -> [Exercise] {
        var changed = 0
        var result: [Exercise] = []
        for (i, e) in list.enumerated() {
            if i < from || changed >= count {
                result.append(e)
                continue
            }
            let next = harder ? self.harder(e) : easier(e)
            if next != e { changed += 1 }
            result.append(next)
        }
        return result
    }

    private func easier(_ e: Exercise) -> Exercise {
        switch e {
        case let .type(t):
            return .bank(BankExercise(sentence: t.sentence, toGerman: t.toGerman, chips: chips(t.sentence, german: t.toGerman, 0.0)))
        case let .listen(l):
            return .bank(BankExercise(sentence: l.sentence, toGerman: false, chips: chips(l.sentence, german: false, 0.0)))
        case let .bank(b):
            if !b.toGerman {
                return .bank(BankExercise(sentence: b.sentence, toGerman: true, chips: chips(b.sentence, german: true, 0.0)))
            }
            return e
        default:
            return e
        }
    }

    private func harder(_ e: Exercise) -> Exercise {
        switch e {
        case let .bank(b): return .type(TypeExercise(sentence: b.sentence, toGerman: b.toGerman))
        case let .choice(c):
            return .bank(BankExercise(sentence: c.sentence, toGerman: false, chips: chips(c.sentence, german: false, 1.0)))
        default: return e
        }
    }

    // ------------------------------------------------------------------ distractors

    private func chips(_ s: Sentence, german: Bool, _ d: Double) -> [String] {
        let answer = german ? s.german[0] : s.target[0]
        let words = Grading.tokens(answer).map { index.display($0, german: german) }
        let have = Set(words.map { $0.lowercased() })
        let sameSkill = (german ? index.germanTokensBySkill : index.targetTokensBySkill)[s.skillId] ?? []
        let all = german ? index.germanTokens : index.targetTokens
        // Hard: look-alikes from the same unit first. Easy: anything, shuffled.
        let ordered = d >= 0.5 ? shuffled(sameSkill) + shuffled(all) : shuffled(all)
        var seen = Set<String>()
        var pool: [String] = []
        for t in ordered {
            let w = index.display(t, german: german)
            if seen.insert(w).inserted && !have.contains(w.lowercased()) { pool.append(w) }
        }
        let extra = min(6, max(2, Int((2 + 4 * d).rounded())))
        return shuffled(words + pool.prefix(extra))
    }

    private func distractors(_ s: Sentence, _ n: Int, _ d: Double) -> [String] {
        let same = shuffled((course.skill(s.skillId)?.sentences ?? []).filter { $0 != s })
        let rest = shuffled(course.allSentences.filter { $0.skillId != s.skillId })
        let accepted = Set(s.german.map { Grading.norm($0) })
        // Hard: options from the same unit are easy to confuse. Easy: options from elsewhere.
        let ordered = d >= 0.5 ? same + rest : rest + same
        var seen = Set<String>()
        var out: [String] = []
        for o in ordered {
            let g = o.german[0]
            if accepted.contains(Grading.norm(g)) || !seen.insert(g).inserted { continue }
            out.append(g)
            if out.count == n { break }
        }
        return out
    }

    private func word(_ words: [WordPair], _ d: Double) -> WordExercise {
        let target = words.randomElement(using: &random)!
        let optionCount = d >= 0.5 ? 3 : 2
        let others = Array(shuffled(words.filter { $0.target != target.target && $0.german != target.german }).prefix(optionCount))
        return WordExercise(word: target, options: shuffled((others + [target]).map { $0.target }))
    }

    private func match(_ words: [WordPair]) -> MatchExercise {
        var seen = Set<String>()
        var pairs: [WordPair] = []
        for w in shuffled(words) {
            // Same rule as Kotlin: unique German word and unique target word.
            guard seen.insert(w.german).inserted else { continue }
            guard seen.insert("t:" + w.target).inserted else { continue }
            pairs.append(w)
            if pairs.count == 5 { break }
        }
        return MatchExercise(pairs: pairs)
    }
}
