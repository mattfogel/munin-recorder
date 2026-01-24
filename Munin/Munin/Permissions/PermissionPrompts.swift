import AppKit

enum PermissionPrompts {

    static func showMicrophoneAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = """
            Munin needs Microphone permission to capture your voice.

            Without microphone access, only system audio will be recorded.

            Please grant permission in System Settings:
            Privacy & Security → Microphone → Enable Munin
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Continue Without Microphone")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }

    static func showPermissionDeniedAlert(permission: String) {
        let alert = NSAlert()
        alert.messageText = "\(permission) Permission Denied"
        alert.informativeText = """
            Munin cannot function without \(permission.lowercased()) permission.

            Please enable it in System Settings and restart Munin.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openPrivacySettings()
        } else {
            NSApp.terminate(nil)
        }
    }

    private static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    private static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
        NSWorkspace.shared.open(url)
    }

    static func showCalendarAlert() {
        let alert = NSAlert()
        alert.messageText = "Calendar Permission"
        alert.informativeText = """
            Munin can use your calendar to automatically name recordings after your meetings.

            This is optional - without calendar access, recordings will use "unknown-meeting" as the name.

            Please grant permission in System Settings:
            Privacy & Security → Calendars → Enable Munin
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Continue Without Calendar")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openCalendarSettings()
        }
    }

    static func openCalendarSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }
}
