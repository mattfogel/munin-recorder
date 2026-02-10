import SwiftUI
import EventKit

@main
struct MuninApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Main window is managed by AppDelegate as MainAppWindow
        // Only MenuBarExtra is defined here as a SwiftUI Scene

        MenuBarExtra("Munin", image: "MenuBarIcon") {
            MenuBarView(
                appState: appDelegate.appState,
                meetingDetection: appDelegate.meetingDetectionService,
                calendarAutoStart: appDelegate.calendarAutoStartService
            )
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var meetingDetection: MeetingDetectionService
    @ObservedObject var calendarAutoStart: CalendarAutoStartService

    private var upcomingEvents: [EKEvent] {
        CalendarService.shared.getUpcomingEvents(limit: 2)
    }

    var body: some View {
        switch appState.state {
        case .idle:
            Text("Ready to record")
                .foregroundColor(.secondary)
            Divider()

            // Upcoming meetings section
            if !upcomingEvents.isEmpty {
                Text("Upcoming Meetings")
                    .foregroundColor(.secondary)
                ForEach(upcomingEvents, id: \.eventIdentifier) { event in
                    Button(formatEventTitle(event)) {
                        Task {
                            // Open meeting link if available
                            if let meetingLink = CalendarService.shared.getMeetingLink(event: event) {
                                NSWorkspace.shared.open(meetingLink)
                            }
                            try? await appState.startRecording(event: event)
                        }
                    }
                }
                Divider()
            }

            Button("Start Recording") {
                Task {
                    try? await appState.startRecording()
                }
            }
            .keyboardShortcut("r")

        case .recording:
            Text("Recording: \(formatDuration(appState.recordingDuration))")
                .foregroundColor(.red)
            Divider()
            Button("Stop Recording") {
                Task {
                    await appState.stopRecording()
                }
            }
            .keyboardShortcut("s")

        case .processing(let phase):
            Text(processingLabel(for: phase))
                .foregroundColor(.secondary)
        }

        Divider()

        Toggle("Auto-detect Meetings", isOn: $meetingDetection.isEnabled)
        Toggle("Calendar Auto-Start", isOn: $calendarAutoStart.isEnabled)

        Divider()

        Button("Show Munin") {
            NSApp.activate(ignoringOtherApps: true)
            // Find and show the main window
            if let mainWindow = NSApp.windows.first(where: { $0 is MainAppWindow }) {
                mainWindow.makeKeyAndOrderFront(nil)
            }
        }
        .keyboardShortcut("m")

        Button("Open Meetings Folder") {
            let storage = MeetingStorage()
            NSWorkspace.shared.open(storage.meetingsDirectory)
        }
        .keyboardShortcut("o")

        Divider()

        Button("Quit Munin") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func formatEventTitle(_ event: EKEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeStr = formatter.string(from: event.startDate)
        let title = event.title ?? "Untitled"
        let displayTitle = "\(timeStr) - \(title)"
        return String(displayTitle.prefix(40))
    }

    private func processingLabel(for phase: AppState.RecordingState.ProcessingPhase) -> String {
        switch phase {
        case .saving: return "Saving audio..."
        case .finalizing: return "Finalizing transcription..."
        case .summarizing: return "Summarizing..."
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
}
