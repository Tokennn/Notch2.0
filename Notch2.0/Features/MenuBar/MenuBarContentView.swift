import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notch2.0")
                .font(.system(size: 16, weight: .semibold))

            Toggle("Activer l'interception des touches", isOn: $appModel.isEnabled)
            Toggle("Now Playing auto", isOn: $appModel.nowPlayingEnabled)
            Toggle("Detection web", isOn: $appModel.webPlayerDetectionEnabled)

            Divider()

            HStack {
                Button("Ouvrir Reglages") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }

                Spacer()

                Button("Quitter") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(14)
    }
}
