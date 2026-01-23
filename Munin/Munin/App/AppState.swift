import Foundation
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    enum RecordingState: Equatable {
        case idle
        case recording
        case processing
    }

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var recordingStartTime: Date?
    @Published private(set) var currentMeetingName: String = "unknown-meeting"

    private var audioCaptureCoordinator: AudioCaptureCoordinator?
    private var currentMeetingRecord: MeetingRecord?

    var recordingDuration: TimeInterval {
        guard let startTime = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }

    func startRecording(meetingName: String? = nil) async throws {
        guard state == .idle else { return }

        currentMeetingName = meetingName ?? "unknown-meeting"

        let storage = MeetingStorage()
        let record = try storage.createMeetingFolder(name: currentMeetingName)
        currentMeetingRecord = record

        audioCaptureCoordinator = AudioCaptureCoordinator()
        try await audioCaptureCoordinator?.startCapture(outputURL: record.audioURL)

        recordingStartTime = Date()
        state = .recording
    }

    func stopRecording() async {
        guard state == .recording else { return }

        state = .processing

        await audioCaptureCoordinator?.stopCapture()
        audioCaptureCoordinator = nil

        if let record = currentMeetingRecord {
            await processRecording(record: record)
        }

        recordingStartTime = nil
        currentMeetingRecord = nil
        state = .idle
    }

    private func processRecording(record: MeetingRecord) async {
        // Phase 2: Transcription
        let transcriptionService = TranscriptionService()
        let transcriptURL = record.transcriptURL

        do {
            try await transcriptionService.transcribe(audioURL: record.audioURL, outputURL: transcriptURL)

            // Phase 3: Summarization
            let summarizationService = SummarizationService()
            try await summarizationService.summarize(transcriptURL: transcriptURL, outputURL: record.summaryURL)
        } catch {
            print("Processing error: \(error)")
        }

        showCompletionNotification(record: record)
    }

    private func showCompletionNotification(record: MeetingRecord) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting Processed"
        content.body = "Recording saved to \(record.folderURL.lastPathComponent)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
