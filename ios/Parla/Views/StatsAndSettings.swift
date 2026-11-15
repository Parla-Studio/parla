import AVFoundation
import ParlaCore
import SwiftUI

// ---------------------------------------------------------------------- Fortschritt

struct StatsTab: View {
    @EnvironmentObject private var repo: Repository
    let course: Course

    private static let goals = [10, 20, 30, 50]
    private static let goalNames = [10: "Locker", 20: "Normal", 30: "Ernsthaft", 50: "Intensiv"]

    var body: some View {
        let st = repo.state
        let p = st.progress
        let answered = (p.courses[course.id] ?? [:]).values.filter { $0.answers > 0 }
        let totalAnswers = answered.reduce(0) { $0 + $1.answers }
        let accuracy: Int? = totalAnswers == 0 ? nil
            : Int(100 * answered.reduce(0.0) { $0 + $1.accuracy * Double($1.answers) } / Double(totalAnswers))
        let doneUnits = course.skills.filter { ProgressLogic.isDone(p, course, $0) }.count
        let goal = st.settings.goal
        let selected = Self.goals.contains(goal) ? goal : 20
        let selectedName = Self.goalNames[selected] ?? "Normal"
        NavigationStack {
            List {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        StatTile(emoji: "🔥", value: "\(ProgressLogic.streak(p.xp))", label: "Tage in Folge")
                        StatTile(emoji: "⚡", value: "\(p.xp.values.reduce(0, +))", label: "XP gesamt")
                        StatTile(emoji: course.flag, value: "\(doneUnits)/\(course.skills.count)", label: "Einheiten fertig")
                        StatTile(emoji: "🎯", value: accuracy.map { "\($0) %" } ?? "–", label: "richtig beantwortet")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section("Diese Woche") {
                    WeekChart(xp: p.xp, goal: goal).padding(.vertical, 8)
                }
                Section {
                    Picker("Tagesziel", selection: Binding(
                        get: { goal },
                        set: { v in repo.updateSettings { $0.goal = v } }
                    )) {
                        ForEach(Self.goals, id: \.self) { g in Text("\(g)").tag(g) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Tagesziel")
                } footer: {
                    Text("\(selectedName): \(selected) XP am Tag – das sind etwa \(selected / 12 + 1) Lektionen.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Fortschritt")
        }
    }
}

private struct StatTile: View {
    let emoji: String
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(emoji).font(.title2)
            Text(value).font(.title2.bold()).padding(.top, 2)
            Text(label).font(.footnote).foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// XP of the last seven days as bars, with the daily goal as a dashed line.
private struct WeekChart: View {
    let xp: [String: Int]
    let goal: Int

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEEEE"
        return f
    }()

    var body: some View {
        let today = Date()
        let days = (0..<7).reversed().map { Days.adding(-$0, to: today) }
        let values = days.map { xp[Days.key($0)] ?? 0 }
        let top = max(Double(goal) * 1.25, Double(values.max() ?? 0), 10)
        let area: CGFloat = 120
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(0..<7, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(values[i] >= goal ? Palette.green : (i == 6 ? Palette.blue : Palette.blue.opacity(0.45)))
                            .frame(height: max(2, area * CGFloat(Double(values[i]) / top)))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: area, alignment: .bottom)
                GeometryReader { geo in
                    let y = geo.size.height * (1 - CGFloat(Double(goal) / top))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Palette.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                }
                .frame(height: area)
            }
            HStack(spacing: 10) {
                ForEach(0..<7, id: \.self) { i in
                    Text(Self.weekday.string(from: days[i]))
                        .font(.footnote.weight(i == 6 ? .semibold : .regular))
                        .foregroundStyle(i == 6 ? Color.primary : Palette.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 6) {
                Rectangle().fill(Palette.orange).frame(width: 16, height: 2)
                Text("Tagesziel \(goal) XP").font(.footnote).foregroundStyle(Palette.secondary)
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heute \(values[6]) XP, Tagesziel \(goal) XP")
    }
}

// ---------------------------------------------------------------------- Einstellungen

struct SettingsTab: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    let course: Course

    private enum Dialog {
        case reset, logout
    }

    @State private var confirm: Dialog?
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var deletePassword = ""
    @State private var showPassword = false
    @State private var showDelete = false
    @State private var resultTitle = ""
    @State private var resultMessage: String?
    @AppStorage(Audio.genderKey) private var voiceGender = Audio.VoiceGender.female.rawValue

    /// First sentence of the course, used to try voices.
    private var sampleSentence: String {
        course.skills.first?.sentences.first?.target.first ?? "Hello"
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        let st = repo.state
        NavigationStack {
            List {
                Section("Kurs") {
                    Button { model.showCoursePicker = true } label: {
                        HStack(spacing: 14) {
                            IconTile(emoji: "🌍", color: Palette.blue)
                            Text("Ich lerne").foregroundStyle(Color.primary)
                            Spacer()
                            Text("\(course.flag) \(course.name)").foregroundStyle(Palette.secondary)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    Toggle(isOn: Binding(get: { st.settings.sound }, set: { v in repo.updateSettings { $0.sound = v } })) {
                        Label { Text("Töne") } icon: { IconTile(emoji: "🔔", color: Palette.red, size: 30) }
                    }
                    Toggle(isOn: Binding(get: { st.settings.listen }, set: { v in repo.updateSettings { $0.listen = v } })) {
                        Label { Text("Hörübungen") } icon: { IconTile(emoji: "🎧", color: Palette.purple, size: 30) }
                    }
                } header: {
                    Text("Lernen")
                } footer: {
                    if !voiceAvailable {
                        Text("Für \(course.name) ist auf diesem Gerät keine Stimme installiert. Du kannst sie unter Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen laden.")
                    }
                }
                Section {
                    Picker(selection: $voiceGender) {
                        ForEach(Audio.VoiceGender.allCases) { g in Text(g.label).tag(g.rawValue) }
                    } label: {
                        Label { Text("Stimme") } icon: { IconTile(emoji: "🗣️", color: Palette.blue, size: 30) }
                    }
                    .onChange(of: voiceGender) {
                        // A new preference replaces a voice picked by hand, so the change is heard right away.
                        UserDefaults.standard.removeObject(forKey: Audio.voiceKey(course.tts))
                        model.audio.preview(sampleSentence, voice: nil, tag: course.tts)
                    }
                    NavigationLink {
                        VoicePickerView(course: course, sample: sampleSentence)
                    } label: {
                        LabeledContent("Stimme für \(course.name)", value: model.audio.voice(for: course.tts)?.name ?? "keine")
                    }
                } header: {
                    Text("Sprachausgabe")
                } footer: {
                    Text("Weitere und bessere Stimmen kannst du unter Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen laden.")
                }
                Section {
                    Toggle(isOn: Binding(get: { st.largeText }, set: { repo.setLargeText($0) })) {
                        Label { Text("Große Schrift") } icon: { IconTile(emoji: "🔍", color: Palette.teal, size: 30) }
                    }
                } header: {
                    Text("Anzeige")
                } footer: {
                    Text("Macht alle Texte in der App größer.")
                }
                Section {
                    LabeledContent {
                        Text(st.username ?? "")
                    } label: {
                        Label { Text("Angemeldet als") } icon: { IconTile(emoji: "👤", color: Palette.gray, size: 30) }
                    }
                    Button { model.sync() } label: {
                        HStack {
                            Label { Text("Jetzt speichern").foregroundStyle(Color.primary) } icon: { IconTile(emoji: "🔄", color: Palette.green, size: 30) }
                            Spacer()
                            if st.syncing { ProgressView() }
                        }
                    }
                    Button { oldPassword = ""; newPassword = ""; showPassword = true } label: {
                        Label { Text("Passwort ändern").foregroundStyle(Color.primary) } icon: { IconTile(emoji: "🔑", color: Palette.orange, size: 30) }
                    }
                    Button { confirm = .logout } label: {
                        Label { Text("Abmelden") } icon: { IconTile(emoji: "🚪", color: Palette.blue, size: 30) }
                    }
                } header: {
                    Text("Konto")
                } footer: {
                    Text(st.offline ? "Gerade keine Verbindung. Dein Fortschritt wird gespeichert, sobald du wieder online bist."
                         : st.pendingEvents > 0 ? "\(st.pendingEvents) Ergebnis(se) werden gleich gespeichert."
                         : "Dein Fortschritt ist sicher auf dem Server gespeichert.")
                }
                Section {
                    Button("\(course.name) von vorne beginnen", role: .destructive) { confirm = .reset }
                    Button("Konto löschen", role: .destructive) { deletePassword = ""; showDelete = true }
                } footer: {
                    Text("Parla \(version) · \(st.serverUrl.replacingOccurrences(of: "https://", with: ""))")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Einstellungen")
            .refreshable { await repo.sync() }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            switch confirm {
            case .reset:
                Button("Zurücksetzen", role: .destructive) { repo.resetCourse(course.id) }
            case .logout:
                Button("Abmelden", role: .destructive) { model.logout() }
            default:
                EmptyView()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(confirmMessage(st))
        }
        .alert("Passwort ändern", isPresented: $showPassword) {
            SecureField("Aktuelles Passwort", text: $oldPassword)
            SecureField("Neues Passwort (mind. 8 Zeichen)", text: $newPassword)
            Button("Ändern") { changePassword() }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Konto löschen?", isPresented: $showDelete) {
            SecureField("Passwort zur Bestätigung", text: $deletePassword)
            Button("Löschen", role: .destructive) { deleteAccount() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Dein Konto und dein ganzer Fortschritt werden für immer gelöscht.")
        }
        .alert(resultTitle, isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("OK", role: .cancel) { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private var voiceAvailable: Bool {
        model.audio.setLanguage(course.tts)
        return model.audio.available
    }

    private var confirmTitle: String {
        switch confirm {
        case .reset: return "\(course.name) von vorne beginnen?"
        case .logout: return "Abmelden?"
        default: return ""
        }
    }

    private func confirmMessage(_ st: AppState) -> String {
        switch confirm {
        case .reset:
            return "Alle Einheiten in \(course.name) werden zurückgesetzt. Deine XP und deine Serie bleiben."
        case .logout:
            return st.pendingEvents > 0
                ? "Es gibt noch Ergebnisse, die nicht gespeichert sind. Ohne Internet gehen sie verloren."
                : "Dein Fortschritt bleibt auf dem Server. Du kannst dich jederzeit wieder anmelden."
        default:
            return ""
        }
    }

    private func changePassword() {
        let old = oldPassword
        let new = newPassword
        if new.count < 8 {
            resultTitle = "Passwort nicht geändert"
            resultMessage = "Das neue Passwort braucht mindestens 8 Zeichen."
            return
        }
        Task {
            if let error = await model.changePassword(old: old, new: new) {
                resultTitle = "Passwort nicht geändert"
                resultMessage = error
            } else {
                resultTitle = "Passwort geändert"
                resultMessage = "Auf deinen anderen Geräten musst du dich neu anmelden."
            }
        }
    }

    private func deleteAccount() {
        let password = deletePassword
        Task {
            if let error = await model.deleteAccount(password: password) {
                resultTitle = "Konto nicht gelöscht"
                resultMessage = error
            }
        }
    }
}

// ---------------------------------------------------------------------- voice picker

/// All installed voices for the course language; tapping one selects it and plays a sample.
private struct VoicePickerView: View {
    @EnvironmentObject private var model: AppModel
    let course: Course
    let sample: String
    @State private var chosenId: String?

    private static let german = Locale(identifier: "de_DE")

    var body: some View {
        let voices = model.audio.voices(for: course.tts)
        List {
            Section {
                row(title: "Automatisch", subtitle: "Beste Stimme – \(model.audio.gender.label.lowercased())", id: nil)
            }
            Section {
                ForEach(voices, id: \.identifier) { v in
                    row(title: v.name, subtitle: description(v), id: v.identifier)
                }
            } footer: {
                Text("Antippen zum Auswählen und Anhören. Weitere Stimmen: Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Stimme")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { chosenId = UserDefaults.standard.string(forKey: Audio.voiceKey(course.tts)) }
        .onDisappear { model.audio.stop() }
    }

    private func row(title: String, subtitle: String, id: String?) -> some View {
        Button {
            chosenId = id
            if let id {
                UserDefaults.standard.set(id, forKey: Audio.voiceKey(course.tts))
            } else {
                UserDefaults.standard.removeObject(forKey: Audio.voiceKey(course.tts))
            }
            model.audio.preview(sample, voice: id.flatMap { AVSpeechSynthesisVoice(identifier: $0) }, tag: course.tts)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Color.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(Palette.secondary)
                }
                Spacer()
                if chosenId == id {
                    Image(systemName: "checkmark").foregroundStyle(Palette.blue).accessibilityLabel("ausgewählt")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func description(_ v: AVSpeechSynthesisVoice) -> String {
        var parts = [Self.german.localizedString(forIdentifier: v.language) ?? v.language]
        switch v.gender {
        case .female: parts.append("weiblich")
        case .male: parts.append("männlich")
        default: break
        }
        switch v.quality {
        case .premium: parts.append("Premium")
        case .enhanced: parts.append("Erweitert")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}
