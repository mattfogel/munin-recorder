import Foundation
import UserNotifications

/// Detects meeting starts via mic activity and prompts user to record
@MainActor
final class MeetingDetectionService: ObservableObject {
    static let notificationCategory = "MEETING_DETECTED"
    static let actionStartRecording = "START_RECORDING"
    static let actionDismiss = "DISMISS"

    private static let cooldownDuration: TimeInterval = 10 * 60 // 10 minutes

    @Published var isEnabled: Bool = true {
        didSet {
            if isEnabled {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }

    private let micMonitor = MicActivityMonitor()
    private var cooldownUntil: Date?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        setupMicMonitor()
    }

    private func setupMicMonitor() {
        micMonitor.onMicActivityChanged = { [weak self] isActive in
            Task { @MainActor [weak self] in
                self?.handleMicActivityChanged(isActive)
            }
        }
    }

    func startMonitoring() {
        micMonitor.startMonitoring()
        print("Munin: Meeting detection enabled")
    }

    func stopMonitoring() {
        micMonitor.stopMonitoring()
        print("Munin: Meeting detection disabled")
    }

    private func handleMicActivityChanged(_ isActive: Bool) {
        guard isActive else { return }
        guard isEnabled else { return }

        // Already recording?
        if appState?.state != .idle {
            print("Munin: Mic active but already recording/processing, ignoring")
            return
        }

        // In cooldown?
        if let cooldownUntil = cooldownUntil, Date() < cooldownUntil {
            print("Munin: Mic active but in cooldown until \(cooldownUntil)")
            return
        }

        // Show notification
        postMeetingDetectedNotification()
    }

    private func postMeetingDetectedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Mic Active"

        // Check for calendar event
        if let event = CalendarService.shared.getCurrentEvent() {
            content.body = "\(event.title ?? "Meeting") - Start recording?"
        } else {
            content.body = "Start recording this meeting?"
        }

        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory

        let request = UNNotificationRequest(
            identifier: "meeting-detected-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Munin: Failed to post meeting notification: \(error)")
            } else {
                print("Munin: Posted meeting detection notification")
            }
        }
    }

    func handleNotificationAction(_ actionIdentifier: String) {
        switch actionIdentifier {
        case Self.actionStartRecording, UNNotificationDefaultActionIdentifier:
            // User tapped notification or Start Recording
            Task {
                try? await appState?.startRecording()
            }

        case Self.actionDismiss:
            // User dismissed - start cooldown
            startCooldown()

        default:
            break
        }
    }

    private func startCooldown() {
        cooldownUntil = Date().addingTimeInterval(Self.cooldownDuration)
        print("Munin: Meeting detection cooldown until \(cooldownUntil!)")
    }

    // MARK: - Notification Category Setup

    static func registerNotificationCategory() {
        let startAction = UNNotificationAction(
            identifier: actionStartRecording,
            title: "Start Recording",
            options: [.foreground]
        )

        let dismissAction = UNNotificationAction(
            identifier: actionDismiss,
            title: "Not Now",
            options: []
        )

        let category = UNNotificationCategory(
            identifier: notificationCategory,
            actions: [startAction, dismissAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
