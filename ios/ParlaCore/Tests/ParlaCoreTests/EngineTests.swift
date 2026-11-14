import XCTest
@testable import ParlaCore

/// Same checks as the Kotlin EngineTest, so both apps grade and build lessons the same way. Runs against
/// copies of the real course files (Tests/ParlaCoreTests/courses).
final class EngineTests: XCTestCase {

    /// Small deterministic generator (SplitMix64) for reproducible lessons.
    struct SeededRandom: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: Int) { state = UInt64(seed) &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func course(_ id: String) throws -> Course {
        let url = try XCTUnwrap(Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "courses"))
        return try Codec.parseCourse(String(contentsOf: url, encoding: .utf8), hash: "test")
    }

    private func date(_ day: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: day + " 12:00")!
    }

    func testGrading() {
        XCTAssertTrue(Grading.grade("le garcon mange une pomme", accepted: ["Le garçon mange une pomme."]).correct)
        XCTAssertTrue(Grading.grade("I dont eat meat", accepted: ["I don't eat meat."]).correct)
        XCTAssertFalse(Grading.grade("Je mange du pomme", accepted: ["Je mange une pomme."]).correct)
        XCTAssertTrue(Grading.grade("nous mangons du pain", accepted: ["Nous mangeons du pain."]).note?.hasPrefix("Kleiner") == true)
        XCTAssertFalse(Grading.grade("she eat rice", accepted: ["She eats rice."]).correct)
        XCTAssertNil(Grading.grade("  Hello ,  how are you ? ", accepted: ["Hello, how are you?"]).note)
        XCTAssertTrue(Grading.grade("  Hello ,  how are you ? ", accepted: ["Hello, how are you?"]).correct)
    }

    func testEveryGeneratedExerciseIsSolvable() throws {
        for id in ["en", "fr"] {
            let c = try course(id)
            let index = CourseIndex(c)
            for seed in 0..<10 {
                let builder = LessonBuilder(index, random: AnyRandom(SeededRandom(seed)))
                let d = Double(seed) / 9.0
                for skill in c.skills {
                    for l in 0..<skill.lessonCount {
                        let list = builder.lesson(skill, l, listening: true, difficulty: d)
                            + builder.practice([skill], listening: true, difficulty: d)
                        for e in builder.adjust(list, from: 1, harder: seed % 2 == 0, count: 5) {
                            switch e {
                            case let .bank(b):
                                var chips = b.chips.map { $0.lowercased() }
                                for t in Grading.tokens(e.solution) {
                                    let i = chips.firstIndex(of: t.lowercased())
                                    XCTAssertNotNil(i, "chip \(t) for \(e.solution)")
                                    if let i { chips.remove(at: i) }
                                }
                            case let .type(t):
                                XCTAssertTrue(Grading.grade(e.solution, accepted: t.accepted).correct)
                            case let .listen(li):
                                XCTAssertTrue(Grading.grade(e.solution, accepted: li.sentence.target).correct)
                            case let .choice(ch):
                                XCTAssertTrue(ch.options.contains(e.solution))
                                XCTAssertEqual(Set(ch.options).count, 3)
                            case let .word(w):
                                XCTAssertTrue(w.options.contains(e.solution))
                            case let .match(m):
                                XCTAssertTrue((3...5).contains(m.pairs.count))
                            }
                        }
                    }
                }
            }
        }
    }

    func testProgressMatchesServerRules() throws {
        let c = try course("en")
        let g1 = try XCTUnwrap(c.skill("g1"))
        var p = LearnerProgress()
        for l in 0..<g1.lessonCount {
            p = ProgressLogic.apply(p, LearnEvent(id: "e\(l)", course: "en", kind: .lesson(skill: "g1", lesson: l),
                                                  xp: 13, day: "2026-11-11", at: 1_000), course: c)
        }
        XCTAssertTrue(ProgressLogic.isDone(p, c, g1))
        XCTAssertEqual(p.skill("en", "g1").reps, 1)
        XCTAssertEqual(p.xp["2026-11-11"], 39)
        XCTAssertEqual(ProgressLogic.strength(p, c, g1, now: 1_000), 5)
        XCTAssertEqual(ProgressLogic.strength(p, c, g1, now: 1_000 + 3 * 86_400_000), 1)
        p = ProgressLogic.apply(p, LearnEvent(id: "p1", course: "en", kind: .practice(skills: ["g1"]), xp: 10,
                                              day: "2026-11-11", at: 2_000), course: c)
        XCTAssertEqual(p.skill("en", "g1").reps, 2)
        XCTAssertTrue(ProgressLogic.rowOpen(p, c, 1))
        p = ProgressLogic.apply(p, LearnEvent(id: "r1", course: "en", kind: .reset, xp: 0, day: "2026-11-11", at: 3_000), course: c)
        XCTAssertFalse(ProgressLogic.isDone(p, c, g1))
        XCTAssertEqual(p.xp["2026-11-11"], 49)
    }

    func testDifficultyFollowsAccuracy() throws {
        let c = try course("en")
        let g1 = try XCTUnwrap(c.skill("g1"))
        let fresh = try XCTUnwrap(c.skill("tra"))
        XCTAssertEqual(ProgressLogic.difficultyLabel(ProgressLogic.difficulty(LearnerProgress(), c, fresh)), "Leicht")

        var strong = LearnerProgress()
        for l in 0..<3 {
            strong = ProgressLogic.apply(strong, LearnEvent(id: "s\(l)", course: "en", kind: .lesson(skill: "g1", lesson: l),
                                                            xp: 13, day: "2026-11-11", at: 1, correct: 20, total: 20), course: c)
        }
        XCTAssertGreaterThan(ProgressLogic.difficulty(strong, c, g1), 0.85)
        XCTAssertGreaterThan(ProgressLogic.difficulty(strong, c, fresh), 0.6, "fresh units inherit the course level")

        var weak = LearnerProgress()
        for l in 0..<3 {
            weak = ProgressLogic.apply(weak, LearnEvent(id: "w\(l)", course: "en", kind: .lesson(skill: "g1", lesson: l),
                                                        xp: 10, day: "2026-11-11", at: 1, correct: 9, total: 20), course: c)
        }
        XCTAssertLessThan(ProgressLogic.difficulty(weak, c, g1), 0.1)

        // Harder sessions contain clearly more free production.
        let index = CourseIndex(c)
        func typedShare(_ d: Double) -> Double {
            var all: [Exercise] = []
            for seed in 0..<50 {
                let builder = LessonBuilder(index, random: AnyRandom(SeededRandom(seed)))
                for skill in c.skills { all += builder.lesson(skill, 1, listening: true, difficulty: d) }
            }
            let typed = all.filter { e in
                switch e {
                case .type, .listen: return true
                default: return false
                }
            }
            return Double(typed.count) / Double(all.count)
        }
        XCTAssertGreaterThan(typedShare(1.0), 2 * typedShare(0.0))

        // Same formula as the server.
        XCTAssertEqual(ProgressLogic.blend(0.8, 10, 10, 10).0, 0.87, accuracy: 1e-9)
    }

    func testStreak() {
        let today = date("2026-11-11")
        XCTAssertEqual(ProgressLogic.streak(["2026-11-10": 5, "2026-11-09": 3], today: today), 2)
        XCTAssertEqual(ProgressLogic.streak(["2026-11-11": 1, "2026-11-10": 5, "2026-11-09": 3], today: today), 3)
        XCTAssertEqual(ProgressLogic.streak(["2026-11-08": 5], today: today), 0)
    }

    func testEventsRoundTrip() throws {
        let events = [
            LearnEvent(id: "a1b2c3d4", course: "fr", kind: .lesson(skill: "g1", lesson: 2), xp: 13, day: "2026-11-11", at: 5, correct: 7, total: 9),
            LearnEvent(id: "e5f6g7h8", course: "fr", kind: .practice(skills: ["g1", "g2"]), xp: 10, day: "2026-11-11", at: 6, correct: 10, total: 10),
            LearnEvent(id: "i9j0k1l2", course: "fr", kind: .reset, xp: 0, day: "2026-11-11", at: 7),
        ]
        XCTAssertEqual(try Codec.parseEvents(Codec.eventsJson(events)), events)
        XCTAssertNotNil(CourseIndex(try course("fr")).hint("C'est", german: false))
    }

    func testSettingsAndProgressRoundTrip() throws {
        let s = Codec.Settings(goal: 30, sound: false, listen: true, course: nil)
        XCTAssertEqual(try Codec.parseSettings(Codec.settingsJson(s)), s)
        let p = LearnerProgress(courses: ["en": ["g1": SkillProgress(lessons: 2, lastPracticed: 1_700_000_000_000, reps: 1, accuracy: 0.5, answers: 8)]],
                         xp: ["2026-11-11": 13])
        XCTAssertEqual(try Codec.parseProgress(Codec.progressJson(p)), p)
    }

    func testFeedbackSoundsAreValidWav() {
        for wav in [FeedbackSounds.tap, FeedbackSounds.correct, FeedbackSounds.pair, FeedbackSounds.wrong, FeedbackSounds.lessonComplete] {
            XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertGreaterThan(wav.count, 1000)
            // The last sample is silence, so the audio never stops in the middle of a wave.
            XCTAssertEqual(wav.suffix(2), Data([0, 0]))
        }
    }
}
