import SwiftUI

@main
struct Notch2_0App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    init() {
        UserDefaults.standard.register(defaults: [
            "EnableWebPlayerDetection": true,
            "EnableSystemNowPlayingCenter": false
        ])
    }

    var body: some Scene {
        Settings {
            EmptyView()
                .environmentObject(appModel)
        }
    }
}
