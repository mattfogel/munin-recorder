import Foundation
import AVFoundation
import EventKit

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

    /// Checks all required permissions
    func checkAllPermissions() async -> PermissionStatus {
        let microphone = hasMicrophonePermission()
        let calendar = hasCalendarPermission()

        return PermissionStatus(microphone: microphone, calendar: calendar)
    }
}

struct PermissionStatus {
    let microphone: Bool
    let calendar: Bool

    var canRecord: Bool {
        // Microphone permission is required for recording
        // System audio via Core Audio Taps will prompt separately if needed
        microphone
    }

    var allGranted: Bool {
        microphone && calendar
    }
}
