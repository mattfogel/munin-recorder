import Foundation
import AVFoundation

final class PermissionChecker {

    /// Checks if microphone permission is granted
    func hasMicrophonePermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Requests microphone permission
    func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Checks all required permissions
    func checkAllPermissions() async -> PermissionStatus {
        let microphone = hasMicrophonePermission()

        return PermissionStatus(microphone: microphone)
    }
}

struct PermissionStatus {
    let microphone: Bool

    var canRecord: Bool {
        // Microphone permission is required for recording
        // System audio via Core Audio Taps will prompt separately if needed
        microphone
    }

    var allGranted: Bool {
        microphone
    }
}
