import ParlaCore
import SwiftUI
import UIKit

@main
struct ParlaApp: App {
    @StateObject private var repo: Repository
    @StateObject private var model: AppModel

    init() {
        let server = Bundle.main.object(forInfoDictionaryKey: "ParlaServerURL") as? String ?? "https://parla.mirranet.de"
        let store = LocalStore(prefs: DevicePrefs(), root: LocalStore.defaultRoot(), defaultServerUrl: server)
        let device = UIDevice.current
        let repo = Repository(store: store, device: "\(device.model) (\(device.systemName) \(device.systemVersion))")
        _repo = StateObject(wrappedValue: repo)
        _model = StateObject(wrappedValue: AppModel(repo: repo))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(repo)
                .environmentObject(model)
                .tint(Palette.blue)
        }
    }
}
