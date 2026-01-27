import AppKit
import EventKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private(set) lazy var meetingDetectionService = MeetingDetectionService(appState: appState)
    private(set) lazy var calendarAutoStartService = CalendarAutoStartService.shared

    private var mainAppWindow: MainAppWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure calendar auto-start service with AppState for notification actions
        calendarAutoStartService.configure(appState: appState)

        // Create and show the main app window
        setupMainAppWindow()

        Task {
            await checkPermissionsOnLaunch()
            // Start monitoring after permissions are requested
            meetingDetectionService.startMonitoring()
            // Start calendar auto-start polling if enabled
            calendarAutoStartService.startPolling()
        }
    }

    private func setupMainAppWindow() {
        mainAppWindow = MainAppWindow(appState: appState)
        mainAppWindow?.showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Show main window when dock icon is clicked
        if !flag {
            mainAppWindow?.showWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        meetingDetectionService.stopMonitoring()
        calendarAutoStartService.stopPolling()

        if appState.state == .recording {
            Task {
                await appState.stopRecording()
            }
        }
    }

    private func checkPermissionsOnLaunch() async {
        let checker = PermissionChecker()

        // Request microphone permission on launch
        // System audio capture via Core Audio Taps will prompt separately when recording starts
        if !checker.hasMicrophonePermission() {
            _ = await checker.requestMicrophonePermission()
        }

        // Request calendar permission on launch (optional, for auto-naming)
        if !checker.hasCalendarPermission() {
            _ = await checker.requestCalendarPermission()
        }
    }
}
