import Foundation
import EventKit
import AppKit

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
    private weak var appState: AppState?

    private let calendarService = CalendarService.shared

    private init() {
        self.isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        self.leadTimeMinutes = UserDefaults.standard.object(forKey: Self.leadTimeKey) as? Int ?? 2
    }

    // MARK: - Public API

    /// Configure with AppState reference for notification actions
    func configure(appState: AppState) {
        self.appState = appState
    }

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
        guard let appState = appState else {
            print("Munin: CalendarAutoStartService not configured with AppState")
            return
        }

        let minutes = Int(ceil(timeUntilStart / 60))
        print("Munin: Showing notification for upcoming meeting: \(event.title ?? "Untitled")")

        appState.notificationPanel.showMeetingReminder(
            event: event,
            minutesUntilStart: minutes,
            onStartRecording: { [weak self] in
                Task { @MainActor in
                    self?.handleStartRecording(event: event)
                }
            },
            onJoinAndRecord: { [weak self] in
                Task { @MainActor in
                    self?.handleJoinAndRecord(event: event)
                }
            },
            onDismiss: { [weak self] in
                self?.clearPendingEvent()
            }
        )
    }

    // MARK: - Action Handlers

    private func handleStartRecording(event: EKEvent) {
        guard let appState = appState else { return }
        clearPendingEvent()
        Task {
            try? await appState.startRecording(event: event)
        }
    }

    private func handleJoinAndRecord(event: EKEvent) {
        guard let appState = appState else { return }

        // Open meeting link if available
        if let meetingURL = calendarService.getMeetingLink(event: event) {
            NSWorkspace.shared.open(meetingURL)
        }

        clearPendingEvent()
        Task {
            try? await appState.startRecording(event: event)
        }
    }
}
