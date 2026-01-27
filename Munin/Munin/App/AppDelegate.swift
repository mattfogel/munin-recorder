import AppKit
import EventKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private(set) lazy var meetingDetectionService = MeetingDetectionService(appState: appState)
    private(set) lazy var calendarAutoStartService = CalendarAutoStartService.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Munin: applicationDidFinishLaunching")

        // Configure calendar auto-start service with AppState for notification actions
        calendarAutoStartService.configure(appState: appState)

        Task {
            await checkPermissionsOnLaunch()
            // Start monitoring after permissions are requested
            meetingDetectionService.startMonitoring()
            // Start calendar auto-start polling if enabled
            calendarAutoStartService.startPolling()
        }
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
