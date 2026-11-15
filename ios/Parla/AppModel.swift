import Foundation
import ParlaCore
import SwiftUI

/// What the main area shows (when logged in and a course is chosen).
enum Screen {
    case home
    case lesson(LessonSession)
    case result(LessonResult)
    case failed(retry: @MainActor () -> Void)
}

struct LessonResult {
    let title: String
    let detail: String?
    let xp: Int
    let mistakes: Int
    let goalReached: Bool
    /// Share of correct answers in percent, nil if nothing was graded.
    let accuracy: Int?
}

enum Tab: Hashable {
    case learn, stats, settings
}

/// State of a running lesson or practice session (same as LessonSession in the Kotlin apps).
@MainActor
final class LessonSession: ObservableObject {
    let course: Course
    let index: CourseIndex
    /// Skill + lesson for a lesson, or the practised skills for a practice session.
    let skillId: String?
    let lessonIndex: Int?
    let practiceSkills: [String]
    /// Difficulty the session was built with (0...1); see ProgressLogic.difficulty.
    let difficulty: Double

    @Published var exercises: [Exercise]
    @Published var position = 0
    @Published var hearts = ProgressLogic.hearts
    @Published var mistakes = 0
    /// Nil while answering; set after "Prüfen".
    @Published var feedback: Feedback?
    var failed = false

    /// Graded answers (match exercises are not graded).
    var answered = 0
    var correctAnswers = 0
    /// Runs of right/wrong answers, used to adjust the upcoming exercises during the session.
    var rightInARow = 0
    var wrongInARow = 0

    var current: Exercise { exercises[position] }
    var isPractice: Bool { skillId == nil }

    /// `skipped`: "Weiß ich nicht" was pressed – shown as a hint with the solution, but counted as a mistake.
    struct Feedback: Equatable {
        let correct: Bool
        let note: String?
        let solution: String
        var skipped = false
    }

    init(course: Course, index: CourseIndex, exercises: [Exercise], skillId: String?, lessonIndex: Int?,
         practiceSkills: [String], difficulty: Double) {
        self.course = course
        self.index = index
        self.exercises = exercises
        self.skillId = skillId
        self.lessonIndex = lessonIndex
        self.practiceSkills = practiceSkills
        self.difficulty = difficulty
    }
}

/// UI logic shared by all screens (the same as AppViewModel in the Kotlin apps).
@MainActor
final class AppModel: ObservableObject {
    let repo: Repository
    let audio = Audio()

    @Published var screen: Screen = .home
    @Published var tab: Tab = .learn
    @Published var busy = false
    @Published var error: String?
    @Published var showCoursePicker = false

    private var indexes: [String: CourseIndex] = [:]

    init(repo: Repository) {
        self.repo = repo
        // Speaker pressed but no voice for the course language: say so instead of staying silent.
        audio.onMissingVoice = { [weak self] in
            guard let self else { return }
            let name = self.repo.state.course?.name ?? "diese Sprache"
            self.repo.showMessage("Für \(name) ist auf diesem Gerät keine Stimme installiert – mehr dazu in den Einstellungen.")
        }
    }

    private var state: AppState { repo.state }
    private var sound: Bool { state.settings.sound }

    /// Soft click sound when a word or an answer is picked.
    func tap() { audio.tap(enabled: sound) }

    private func indexFor(_ c: Course) -> CourseIndex {
        if let i = indexes[c.id], i.course.hash == c.hash { return i }
        let i = CourseIndex(c)
        indexes[c.id] = i
        return i
    }

    // ------------------------------------------------------------------ account

    func authenticate(server: String, username: String, password: String, register: Bool) {
        if busy { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await repo.authenticate(serverUrl: server, username: username.trimmingCharacters(in: .whitespaces),
                                            password: password, register: register)
                screen = .home
            } catch let e as ApiError {
                error = e.message
            } catch let e as OfflineError {
                error = e.reason
            } catch {
                self.error = "Unerwarteter Fehler: \(error.localizedDescription)"
            }
        }
    }

    func logout() {
        Task {
            busy = true
            _ = await repo.logout()
            busy = false
            screen = .home
            tab = .learn
        }
    }

    /// Returns nil on success, otherwise a message for the user.
    func changePassword(old: String, new: String) async -> String? {
        do {
            try await repo.changePassword(old: old, new: new)
            return nil
        } catch let e as ApiError {
            return e.message
        } catch {
            return "Keine Verbindung zum Server."
        }
    }

    func deleteAccount(password: String) async -> String? {
        do {
            try await repo.deleteAccount(password: password)
            screen = .home
            return nil
        } catch let e as ApiError {
            return e.message
        } catch {
            return "Keine Verbindung zum Server."
        }
    }

    func sync() { repo.syncInBackground() }

    func selectCourse(_ id: String) {
        repo.updateSettings { $0.course = id }
        showCoursePicker = false
        screen = .home
        tab = .learn
    }

    // ------------------------------------------------------------------ lessons

    private func builder(_ c: Course) -> LessonBuilder { LessonBuilder(indexFor(c)) }

    private func listening(_ c: Course) -> Bool {
        audio.setLanguage(c.tts)
        return state.settings.listen && audio.available
    }

    func difficulty(_ c: Course, _ skill: Skill) -> Double { ProgressLogic.difficulty(state.progress, c, skill) }

    /// The lesson the learner should do next: first unlocked unit that isn't finished.
    func nextLesson(_ c: Course) -> (Skill, Int)? {
        let p = state.progress
        guard let skill = c.skills.first(where: { ProgressLogic.rowOpen(p, c, $0.row) && !ProgressLogic.isDone(p, c, $0) }) else {
            return nil
        }
        return (skill, p.skill(c.id, skill.id).lessons)
    }

    /// Finished units that are fading and should be reviewed.
    func weakSkills(_ c: Course) -> [Skill] {
        let p = state.progress
        return c.skills.filter { ProgressLogic.isDone(p, c, $0) && ProgressLogic.strength(p, c, $0) < 4 }
    }

    /// `ease` lowers the difficulty, e.g. for a retry after running out of hearts.
    func startLesson(_ skill: Skill, _ lesson: Int, ease: Double = 0) {
        guard let c = state.course else { return }
        audio.setLanguage(c.tts)
        let d = max(0, difficulty(c, skill) - ease)
        let list = builder(c).lesson(skill, lesson, listening: listening(c), difficulty: d)
        screen = .lesson(LessonSession(course: c, index: indexFor(c), exercises: list, skillId: skill.id, lessonIndex: lesson,
                                       practiceSkills: [], difficulty: d))
    }

    /// Practice one skill, or the weakest finished ones when `skill` is nil.
    func startPractice(_ skill: Skill?) {
        guard let c = state.course else { return }
        let p = state.progress
        let skills: [Skill]
        if let skill {
            skills = [skill]
        } else {
            skills = Array(c.skills.filter { ProgressLogic.isDone(p, c, $0) }.sorted { a, b in
                let sa = ProgressLogic.strength(p, c, a)
                let sb = ProgressLogic.strength(p, c, b)
                if sa != sb { return sa < sb }
                return p.skill(c.id, a.id).lastPracticed < p.skill(c.id, b.id).lastPracticed
            }.prefix(3))
        }
        if skills.isEmpty { return }
        audio.setLanguage(c.tts)
        startPracticeSkills(c, skills.map { $0.id })
    }

    private func startPracticeSkills(_ c: Course, _ ids: [String], ease: Double = 0) {
        let skills = ids.compactMap { c.skill($0) }
        if skills.isEmpty { return }
        let average = skills.map { difficulty(c, $0) }.reduce(0, +) / Double(skills.count)
        let d = max(0, average - ease)
        let list = builder(c).practice(skills, listening: listening(c), difficulty: d)
        screen = .lesson(LessonSession(course: c, index: indexFor(c), exercises: list, skillId: nil, lessonIndex: nil,
                                       practiceSkills: ids, difficulty: d))
    }

    /// Grades the current exercise. `answer` is typed text or the assembled chips; `choice` for options.
    func check(_ s: LessonSession, answer: String?, choice: String?, forceWrong: Bool = false) {
        if s.feedback != nil { return }
        let ex = s.current
        let grade: Grading.Grade
        if forceWrong {
            grade = Grading.Grade(correct: false)
        } else {
            switch ex {
            // The course's words in the answer language tell real words from typos (ist/isst is a mistake).
            case let .bank(e): grade = Grading.grade(answer ?? "", accepted: e.accepted, known: s.index.known(german: e.toGerman))
            case let .type(e): grade = Grading.grade(answer ?? "", accepted: e.accepted, known: s.index.known(german: e.toGerman))
            case let .listen(e): grade = Grading.grade(answer ?? "", accepted: e.sentence.target, known: s.index.known(german: false))
            case .choice, .word: grade = Grading.Grade(correct: choice == ex.solution)
            case .match: grade = Grading.Grade(correct: true)
            }
        }
        if !grade.correct {
            s.mistakes += 1
            if s.hearts == 0 { s.failed = true } else { s.hearts -= 1 }
        }
        if !ex.isMatch {
            s.answered += 1
            if grade.correct { s.correctAnswers += 1 }
            adapt(s, correct: grade.correct)
        }
        // Skipping is not "wrong" for the ear: no error sound, the solution is shown as a hint.
        if !forceWrong { audio.feedback(correct: grade.correct, enabled: sound) }
        if !grade.correct && !forceWrong { Haptics.error() }
        let spoken: String?
        switch ex {
        case let .bank(e): spoken = e.toGerman ? nil : e.sentence.target[0]
        case let .type(e): spoken = e.toGerman ? nil : e.sentence.target[0]
        case let .listen(e): spoken = e.sentence.target[0]
        default: spoken = nil
        }
        if let spoken { audio.speak(spoken) }
        s.feedback = LessonSession.Feedback(correct: grade.correct, note: grade.note, solution: ex.solution, skipped: forceWrong)
    }

    func next(_ s: LessonSession) {
        if s.failed {
            screen = .failed(retry: { [weak self] in
                guard let self else { return }
                // The retry is a bit easier than the attempt that failed.
                if s.isPractice {
                    self.startPracticeSkills(s.course, s.practiceSkills, ease: 0.3)
                } else if let id = s.skillId, let skill = s.course.skill(id), let lesson = s.lessonIndex {
                    self.startLesson(skill, lesson, ease: 0.3)
                }
            })
            return
        }
        if s.position + 1 >= s.exercises.count {
            finish(s)
            return
        }
        s.feedback = nil
        s.position += 1
    }

    /// In-session adaptation: two mistakes in a row make the next exercises easier, four correct answers in a
    /// row make the next ones harder. The long-term level comes from the accuracy stored per skill.
    private func adapt(_ s: LessonSession, correct: Bool) {
        if correct {
            s.wrongInARow = 0
            s.rightInARow += 1
            if s.rightInARow >= 4 {
                s.exercises = builder(s.course).adjust(s.exercises, from: s.position + 1, harder: true, count: 2)
                s.rightInARow = 0
            }
        } else {
            s.rightInARow = 0
            s.wrongInARow += 1
            if s.wrongInARow >= 2 {
                s.exercises = builder(s.course).adjust(s.exercises, from: s.position + 1, harder: false, count: 3)
                s.wrongInARow = 0
            }
        }
    }

    /// "Can't listen now": turn this session's listening exercises into word-bank exercises.
    func skipListening(_ s: LessonSession) {
        s.exercises = builder(s.course).withoutListening(s.exercises)
    }

    private func finish(_ s: LessonSession) {
        let before = state.progress.xp[Days.key()] ?? 0
        let c = s.course
        var title: String
        var detail: String?
        let xp: Int
        if s.isPractice {
            xp = repo.completePractice(course: c.id, skills: s.practiceSkills, correct: s.correctAnswers, total: s.answered)
            title = "Training abgeschlossen!"
            detail = "Deine Fertigkeiten sind wieder voll aufgeladen."
        } else if let id = s.skillId, let skill = c.skill(id), let lesson = s.lessonIndex {
            let wasDone = ProgressLogic.isDone(state.progress, c, skill)
            xp = repo.completeLesson(course: c.id, skill: skill.id, lesson: lesson, heartsLeft: s.hearts,
                                     correct: s.correctAnswers, total: s.answered)
            let nowDone = ProgressLogic.isDone(state.progress, c, skill)
            if !wasDone && nowDone {
                title = "Fertigkeit gemeistert!"
                detail = "\(skill.icon) \(skill.title) ist jetzt golden."
            } else {
                title = "Lektion abgeschlossen!"
            }
        } else {
            screen = .home
            return
        }
        let goal = state.settings.goal
        let accuracy: Int? = s.answered > 0 ? 100 * s.correctAnswers / s.answered : nil
        audio.lessonComplete(enabled: sound)
        screen = .result(LessonResult(title: title, detail: detail, xp: xp, mistakes: s.mistakes,
                                      goalReached: before < goal && before + xp >= goal, accuracy: accuracy))
    }

    func quitLesson() {
        audio.stop()
        screen = .home
    }
}
