import Foundation
import UserNotifications

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

    private var audioCaptureCoordinator: AudioCaptureCoordinator?
    private var currentMeetingRecord: MeetingRecord?

    var recordingDuration: TimeInterval {
        guard let startTime = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }

    @Published var lastError: String?

    func startRecording(meetingName: String? = nil) async throws {
        guard state == .idle else { return }

        lastError = nil
        currentMeetingName = meetingName ?? "unknown-meeting"

        print("Munin: Starting recording...")

        let storage = MeetingStorage()
        let record = try storage.createMeetingFolder(name: currentMeetingName)
        currentMeetingRecord = record
        print("Munin: Created folder at \(record.folderURL.path)")

        audioCaptureCoordinator = AudioCaptureCoordinator()
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
    }

    func stopRecording() async {
        guard state == .recording else { return }

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
        state = .idle
    }

    private func processRecording(record: MeetingRecord) async {
        // Phase 2: Transcription
        state = .processing(.transcribing)
        let transcriptionService = TranscriptionService()
        let transcriptURL = record.transcriptURL

        do {
            try await transcriptionService.transcribe(audioURL: record.audioURL, outputURL: transcriptURL)
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
        let content = UNMutableNotificationContent()
        if let error = error {
            content.title = "Processing Failed"
            content.body = error
        } else {
            content.title = "Meeting Processed"
            content.body = "Recording saved to \(record.folderURL.lastPathComponent)"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
