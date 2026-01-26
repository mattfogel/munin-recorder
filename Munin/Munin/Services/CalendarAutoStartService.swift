import Foundation
import EventKit
import UserNotifications

/// Service that monitors calendar and offers to auto-start recording before scheduled meetings
@MainActor
final class CalendarAutoStartService: ObservableObject {
    static let shared = CalendarAutoStartService()

    // MARK: - UserDefaults Keys
    private static let enabledKey = "CalendarAutoStartEnabled"
    private static let leadTimeKey = "CalendarAutoStartLeadTime"

    // MARK: - Published State
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                startPolling()
            } else {
                stopPolling()
            }
        }
    }

    @Published var leadTimeMinutes: Int {
        didSet {
            UserDefaults.standard.set(leadTimeMinutes, forKey: Self.leadTimeKey)
        }
    }

    // MARK: - Internal State
    private var pollingTimer: Timer?
    private var notifiedEventIDs: Set<String> = []
    private var lastMidnightClear: Date?
    private var pendingEvent: EKEvent?

    private let calendarService = CalendarService.shared

    private init() {
        self.isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        self.leadTimeMinutes = UserDefaults.standard.object(forKey: Self.leadTimeKey) as? Int ?? 2
    }

    // MARK: - Public API

    func startPolling() {
        guard isEnabled else { return }
        stopPolling()

        print("Munin: CalendarAutoStartService starting polling (lead time: \(leadTimeMinutes) min)")

        // Poll every 30 seconds
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkUpcomingEvents()
            }
        }
        // Run immediately
        checkUpcomingEvents()
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    /// Get the pending event for notification action handling
    func getPendingEvent() -> EKEvent? {
        return pendingEvent
    }

    /// Clear the pending event after handling
    func clearPendingEvent() {
        pendingEvent = nil
    }

    // MARK: - Polling Logic

    private func checkUpcomingEvents() {
        guard calendarService.hasAccess else { return }

        // Clear notified set at midnight
        clearNotifiedSetIfNewDay()

        let now = Date()
        let leadTimeSeconds = TimeInterval(leadTimeMinutes * 60)

        // Get events starting within the next leadTime window
        let events = calendarService.getUpcomingEvents(limit: 5)

        for event in events {
            guard let eventID = event.eventIdentifier else { continue }

            // Skip if already notified
            if notifiedEventIDs.contains(eventID) { continue }

            // Check if event starts within lead time window
            let timeUntilStart = event.startDate.timeIntervalSince(now)

            // Notify if: 0 < timeUntilStart <= leadTime
            // (don't notify for events that have already started)
            if timeUntilStart > 0 && timeUntilStart <= leadTimeSeconds {
                notifiedEventIDs.insert(eventID)
                pendingEvent = event
                showUpcomingMeetingNotification(event: event, timeUntilStart: timeUntilStart)
                break // Only show one notification at a time
            }
        }
    }

    private func clearNotifiedSetIfNewDay() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        if let lastClear = lastMidnightClear {
            if !calendar.isDate(lastClear, inSameDayAs: today) {
                notifiedEventIDs.removeAll()
                lastMidnightClear = today
            }
        } else {
            lastMidnightClear = today
        }
    }

    // MARK: - Notifications

    private func showUpcomingMeetingNotification(event: EKEvent, timeUntilStart: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting Starting Soon"

        let minutes = Int(ceil(timeUntilStart / 60))
        let timeText = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        content.body = "\(event.title ?? "Untitled") starts in \(timeText)"
        content.sound = .default
        content.categoryIdentifier = "MEETING_REMINDER"

        // Store event ID in userInfo for action handling
        content.userInfo = ["eventID": event.eventIdentifier ?? ""]

        let request = UNNotificationRequest(
            identifier: "meeting-\(event.eventIdentifier ?? UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Munin: Failed to show meeting notification: \(error)")
            } else {
                print("Munin: Showed notification for upcoming meeting: \(event.title ?? "Untitled")")
            }
        }
    }
}
