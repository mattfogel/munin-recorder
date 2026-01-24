import AppKit
import EventKit

@MainActor
final class MenuBuilder {
    private let appState: AppState
    private let calendarService = CalendarService.shared

    init(appState: AppState) {
        self.appState = appState
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Status item
        let statusItem = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Upcoming meetings section (only when idle)
        if appState.state == .idle {
            addUpcomingMeetingsSection(to: menu)
        }

        // Start/Stop recording
        switch appState.state {
        case .idle:
            let startItem = NSMenuItem(
                title: "Start Recording",
                action: #selector(startRecording),
                keyEquivalent: "r"
            )
            startItem.target = self
            menu.addItem(startItem)

        case .recording:
            let stopItem = NSMenuItem(
                title: "Stop Recording",
                action: #selector(stopRecording),
                keyEquivalent: "s"
            )
            stopItem.target = self
            menu.addItem(stopItem)

        case .processing:
            let processingItem = NSMenuItem(title: "Processing...", action: nil, keyEquivalent: "")
            processingItem.isEnabled = false
            menu.addItem(processingItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Open folder
        let openFolderItem = NSMenuItem(
            title: "Open Meetings Folder",
            action: #selector(openMeetingsFolder),
            keyEquivalent: "o"
        )
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Munin",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        return menu
    }

    private func statusText() -> String {
        switch appState.state {
        case .idle:
            return "Ready to record"
        case .recording:
            let duration = appState.recordingDuration
            return "Recording: \(formatDuration(duration))"
        case .processing:
            return "Processing..."
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    @objc private func startRecording() {
        Task {
            do {
                try await appState.startRecording()
            } catch {
                showError("Failed to start recording: \(error.localizedDescription)")
            }
        }
    }

    @objc private func stopRecording() {
        Task {
            await appState.stopRecording()
        }
    }

    @objc private func openMeetingsFolder() {
        let storage = MeetingStorage()
        NSWorkspace.shared.open(storage.meetingsDirectory)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Upcoming Meetings

    private func addUpcomingMeetingsSection(to menu: NSMenu) {
        let events = calendarService.getUpcomingEvents(limit: 2)
        guard !events.isEmpty else { return }

        let headerItem = NSMenuItem(title: "Upcoming Meetings", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        for event in events {
            let eventItem = EventMenuItem(event: event, target: self)
            menu.addItem(eventItem)
        }

        menu.addItem(NSMenuItem.separator())
    }

    @objc func startRecordingWithEvent(_ sender: EventMenuItem) {
        guard let event = sender.event else { return }
        Task {
            do {
                try await appState.startRecording(event: event)
            } catch {
                showError("Failed to start recording: \(error.localizedDescription)")
            }
        }
    }
}

/// Custom menu item that holds an event reference
final class EventMenuItem: NSMenuItem {
    let event: EKEvent?

    init(event: EKEvent, target: MenuBuilder) {
        self.event = event
        super.init(title: "", action: #selector(MenuBuilder.startRecordingWithEvent(_:)), keyEquivalent: "")
        self.target = target

        // Format: "10:00 - Meeting Title"
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeStr = formatter.string(from: event.startDate)
        let title = event.title ?? "Untitled"
        let displayTitle = "\(timeStr) - \(title)"
        self.title = String(displayTitle.prefix(40))

        self.toolTip = "Click to start recording: \(title)"
    }

    required init(coder: NSCoder) {
        self.event = nil
        super.init(coder: coder)
    }
}
