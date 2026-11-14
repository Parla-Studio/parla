import ParlaCore
import SwiftUI

struct LessonView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: LessonSession

    // Per-exercise answer state; reset whenever the exercise changes.
    @State private var answer = ""
    @State private var choice: String?
    @State private var ready = false
    @State private var confirmQuit = false

    /// Changes when the exercise on screen changes (next exercise, or a listening exercise turned into a word bank).
    private var exerciseKey: String {
        let kind: String
        switch session.current {
        case .bank: kind = "bank"
        case .type: kind = "type"
        case .listen: kind = "listen"
        case .choice: kind = "choice"
        case .word: kind = "word"
        case .match: kind = "match"
        }
        return "\(session.position)-\(kind)"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                exercise
                    .id(exerciseKey)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            bottom
        }
        .background(Color(uiColor: .systemBackground))
        .onChange(of: exerciseKey) {
            answer = ""
            choice = nil
            ready = false
        }
        .alert("Lektion beenden?", isPresented: $confirmQuit) {
            Button("Beenden", role: .destructive) { model.quitLesson() }
            Button("Weiterlernen", role: .cancel) {}
        } message: {
            Text("Was du in dieser Lektion gemacht hast, wird nicht gespeichert.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { confirmQuit = true } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 40, height: 40)
                    .background(Palette.fillLight, in: Circle())
            }
            .accessibilityLabel("Lektion beenden")
            ProgressBar(value: Double(session.position) / Double(max(1, session.exercises.count)), color: Palette.green, height: 10)
            HStack(spacing: 2) {
                ForEach(0..<ProgressLogic.hearts, id: \.self) { i in
                    Image(systemName: "heart.fill")
                        .foregroundStyle(i < session.hearts ? Palette.red : Palette.fill)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(session.hearts) Herzen")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var exercise: some View {
        let locked = session.feedback != nil
        switch session.current {
        case let .bank(e):
            BankView(session: session, exercise: e, locked: locked) { text in
                answer = text
                ready = !text.trimmingCharacters(in: .whitespaces).isEmpty
            }
        case let .type(e):
            VStack(alignment: .leading, spacing: 0) {
                Instruction(text: e.toGerman ? "Schreib das auf Deutsch" : "Schreib das auf \(session.course.name)")
                PromptView(session: session, text: e.prompt, german: !e.toGerman, speak: e.toGerman)
                AnswerField(session: session, targetLanguage: !e.toGerman, locked: locked, text: $answer)
            }
            .onChange(of: answer) { ready = !answer.trimmingCharacters(in: .whitespaces).isEmpty }
        case let .listen(e):
            ListenView(session: session, exercise: e, locked: locked, text: $answer)
                .onChange(of: answer) { ready = !answer.trimmingCharacters(in: .whitespaces).isEmpty }
        case let .choice(e):
            VStack(alignment: .leading, spacing: 0) {
                Instruction(text: "Was bedeutet das?")
                PromptView(session: session, text: e.sentence.target[0], german: false, speak: true)
                OptionsView(options: e.options, selected: choice, locked: locked) { picked in
                    choice = picked
                    ready = true
                    model.tap()
                }
            }
        case let .word(e):
            VStack(alignment: .leading, spacing: 0) {
                Instruction(text: "Welches Wort bedeutet „\(e.word.german)“?")
                OptionsView(options: e.options, selected: choice, locked: locked) { picked in
                    choice = picked
                    ready = true
                    model.tap()
                    model.audio.speak(picked)
                }
            }
        case let .match(e):
            MatchView(exercise: e, locked: locked) { ready = true }
        }
    }

    @ViewBuilder
    private var bottom: some View {
        if let fb = session.feedback {
            FeedbackPanel(feedback: fb) { model.next(session) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            VStack(spacing: 6) {
                Button(session.current.isMatch && !ready ? "Paare finden" : "Prüfen") {
                    withAnimation(.spring(duration: 0.35)) { model.check(session, answer: answer, choice: choice) }
                }
                .buttonStyle(.primary)
                .disabled(!ready)
                if !session.current.isMatch {
                    Button("Weiß ich nicht") {
                        withAnimation(.spring(duration: 0.35)) { model.check(session, answer: nil, choice: nil, forceWrong: true) }
                    }
                    .font(.callout)
                    .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

private struct Instruction: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title2.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 18)
    }
}

private struct FeedbackPanel: View {
    let feedback: LessonSession.Feedback
    let onNext: () -> Void

    var body: some View {
        // Three looks: correct (green), wrong (red), skipped with "Weiß ich nicht" (blue hint).
        let tint = feedback.correct ? Palette.greenTint : feedback.skipped ? Palette.blueTint : Palette.redTint
        let color = feedback.correct ? Palette.greenDark : feedback.skipped ? Palette.blue : Palette.redDark
        let badge = feedback.correct ? Palette.green : feedback.skipped ? Palette.blue : Palette.red
        let icon = feedback.correct ? "checkmark" : feedback.skipped ? "info" : "xmark"
        let title = feedback.correct ? "Richtig!" : feedback.skipped ? "Kein Problem – so geht's" : "Nicht ganz"
        let detail = feedback.correct ? feedback.note : feedback.solution
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(badge, in: Circle())
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(color)
            }
            if let detail, !detail.isEmpty {
                if !feedback.correct {
                    Text("Richtig ist:").font(.subheadline).foregroundStyle(color).padding(.top, 10)
                }
                Text(detail)
                    .font(.body.weight(.medium))
                    .foregroundStyle(color)
                    .padding(.top, feedback.correct ? 8 : 2)
            }
            Button("Weiter", action: onNext)
                .buttonStyle(.primary(feedback.correct ? .success : feedback.skipped ? .filled : .destructive))
                .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous))
    }
}

/// Prompt sentence; words with a known translation are underlined and show it when tapped.
private struct PromptView: View {
    @EnvironmentObject private var model: AppModel
    let session: LessonSession
    let text: String
    let german: Bool
    let speak: Bool
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                if speak {
                    Button { model.audio.speakButton(text) } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.title2)
                            .foregroundStyle(Palette.blue)
                            .frame(width: 52, height: 52)
                            .background(Palette.blueTint, in: Circle())
                    }
                    .accessibilityLabel("Vorlesen")
                }
                FlowLayout(spacing: 7, lineSpacing: 4) {
                    ForEach(Array(text.split(separator: " ").enumerated()), id: \.offset) { _, part in
                        let word = String(part)
                        let translation = session.index.hint(word, german: german)
                        Text(word)
                            .font(.title2.weight(.medium))
                            .underline(translation != nil, pattern: .dot, color: Palette.secondary)
                            .onTapGesture {
                                if let translation {
                                    let clean = word.trimmingCharacters(in: CharacterSet(charactersIn: ",.?!¿¡"))
                                    hint = "\(clean) = \(translation)"
                                }
                            }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)

            Group {
                if let hint {
                    Text(hint)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Palette.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Palette.blueTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if !session.index.course.gloss.isEmpty {
                    Text("Tipp: Unterstrichene Wörter antippen für eine Übersetzung.")
                        .font(.footnote)
                        .foregroundStyle(Palette.tertiary)
                }
            }
            .frame(minHeight: 44, alignment: .topLeading)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .task(id: text) {
            hint = nil
            if speak { model.audio.speak(text) }
        }
    }
}

private struct WordChip: View {
    let text: String
    var used = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.body.weight(.medium))
                .foregroundStyle(used ? Color.clear : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(used ? Palette.fill : Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(used ? Color.clear : Palette.separator, lineWidth: 1)
                )
                .shadow(color: .black.opacity(used ? 0 : 0.06), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(used)
        .accessibilityHidden(used)
    }
}

private struct BankView: View {
    @EnvironmentObject private var model: AppModel
    let session: LessonSession
    let exercise: BankExercise
    let locked: Bool
    let onAnswer: (String) -> Void
    @State private var chosen: [Int] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Instruction(text: exercise.toGerman ? "Übersetze ins Deutsche" : "Übersetze auf \(session.course.name)")
            PromptView(session: session, text: exercise.prompt, german: !exercise.toGerman, speak: exercise.toGerman)
            // Answer area: a soft field that fills with tapped words.
            FlowLayout(spacing: 8, lineSpacing: 8) {
                if chosen.isEmpty {
                    Text("Tippe die Wörter in der richtigen Reihenfolge an.")
                        .font(.callout)
                        .foregroundStyle(Palette.tertiary)
                        .padding(6)
                }
                ForEach(chosen, id: \.self) { i in
                    WordChip(text: exercise.chips[i]) {
                        guard !locked else { return }
                        chosen.removeAll { $0 == i }
                        model.tap()
                        update()
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            .background(Palette.fillLight, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            FlowLayout(spacing: 10, lineSpacing: 10, centered: true) {
                ForEach(Array(exercise.chips.enumerated()), id: \.offset) { i, chip in
                    WordChip(text: chip, used: chosen.contains(i)) {
                        guard !locked else { return }
                        chosen.append(i)
                        model.tap()
                        if !exercise.toGerman { model.audio.speak(chip) }
                        update()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
        }
    }

    private func update() {
        onAnswer(chosen.map { exercise.chips[$0] }.joined(separator: " "))
    }
}

/// Text answer with buttons for the target language's special characters.
private struct AnswerField: View {
    let session: LessonSession
    let targetLanguage: Bool
    let locked: Bool
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(targetLanguage ? "Antwort auf \(session.course.name)" : "Antwort auf Deutsch", text: $text, axis: .vertical)
                .font(.title3)
                .lineLimit(3...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .focused($focused)
                .disabled(locked)
                .padding(14)
                .frame(minHeight: 120, alignment: .topLeading)
                .background(Palette.fillLight, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if targetLanguage && !session.course.chars.isEmpty {
                Text("Sonderzeichen").font(.footnote).foregroundStyle(Palette.secondary).padding(.top, 14).padding(.bottom, 6)
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(session.course.chars, id: \.self) { c in
                        Button { text += c } label: {
                            Text(c)
                                .font(.title3.weight(.semibold))
                                .frame(width: 48, height: 46)
                                .background(Palette.fillLight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(locked)
                    }
                }
            }
        }
        .onChange(of: locked) { if locked { focused = false } }
    }
}

private struct ListenView: View {
    @EnvironmentObject private var model: AppModel
    let session: LessonSession
    let exercise: ListenExercise
    let locked: Bool
    @Binding var text: String

    var body: some View {
        let sentence = exercise.sentence.target[0]
        VStack(alignment: .leading, spacing: 0) {
            Instruction(text: "Hör zu und schreib, was du hörst")
            HStack(spacing: 28) {
                VStack(spacing: 6) {
                    Button { model.audio.speakButton(sentence) } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white)
                            .frame(width: 96, height: 96)
                            .background(Palette.blue, in: Circle())
                    }
                    Text("Abspielen").font(.footnote).foregroundStyle(Palette.secondary)
                }
                VStack(spacing: 6) {
                    Button { model.audio.speak(sentence, slow: true) } label: {
                        Image(systemName: "tortoise.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Palette.blue)
                            .frame(width: 64, height: 64)
                            .background(Palette.blueTint, in: Circle())
                    }
                    Text("Langsam").font(.footnote).foregroundStyle(Palette.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            AnswerField(session: session, targetLanguage: true, locked: locked, text: $text)
                .padding(.top, 14)
            if !locked {
                Button("Ich kann gerade nicht zuhören") { model.skipListening(session) }
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.top, 8)
            }
        }
        .task(id: sentence) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            model.audio.speak(sentence)
        }
    }
}

private struct OptionsView: View {
    let options: [String]
    let selected: String?
    let locked: Bool
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                if i > 0 { Divider().padding(.leading, 58) }
                let on = option == selected
                Button { onSelect(option) } label: {
                    HStack(spacing: 16) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(on ? Palette.blue : Palette.tertiary)
                        Text(option)
                            .font(.body.weight(on ? .semibold : .regular))
                            .foregroundStyle(on ? Palette.blue : Color.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(minHeight: 62)
                    .background(on ? Palette.blueTint : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(locked)
            }
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.separator, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct MatchView: View {
    @EnvironmentObject private var model: AppModel
    let exercise: MatchExercise
    let locked: Bool
    let onComplete: () -> Void

    private struct Pick: Hashable {
        let left: Bool
        let index: Int
    }

    @State private var leftOrder: [Int] = []
    @State private var rightOrder: [Int] = []
    @State private var matched: Set<Int> = []
    @State private var selected: Pick?
    @State private var errors: Set<Pick> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Instruction(text: "Tippe auf zwei Wörter, die zusammengehören")
            HStack(alignment: .top, spacing: 12) {
                column(left: true, order: leftOrder)
                column(left: false, order: rightOrder)
            }
        }
        .onAppear {
            if leftOrder.isEmpty {
                leftOrder = Array(exercise.pairs.indices).shuffled()
                rightOrder = Array(exercise.pairs.indices).shuffled()
            }
        }
    }

    private func column(left: Bool, order: [Int]) -> some View {
        VStack(spacing: 12) {
            ForEach(order, id: \.self) { k in
                let pick = Pick(left: left, index: k)
                let text = left ? exercise.pairs[k].target : exercise.pairs[k].german
                let gone = matched.contains(k)
                let isSelected = selected == pick
                let isError = errors.contains(pick)
                Button { tap(pick) } label: {
                    Text(text)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(gone ? Palette.greenDark : isSelected ? Palette.blue : Color.primary)
                        .padding(10)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(gone ? Palette.greenTint : isError ? Palette.redTint : isSelected ? Palette.blueTint : Palette.card,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(gone ? Color.clear : isError ? Palette.red : isSelected ? Palette.blue : Palette.separator,
                                              lineWidth: isSelected || isError ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(gone || locked)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func tap(_ pick: Pick) {
        if locked || matched.contains(pick.index) { return }
        let sound = model.repo.state.settings.sound
        if pick.left { model.audio.speak(exercise.pairs[pick.index].target) }
        guard let current = selected, current.left != pick.left else {
            selected = pick
            model.tap()
            return
        }
        if current.index == pick.index {
            matched.insert(pick.index)
            model.audio.pairFound(enabled: sound)
            selected = nil
            if matched.count == exercise.pairs.count { onComplete() }
        } else {
            errors = [current, pick]
            model.audio.feedback(correct: false, enabled: sound)
            selected = nil
            Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                errors = []
            }
        }
    }
}

// ---------------------------------------------------------------------- end screens

struct ResultView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    let result: LessonResult

    var body: some View {
        let st = repo.state
        let streak = ProgressLogic.streak(st.progress.xp)
        let today = st.progress.xp[Days.key()] ?? 0
        VStack(spacing: 0) {
            Spacer()
            Circle()
                .fill(result.goalReached ? Palette.orange : Palette.green)
                .frame(width: 110, height: 110)
                .overlay(
                    Group {
                        if result.goalReached {
                            Text("🏆").font(.system(size: 54))
                        } else {
                            Image(systemName: "checkmark").font(.system(size: 50, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                )
            Text(result.title).font(.largeTitle.bold()).multilineTextAlignment(.center).padding(.top, 20)
            if let detail = result.detail {
                Text(detail).font(.callout).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).padding(.top, 6)
            }
            if result.goalReached {
                Text("Tagesziel erreicht – super!").font(.headline).foregroundStyle(Palette.orange).padding(.top, 8)
            }
            HStack(spacing: 10) {
                ResultTile(value: "+\(result.xp)", label: "XP")
                ResultTile(value: result.accuracy.map { "\($0) %" } ?? "–", label: "richtig")
                ResultTile(value: "\(streak)", label: streak == 1 ? "Tag in Folge" : "Tage in Folge")
            }
            .padding(.top, 24)
            Text("Heute: \(today) von \(st.settings.goal) XP").font(.subheadline).foregroundStyle(Palette.secondary).padding(.top, 16)
            Spacer()
            Button("Weiter") { model.screen = .home }.buttonStyle(.primary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.groupedBackground)
    }
}

private struct ResultTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold())
            Text(label).font(.footnote).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct FailView: View {
    @EnvironmentObject private var model: AppModel
    let retry: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Circle()
                .fill(Palette.redTint)
                .frame(width: 110, height: 110)
                .overlay(Image(systemName: "heart.fill").font(.system(size: 52)).foregroundStyle(Palette.red))
            Text("Keine Herzen mehr").font(.largeTitle.bold()).padding(.top, 20)
            Text("Kein Problem – Fehler gehören zum Lernen dazu. Die nächste Runde wird etwas leichter.")
                .font(.callout)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer()
            Button("Noch einmal versuchen") { retry() }.buttonStyle(.primary)
            Button("Zur Übersicht") { model.screen = .home }.buttonStyle(.primary(.tinted)).padding(.top, 10)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.groupedBackground)
    }
}
