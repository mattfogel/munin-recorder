import Foundation
import AppKit
import EventKit

@MainActor
final class AppState: ObservableObject {
    enum RecordingState: Equatable {
        case idle
        case recording
        case processing(ProcessingPhase)

        enum ProcessingPhase: Equatable {
            case saving
            case transcribing
            case summarizing
        }
    }

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var recordingStartTime: Date?
    @Published private(set) var currentMeetingName: String = "unknown-meeting"
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var audioLevels: AudioLevels = .zero

    private var audioCaptureCoordinator: AudioCaptureCoordinator?
    private var currentMeetingRecord: MeetingRecord?
    private var currentParticipants: [String] = []
    private let calendarService = CalendarService.shared
    private var recordingIndicatorWindow: RecordingIndicatorWindow?
    let notificationPanel = NotificationNubPanel()

    var recordingDuration: TimeInterval {
        guard let startTime = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }

    @Published var lastError: String?

    func startRecording(meetingName: String? = nil, event: EKEvent? = nil) async throws {
        guard state == .idle else { return }

        lastError = nil
        currentParticipants = []

        // Determine meeting name and participants: explicit event > explicit name > auto-detect > fallback
        if let event = event {
            // Explicit event passed (from clicking upcoming meeting)
            currentMeetingName = calendarService.sanitizeForFilename(event.title ?? "unknown-meeting")
            currentParticipants = calendarService.getParticipantNames(event: event)
            print("Munin: Using selected event: \(event.title ?? "untitled") with \(currentParticipants.count) participants")
        } else if let name = meetingName {
            currentMeetingName = name
        } else if let detectedEvent = calendarService.getCurrentEvent() {
            currentMeetingName = calendarService.sanitizeForFilename(detectedEvent.title ?? "unknown-meeting")
            currentParticipants = calendarService.getParticipantNames(event: detectedEvent)
            print("Munin: Found calendar event: \(detectedEvent.title ?? "untitled") with \(currentParticipants.count) participants")
        } else {
            currentMeetingName = "unknown-meeting"
        }

        print("Munin: Starting recording...")

        let storage = MeetingStorage()
        let record = try storage.createMeetingFolder(name: currentMeetingName)
        currentMeetingRecord = record
        print("Munin: Created folder at \(record.folderURL.path)")

        audioCaptureCoordinator = AudioCaptureCoordinator()

        // Set up audio level monitoring for VU meters
        audioCaptureCoordinator?.levelHandler = { [weak self] levels in
            Task { @MainActor [weak self] in
                self?.audioLevels = AudioLevels(micLevel: levels.micLevel, systemLevel: levels.systemLevel)
            }
        }

        do {
            try await audioCaptureCoordinator?.startCapture(outputURL: record.audioURL)
            print("Munin: Audio capture started successfully")
        } catch {
            lastError = error.localizedDescription
            print("Munin: Failed to start audio capture: \(error)")
            throw error
        }

        recordingStartTime = Date()
        state = .recording

        // Show recording indicator window
        showRecordingIndicator()

        // Show "Recording Started" notification
        showRecordingStartedNotification()
    }

    private func showRecordingStartedNotification() {
        let subtitle = currentMeetingName == "unknown-meeting" ? "Recording in progress" : currentMeetingName
        notificationPanel.showInfo(title: "Recording Started", subtitle: subtitle)
    }

    private func showRecordingIndicator() {
        if recordingIndicatorWindow == nil {
            recordingIndicatorWindow = RecordingIndicatorWindow(appState: self)
        }
        recordingIndicatorWindow?.showAnimated()
    }

    private func hideRecordingIndicator() {
        recordingIndicatorWindow?.hideAnimated()
        audioLevels = .zero
    }

    func stopRecording() async {
        guard state == .recording else { return }

        // Hide recording indicator window
        hideRecordingIndicator()

        state = .processing(.saving)
        lastError = nil

        await audioCaptureCoordinator?.stopCapture()
        audioCaptureCoordinator = nil

        if let record = currentMeetingRecord {
            lastRecordingURL = record.folderURL
            await processRecording(record: record)
        }

        recordingStartTime = nil
        currentMeetingRecord = nil
        currentParticipants = []
        state = .idle
    }

    private func processRecording(record: MeetingRecord) async {
        // Phase 2: Transcription
        state = .processing(.transcribing)
        let transcriptionService = TranscriptionService()
        let transcriptURL = record.transcriptURL

        do {
            try await transcriptionService.transcribe(
                audioURL: record.audioURL,
                outputURL: transcriptURL,
                participants: currentParticipants
            )
        } catch {
            print("Transcription error: \(error)")
            lastError = error.localizedDescription
            showCompletionNotification(record: record, error: "Transcription failed")
            return
        }

        // Phase 3: Summarization
        state = .processing(.summarizing)
        let summarizationService = SummarizationService()
        do {
            try await summarizationService.summarize(transcriptURL: transcriptURL, outputURL: record.summaryURL)
        } catch {
            print("Summarization error: \(error)")
            // Non-fatal - transcript is still saved
            lastError = "Summarization skipped: \(error.localizedDescription)"
        }

        showCompletionNotification(record: record, error: nil)
    }

    private func showCompletionNotification(record: MeetingRecord, error: String?) {
        if let error = error {
            notificationPanel.showStatus(
                title: "Processing Failed",
                subtitle: error,
                isError: true
            )
        } else {
            notificationPanel.showStatus(
                title: "Meeting Processed",
                subtitle: record.folderURL.lastPathComponent,
                isError: false,
                onTap: {
                    NSWorkspace.shared.open(record.folderURL)
                }
            )
        }
    }
}
