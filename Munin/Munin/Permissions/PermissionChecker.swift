import Foundation
import AVFoundation
import ScreenCaptureKit

final class PermissionChecker {

    /// Checks if screen recording permission is granted
    /// Note: There's no direct API to check this before macOS 15
    /// We use CGWindowListCopyWindowInfo as a proxy check
    func hasScreenRecordingPermission() -> Bool {
        // Attempt to get window list - this requires screen recording permission
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]

        // If we can get window names/owners, we have permission
        // If permission is denied, the list will be empty or have no names
        guard let windows = windowList else { return false }

        for window in windows {
            if let name = window[kCGWindowName as String] as? String, !name.isEmpty {
                return true
            }
            if let owner = window[kCGWindowOwnerName as String] as? String, !owner.isEmpty {
                return true
            }
        }

        // If we got here but have windows, permission might be granted but no named windows visible
        return !windows.isEmpty
    }

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
        let screenRecording = hasScreenRecordingPermission()
        let microphone = hasMicrophonePermission()

        return PermissionStatus(
            screenRecording: screenRecording,
            microphone: microphone
        )
    }
}

struct PermissionStatus {
    let screenRecording: Bool
    let microphone: Bool

    var canRecord: Bool {
        screenRecording // Microphone is optional - we can still capture system audio
    }

    var allGranted: Bool {
        screenRecording && microphone
    }
}
