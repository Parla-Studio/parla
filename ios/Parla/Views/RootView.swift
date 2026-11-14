import ParlaCore
import SwiftUI

/// Top-level navigation: login → content download → course choice → units / lesson.
struct RootView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var banner: String?

    var body: some View {
        content
            .modifier(LargeTextModifier(on: repo.state.largeText))
            .overlay(alignment: .top) {
                if let banner {
                    Text(banner)
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { withAnimation { self.banner = nil } }
                }
            }
            .onChange(of: repo.state.message) {
                guard let message = repo.state.message else { return }
                repo.consumeMessage()
                withAnimation { banner = message }
                Task {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    if banner == message { withAnimation { banner = nil } }
                }
            }
            .onChange(of: scenePhase) {
                // Pick up progress from other devices whenever the app comes to the front.
                if scenePhase == .active { model.sync() }
            }
    }

    @ViewBuilder
    private var content: some View {
        let st = repo.state
        if !st.loggedIn {
            LoginView()
        } else if st.courses.isEmpty {
            WaitingView(offline: st.offline, syncing: st.syncing)
        } else if let course = st.course {
            switch model.screen {
            case .home:
                HomeView(course: course)
            case let .lesson(session):
                LessonView(session: session)
            case let .result(result):
                ResultView(result: result)
            case let .failed(retry):
                FailView(retry: retry)
            }
        } else {
            NavigationStack { CoursePickerView(firstTime: true) }
        }
    }
}

/// Shown after login until the courses are downloaded.
struct WaitingView: View {
    @EnvironmentObject private var model: AppModel
    let offline: Bool
    let syncing: Bool

    var body: some View {
        VStack(spacing: 14) {
            if syncing {
                ProgressView()
                Text("Kurse werden geladen …").font(.headline)
            } else {
                Text(offline ? "📡" : "⚠️").font(.system(size: 56))
                Text(offline ? "Keine Verbindung" : "Kurse konnten nicht geladen werden")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(offline
                     ? "Die Kursinhalte kommen vom Server. Verbinde dich einmal mit dem Internet, danach geht es auch offline."
                     : "Der Server hat keine Kurse geliefert. Versuch es gleich noch einmal.")
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                Button("Erneut versuchen") { model.sync() }
                    .buttonStyle(.primary)
                    .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.groupedBackground)
        .task { model.sync() }
    }
}
