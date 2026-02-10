import Foundation
import AVFoundation
import EventKit
import Speech

final class PermissionChecker {

    /// Checks if microphone permission is granted
    func hasMicrophonePermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Requests microphone permission
    func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Checks if calendar permission is granted
    func hasCalendarPermission() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .fullAccess
    }

    /// Requests calendar permission
    func requestCalendarPermission() async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            print("Munin: Calendar permission request failed: \(error)")
            return false
        }
    }

    /// Checks if speech recognition permission is granted
    func hasSpeechRecognitionPermission() -> Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Requests speech recognition permission
    func requestSpeechRecognitionPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Checks all required permissions
    func checkAllPermissions() async -> PermissionStatus {
        let microphone = hasMicrophonePermission()
        let calendar = hasCalendarPermission()
        let speechRecognition = hasSpeechRecognitionPermission()

        return PermissionStatus(microphone: microphone, calendar: calendar, speechRecognition: speechRecognition)
    }
}

struct PermissionStatus {
    let microphone: Bool
    let calendar: Bool
    let speechRecognition: Bool

    var canRecord: Bool {
        // Microphone permission is required for recording
        // System audio via Core Audio Taps will prompt separately if needed
        microphone
    }

    var canTranscribe: Bool {
        speechRecognition
    }

    var allGranted: Bool {
        microphone && calendar && speechRecognition
    }
}
