import AppKit
import SwiftUI
import EventKit

/// Main application window shown when not recording
/// Behaves as a normal window (dock, cmd+tab accessible)
final class MainAppWindow: NSWindow {
    private var hostingView: NSHostingView<MainAppWindowContent>?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configure()
        setupContent()
        center()
    }

    private func configure() {
        title = "Munin"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true

        // Dark appearance
        appearance = NSAppearance(named: .darkAqua)

        // Visual style
        backgroundColor = NSColor.windowBackgroundColor

        // Standard window behavior - appears in dock, cmd+tab, etc.
        collectionBehavior = [.managed]

        // Animation
        animationBehavior = .documentWindow
    }

    private func setupContent() {
        guard let appState = appState else { return }

        let contentView = MainAppWindowContent(appState: appState)

        hostingView = NSHostingView(rootView: contentView)
        hostingView?.translatesAutoresizingMaskIntoConstraints = false
        self.contentView = hostingView
    }

    func showWindow() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - SwiftUI Content

struct MainAppWindowContent: View {
    @ObservedObject var appState: AppState

    private var upcomingEvents: [EKEvent] {
        CalendarService.shared.getUpcomingEvents(limit: 3)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Status
            statusView

            // Upcoming meetings (hidden if empty)
            if appState.state == .idle && !upcomingEvents.isEmpty {
                upcomingMeetingsView
            }

            // Start Recording button
            if appState.state == .idle {
                startRecordingButton
            } else if appState.state == .recording {
                stopRecordingButton
            }
        }
        .padding(16)
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Status

    private var statusView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private var statusColor: Color {
        switch appState.state {
        case .idle:
            return .green
        case .recording:
            return .red
        case .processing:
            return .orange
        }
    }

    private var statusText: String {
        switch appState.state {
        case .idle:
            return "Ready to record"
        case .recording:
            return "Recording..."
        case .processing(let phase):
            switch phase {
            case .saving: return "Saving..."
            case .transcribing: return "Transcribing..."
            case .summarizing: return "Summarizing..."
            }
        }
    }

    // MARK: - Upcoming Meetings

    private var upcomingMeetingsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming Meetings")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(spacing: 6) {
                ForEach(upcomingEvents, id: \.eventIdentifier) { event in
                    MeetingRowButton(event: event) {
                        startMeetingRecording(event: event)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Control Buttons

    private var startRecordingButton: some View {
        Button(action: {
            Task { try? await appState.startRecording() }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 12))
                Text("Start Recording")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(Color.red)
        .foregroundColor(.white)
        .cornerRadius(8)
        .pointerOnHover()
    }

    private var stopRecordingButton: some View {
        Button(action: {
            Task { await appState.stopRecording() }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10))
                Text("Stop Recording")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(Color.red.opacity(0.8))
        .foregroundColor(.white)
        .cornerRadius(8)
        .pointerOnHover()
    }

    // MARK: - Actions

    private func startMeetingRecording(event: EKEvent) {
        Task {
            // Open meeting link if available
            if let meetingLink = CalendarService.shared.getMeetingLink(event: event) {
                NSWorkspace.shared.open(meetingLink)
            }
            // Start recording with the event
            try? await appState.startRecording(event: event)
        }
    }
}

// MARK: - Meeting Row Button

private struct MeetingRowButton: View {
    let event: EKEvent
    let action: () -> Void

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: event.startDate)
    }

    private var titleString: String {
        let title = event.title ?? "Untitled"
        return String(title.prefix(30))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(timeString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                Text(titleString)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .pointerOnHover()
    }
}

// MARK: - Pointer Cursor Modifier

private extension View {
    func pointerOnHover() -> some View {
        self.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
