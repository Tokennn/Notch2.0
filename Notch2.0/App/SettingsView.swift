import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("General") {
                Toggle("Activer l'interception des touches", isOn: $appModel.isEnabled)
                Toggle("Activer now playing automatique", isOn: $appModel.nowPlayingEnabled)
                Toggle("Detecter audio/video web", isOn: $appModel.webPlayerDetectionEnabled)
            }
        }
        .padding(16)
    }
}
