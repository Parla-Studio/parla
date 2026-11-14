import ParlaCore
import SwiftUI

/// Tab bar with Lernen, Fortschritt and Einstellungen.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let course: Course

    var body: some View {
        TabView(selection: $model.tab) {
            LearnTab(course: course)
                .tabItem { Label("Lernen", systemImage: "house.fill") }
                .tag(Tab.learn)
            StatsTab(course: course)
                .tabItem { Label("Fortschritt", systemImage: "star.fill") }
                .tag(Tab.stats)
            SettingsTab(course: course)
                .tabItem { Label("Einstellungen", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .sheet(isPresented: $model.showCoursePicker) {
            NavigationStack { CoursePickerView(firstTime: false) }
        }
    }
}

// ---------------------------------------------------------------------- Lernen

private struct LearnTab: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    let course: Course
    @State private var openSkill: Skill?
    @State private var lockedSkill: Skill?

    /// Units grouped by level, in course order.
    private var groups: [(level: String?, skills: [Skill])] {
        var result: [(level: String?, skills: [Skill])] = []
        for s in course.skills {
            if let last = result.last, last.level == s.level {
                result[result.count - 1].skills.append(s)
            } else {
                result.append((s.level, [s]))
            }
        }
        return result
    }

    var body: some View {
        let p = repo.state.progress
        NavigationStack {
            List {
                Section { TodayCard() }
                Section { ContinueCard(course: course) }
                if course.skills.contains(where: { ProgressLogic.isDone(p, course, $0) }) {
                    let weak = model.weakSkills(course)
                    Section {
                        Button { model.startPractice(nil) } label: {
                            RowLabel(
                                title: weak.isEmpty ? "Üben" : "Wiederholen",
                                subtitle: weak.isEmpty ? "Gelerntes festigen"
                                    : "\(weak.count) \(weak.count == 1 ? "Einheit verblasst" : "Einheiten verblassen") – kurz auffrischen",
                                emoji: "💪", color: Palette.orange, chevron: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Section(levelName(group.level)) {
                        ForEach(group.skills) { skill in
                            Button {
                                if ProgressLogic.rowOpen(p, course, skill.row) { openSkill = skill } else { lockedSkill = skill }
                            } label: {
                                UnitRow(course: course, skill: skill, progress: p)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Lernen")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showCoursePicker = true } label: {
                        Text("\(course.flag) \(course.name)").font(.callout.weight(.semibold))
                    }
                    .accessibilityLabel("Kurs wechseln, aktuell \(course.name)")
                }
            }
            .refreshable { await repo.sync() }
            .sheet(item: $openSkill) { skill in
                UnitSheet(course: course, skill: skill)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .alert("Noch gesperrt", isPresented: Binding(get: { lockedSkill != nil }, set: { if !$0 { lockedSkill = nil } })) {
                Button("OK", role: .cancel) { lockedSkill = nil }
            } message: {
                Text("„\(lockedSkill?.title ?? "")“ wird frei, sobald du die Einheiten davor abgeschlossen hast.")
            }
        }
    }
}

/// A list row with an icon tile, title and subtitle.
struct RowLabel: View {
    let title: String
    var subtitle: String?
    var emoji: String?
    var color: Color = Palette.blue
    var titleColor: Color = .primary
    var dimmed = false
    var chevron = false

    var body: some View {
        HStack(spacing: 14) {
            if let emoji { IconTile(emoji: emoji, color: color, dimmed: dimmed) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(titleColor)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(Palette.secondary)
                }
            }
            Spacer(minLength: 8)
            if chevron {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct TodayCard: View {
    @EnvironmentObject private var repo: Repository

    var body: some View {
        let st = repo.state
        let today = st.progress.xp[Days.key()] ?? 0
        let streak = ProgressLogic.streak(st.progress.xp)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Heute").font(.footnote).foregroundStyle(Palette.secondary)
                    Text("\(today) von \(st.settings.goal) XP").font(.headline)
                    ProgressBar(value: Double(today) / Double(max(1, st.settings.goal)), color: Palette.orange)
                        .padding(.top, 4)
                }
                VStack(spacing: 2) {
                    Text("🔥").font(.title2)
                    Text("\(streak) \(streak == 1 ? "Tag" : "Tage")").font(.subheadline.weight(.semibold))
                }
            }
            if st.syncing || st.offline || st.pendingEvents > 0 {
                Divider()
                HStack(spacing: 8) {
                    if st.syncing { ProgressView().controlSize(.small) }
                    Text(st.syncing ? "Wird gespeichert …"
                         : st.offline ? "Offline – dein Fortschritt wird später gespeichert."
                         : "Wird gleich gespeichert.")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ContinueCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    let course: Course

    var body: some View {
        // Read the state so the card updates with the progress.
        let _ = repo.state.progress
        VStack(alignment: .leading, spacing: 14) {
            if let next = model.nextLesson(course) {
                let skill = next.0
                let lesson = next.1
                HStack(spacing: 14) {
                    IconTile(emoji: skill.icon, color: Color(rgb: skill.color), size: 60)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lesson == 0 ? "Als Nächstes" : "Weiter lernen").font(.footnote).foregroundStyle(Palette.secondary)
                        Text(skill.title).font(.title3.weight(.semibold))
                        Text("Lektion \(lesson + 1) von \(skill.lessonCount) · \(ProgressLogic.difficultyLabel(model.difficulty(course, skill)))")
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondary)
                    }
                }
                Button("Lektion starten") { model.startLesson(skill, lesson) }
                    .buttonStyle(.primary)
            } else {
                Text("Alles geschafft! 🎉").font(.title3.weight(.semibold))
                Text("Du hast alle Einheiten abgeschlossen. Mit „Üben“ hältst du alles frisch.")
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                Button("Jetzt üben") { model.startPractice(nil) }
                    .buttonStyle(.primary)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct UnitRow: View {
    let course: Course
    let skill: Skill
    let progress: LearnerProgress

    var body: some View {
        let open = ProgressLogic.rowOpen(progress, course, skill.row)
        let sp = progress.skill(course.id, skill.id)
        let done = sp.lessons >= skill.lessonCount
        let strength = ProgressLogic.strength(progress, course, skill)
        HStack(spacing: 14) {
            IconTile(emoji: skill.icon, color: Color(rgb: skill.color), dimmed: !open)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(open ? Color.primary : Palette.secondary)
                Text(!open ? "Gesperrt"
                     : done && strength < 4 ? "Fertig · bitte wiederholen"
                     : done ? "Fertig"
                     : sp.lessons > 0 ? "Lektion \(sp.lessons + 1) von \(skill.lessonCount)"
                     : "\(skill.lessonCount) Lektionen")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 8)
            if !open {
                Image(systemName: "lock.fill").foregroundStyle(Palette.tertiary).accessibilityLabel("gesperrt")
            } else if done {
                StrengthBars(strength: strength)
            } else {
                if sp.lessons > 0 {
                    ProgressBar(value: Double(sp.lessons) / Double(skill.lessonCount), height: 6).frame(width: 56)
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Details of a unit: progress, words and lesson buttons.
private struct UnitSheet: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let course: Course
    let skill: Skill

    var body: some View {
        let p = repo.state.progress
        let sp = p.skill(course.id, skill.id)
        let done = sp.lessons >= skill.lessonCount
        let strength = ProgressLogic.strength(p, course, skill)
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        IconTile(emoji: skill.icon, color: Color(rgb: skill.color), size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.title).font(.title2.bold())
                            Text(done && strength >= 5 ? "Fertig – sitzt sicher"
                                 : done ? "Fertig – Stärke \(strength) von 5"
                                 : "Lektion \(sp.lessons + 1) von \(skill.lessonCount)")
                                .font(.callout)
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    if let level = skill.level { LabeledContent("Stufe", value: level) }
                    LabeledContent("Schwierigkeit", value: ProgressLogic.difficultyLabel(model.difficulty(course, skill)))
                    if sp.answers > 0 { LabeledContent("Richtige Antworten", value: "\(Int(sp.accuracy * 100)) %") }
                } footer: {
                    Text("Die Aufgaben passen sich deinen Antworten an.")
                }
                Section("Wörter") {
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(skill.words, id: \.self) { w in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(w.target).font(.callout.weight(.semibold))
                                Text(w.german).font(.footnote).foregroundStyle(Palette.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Palette.fillLight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    VStack(spacing: 10) {
                        if done {
                            Button("Üben") { start { model.startPractice(skill) } }.buttonStyle(.primary)
                            ForEach(0..<skill.lessonCount, id: \.self) { i in
                                Button("Lektion \(i + 1) wiederholen") { start { model.startLesson(skill, i) } }
                                    .buttonStyle(.primary(.tinted))
                            }
                        } else {
                            Button("Lektion \(sp.lessons + 1) starten") { start { model.startLesson(skill, sp.lessons) } }
                                .buttonStyle(.primary)
                            if sp.lessons > 0 {
                                Button("Lektion \(sp.lessons) wiederholen") { start { model.startLesson(skill, sp.lessons - 1) } }
                                    .buttonStyle(.primary(.tinted))
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .listStyle(.insetGrouped)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { dismiss() } }
            }
        }
    }

    private func start(_ action: @escaping @MainActor () -> Void) {
        dismiss()
        // Start after the sheet has closed, so the lesson does not appear behind it.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            action()
        }
    }
}

// ---------------------------------------------------------------------- course picker

struct CoursePickerView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    let firstTime: Bool

    var body: some View {
        let st = repo.state
        List {
            Section {
                ForEach(st.courses) { c in
                    let done = c.skills.filter { ProgressLogic.isDone(st.progress, c, $0) }.count
                    Button { model.selectCourse(c.id) } label: {
                        HStack(spacing: 14) {
                            Text(c.flag).font(.system(size: 34)).frame(width: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.body.weight(.medium))
                                Text("\(done) von \(c.skills.count) Einheiten").font(.subheadline).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            if c.id == st.settings.course {
                                Image(systemName: "checkmark").foregroundStyle(Palette.blue).accessibilityLabel("ausgewählt")
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Alle Kurse sind für Deutschsprachige. Dein Fortschritt bleibt pro Kurs gespeichert.")
                    .textCase(nil)
                    .font(.callout)
                    .padding(.bottom, 8)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(firstTime ? "Was möchtest du lernen?" : "Kurs wählen")
        .toolbar {
            if !firstTime {
                ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { model.showCoursePicker = false } }
            }
        }
    }
}
