import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        terminateDuplicateInstances()
    }

    private func terminateDuplicateInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID.isEmpty == false else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let duplicates = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }

        for app in duplicates {
            if app.terminate() == false {
                app.forceTerminate()
            }
        }
    }
}
