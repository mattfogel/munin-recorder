import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Munin: applicationDidFinishLaunching")

        Task {
            await checkPermissionsOnLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if appState.state == .recording {
            Task {
                await appState.stopRecording()
            }
        }
    }

    private func checkPermissionsOnLaunch() async {
        let checker = PermissionChecker()

        if !checker.hasScreenRecordingPermission() {
            PermissionPrompts.showScreenRecordingAlert()
        }

        if !checker.hasMicrophonePermission() {
            _ = await checker.requestMicrophonePermission()
        }
    }
}
