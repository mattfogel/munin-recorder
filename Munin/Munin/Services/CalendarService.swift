import Foundation
import EventKit

/// Provides calendar integration for automatic meeting name detection
final class CalendarService {
    static let shared = CalendarService()

    private let eventStore = EKEventStore()

    /// Time buffer for matching events (±5 minutes)
    private let matchBufferSeconds: TimeInterval = 5 * 60

    private init() {}

    /// Request calendar access
    func requestAccess() async -> Bool {
        do {
            return try await eventStore.requestFullAccessToEvents()
        } catch {
            print("Munin: Calendar access request failed: \(error)")
            return false
        }
    }

    /// Check if calendar access is granted
    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Find a calendar event overlapping the given time (±buffer)
    func getCurrentEvent(at date: Date = Date()) -> EKEvent? {
        guard hasAccess else { return nil }

        let startWindow = date.addingTimeInterval(-matchBufferSeconds)
        let endWindow = date.addingTimeInterval(matchBufferSeconds)

        let predicate = eventStore.predicateForEvents(
            withStart: startWindow,
            end: endWindow,
            calendars: nil
        )

        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }

        // Find event that contains the current time (with buffer consideration)
        // Prefer events currently in progress over upcoming ones
        let now = date
        let activeEvents = events.filter { event in
            event.startDate <= now && event.endDate >= now
        }

        if let active = activeEvents.first {
            return active
        }

        // Return nearest event within buffer window
        return events.sorted { $0.startDate < $1.startDate }.first
    }

    /// Get upcoming events for menu display
    func getUpcomingEvents(limit: Int = 3) -> [EKEvent] {
        guard hasAccess else { return [] }

        let now = Date()
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now.addingTimeInterval(12 * 3600)

        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: endOfDay,
            calendars: nil
        )

        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        return Array(events.prefix(limit))
    }

    /// Extract participant names from an event
    func getParticipantNames(event: EKEvent) -> [String] {
        guard let attendees = event.attendees else { return [] }

        return attendees.compactMap { attendee in
            // Use name if available, otherwise extract from URL
            if let name = attendee.name, !name.isEmpty {
                return name
            }
            // Try to extract email from URL
            let url = attendee.url
            let email = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            if let username = email.components(separatedBy: "@").first, !username.isEmpty {
                return username
            }
            return nil
        }
    }

    /// Extract meeting link from an event (Zoom, Meet, Teams, etc.)
    func getMeetingLink(event: EKEvent) -> URL? {
        // 1. Check event.url first (most reliable)
        if let url = event.url {
            return url
        }

        // URL patterns for common meeting providers
        let meetingPatterns = [
            "https?://[^\\s]*zoom\\.us/[^\\s]+",
            "https?://meet\\.google\\.com/[^\\s]+",
            "https?://teams\\.microsoft\\.com/[^\\s]+",
            "https?://[^\\s]*webex\\.com/[^\\s]+",
            "https?://[^\\s]*gotomeeting\\.com/[^\\s]+"
        ]

        let combinedPattern = meetingPatterns.joined(separator: "|")

        // 2. Check event.notes
        if let notes = event.notes, let url = extractURL(from: notes, pattern: combinedPattern) {
            return url
        }

        // 3. Check event.location (sometimes contains URL)
        if let location = event.location, let url = extractURL(from: location, pattern: combinedPattern) {
            return url
        }

        return nil
    }

    private func extractURL(from text: String, pattern: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range),
           let matchRange = Range(match.range, in: text) {
            let urlString = String(text[matchRange])
            return URL(string: urlString)
        }
        return nil
    }

    /// Sanitize event title for use as folder name
    func sanitizeForFilename(_ title: String) -> String {
        // Remove/replace characters invalid for filenames
        let invalidChars = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        var sanitized = title.components(separatedBy: invalidChars).joined(separator: "-")

        // Replace multiple spaces/dashes with single dash
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }
        while sanitized.contains("  ") {
            sanitized = sanitized.replacingOccurrences(of: "  ", with: " ")
        }

        // Trim and limit length
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.count > 50 {
            sanitized = String(sanitized.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return sanitized.isEmpty ? "unknown-meeting" : sanitized
    }
}
