import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(appState: appState)

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
