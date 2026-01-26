import AppKit
import UserNotifications
import EventKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appState = AppState()
    private(set) lazy var meetingDetectionService = MeetingDetectionService(appState: appState)
    private(set) lazy var calendarAutoStartService = CalendarAutoStartService.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Munin: applicationDidFinishLaunching")

        // Setup notification handling (for completion notifications)
        UNUserNotificationCenter.current().delegate = self

        // Register notification categories with actions
        registerNotificationCategories()

        Task {
            await checkPermissionsOnLaunch()
            // Start monitoring after permissions are requested
            meetingDetectionService.startMonitoring()
            // Start calendar auto-start polling if enabled
            calendarAutoStartService.startPolling()
        }
    }

    private func registerNotificationCategories() {
        let startAction = UNNotificationAction(
            identifier: "START_RECORDING",
            title: "Start Recording",
            options: [.foreground]
        )

        let joinAndRecordAction = UNNotificationAction(
            identifier: "START_WITH_LINK",
            title: "Join & Record",
            options: [.foreground]
        )

        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: "Dismiss",
            options: []
        )

        let meetingCategory = UNNotificationCategory(
            identifier: "MEETING_REMINDER",
            actions: [joinAndRecordAction, startAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([meetingCategory])
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
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notifications even when app is in foreground
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier

        Task { @MainActor in
            switch actionID {
            case "START_RECORDING":
                await handleStartRecording()

            case "START_WITH_LINK":
                await handleJoinAndRecord()

            case "DISMISS", UNNotificationDismissActionIdentifier:
                // User dismissed - clear pending event
                calendarAutoStartService.clearPendingEvent()

            default:
                // Default action (tapped notification itself)
                break
            }
            completionHandler()
        }
    }

    private func handleStartRecording() async {
        guard let event = calendarAutoStartService.getPendingEvent() else {
            // No pending event, start generic recording
            try? await appState.startRecording()
            return
        }

        calendarAutoStartService.clearPendingEvent()
        try? await appState.startRecording(event: event)
    }

    private func handleJoinAndRecord() async {
        guard let event = calendarAutoStartService.getPendingEvent() else {
            // No pending event, just start recording
            try? await appState.startRecording()
            return
        }

        // Open meeting link if available
        if let meetingURL = CalendarService.shared.getMeetingLink(event: event) {
            NSWorkspace.shared.open(meetingURL)
        }

        calendarAutoStartService.clearPendingEvent()
        try? await appState.startRecording(event: event)
    }
}
