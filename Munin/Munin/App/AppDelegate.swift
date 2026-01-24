import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appState = AppState()
    private(set) lazy var meetingDetectionService = MeetingDetectionService(appState: appState)

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Munin: applicationDidFinishLaunching")

        // Setup notification handling
        UNUserNotificationCenter.current().delegate = self
        MeetingDetectionService.registerNotificationCategory()

        Task {
            await checkPermissionsOnLaunch()
            // Start monitoring after permissions are requested
            meetingDetectionService.startMonitoring()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        meetingDetectionService.stopMonitoring()

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

        // Request notification permission for completion alerts
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        let actionIdentifier = response.actionIdentifier

        if categoryIdentifier == MeetingDetectionService.notificationCategory {
            Task { @MainActor in
                meetingDetectionService.handleNotificationAction(actionIdentifier)
            }
        }

        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notifications even when app is in foreground
        completionHandler([.banner, .sound])
    }
}
