import SwiftUI

@main
struct MuninApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appDelegate.appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 300, height: 200)

        MenuBarExtra("Munin", systemImage: "waveform.circle") {
            MenuBarView(appState: appDelegate.appState)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var timer: Timer?
    @State private var displayedDuration: TimeInterval = 0

    var body: some View {
        VStack(spacing: 20) {
            Text("Munin")
                .font(.largeTitle)
                .fontWeight(.bold)

            statusView

            if let error = appState.lastError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }

            Divider()

            controlButton

            HStack(spacing: 16) {
                if let lastURL = appState.lastRecordingURL {
                    Button("Open Last Recording") {
                        NSWorkspace.shared.open(lastURL)
                    }
                    .buttonStyle(.link)
                }

                Button("Open Meetings Folder") {
                    let storage = MeetingStorage()
                    NSWorkspace.shared.open(storage.meetingsDirectory)
                }
                .buttonStyle(.link)
            }
        }
        .padding(30)
        .frame(minWidth: 280, minHeight: 180)
    }

    @ViewBuilder
    private var statusView: some View {
        switch appState.state {
        case .idle:
            Label("Ready to record", systemImage: "checkmark.circle")
                .foregroundColor(.secondary)
                .onAppear { stopTimer() }
        case .recording:
            Label("Recording: \(formatDuration(displayedDuration))", systemImage: "record.circle.fill")
                .foregroundColor(.red)
                .onAppear { startTimer() }
        case .processing(let phase):
            Label(processingLabel(for: phase), systemImage: "gear")
                .foregroundColor(.orange)
                .onAppear { stopTimer() }
        }
    }

    private func processingLabel(for phase: AppState.RecordingState.ProcessingPhase) -> String {
        switch phase {
        case .saving: return "Saving audio..."
        case .transcribing: return "Transcribing..."
        case .summarizing: return "Summarizing..."
        }
    }

    private func startTimer() {
        displayedDuration = appState.recordingDuration
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak appState] _ in
            Task { @MainActor in
                guard let appState else { return }
                displayedDuration = appState.recordingDuration
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @ViewBuilder
    private var controlButton: some View {
        switch appState.state {
        case .idle:
            Button(action: {
                Task { try? await appState.startRecording() }
            }) {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

        case .recording:
            Button(action: {
                Task { await appState.stopRecording() }
            }) {
                Label("Stop Recording", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .processing:
            ProgressView()
                .progressViewStyle(.circular)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        switch appState.state {
        case .idle:
            Text("Ready to record")
                .foregroundColor(.secondary)
            Divider()
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

    private func processingLabel(for phase: AppState.RecordingState.ProcessingPhase) -> String {
        switch phase {
        case .saving: return "Saving audio..."
        case .transcribing: return "Transcribing..."
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
