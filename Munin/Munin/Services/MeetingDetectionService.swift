import Foundation
import AppKit
import Combine

/// Detects meeting starts via mic activity and prompts user to record
@MainActor
final class MeetingDetectionService: ObservableObject {
    private static let isEnabledKey = "MeetingDetectionEnabled"
    private static let cooldownDuration: TimeInterval = 10 * 60 // 10 minutes

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.isEnabledKey)
            updateMonitoringState()
        }
    }

    private let micMonitor = MicActivityMonitor()
    private var cooldownUntil: Date?
    private weak var appState: AppState?
    private var promptPanel: MeetingPromptPanel?
    private var stateObserver: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        // Restore saved preference (default: enabled)
        self.isEnabled = UserDefaults.standard.object(forKey: Self.isEnabledKey) as? Bool ?? true
        setupMicMonitor()
        observeAppState()
    }

    private func setupMicMonitor() {
        micMonitor.onMicActivityChanged = { [weak self] isActive in
            Task { @MainActor [weak self] in
                self?.handleMicActivityChanged(isActive)
            }
        }
    }

    private func observeAppState() {
        // Pause monitoring while recording to avoid detecting our own mic usage
        stateObserver = appState?.$state.sink { [weak self] state in
            self?.updateMonitoringState()
        }
    }

    private func updateMonitoringState() {
        let shouldMonitor = isEnabled && appState?.state == .idle
        if shouldMonitor {
            micMonitor.startMonitoring()
        } else {
            micMonitor.stopMonitoring()
        }
    }

    func startMonitoring() {
        updateMonitoringState()
        print("Munin: Meeting detection enabled")
    }

    func stopMonitoring() {
        micMonitor.stopMonitoring()
        print("Munin: Meeting detection disabled")
    }

    private func handleMicActivityChanged(_ isActive: Bool) {
        guard isActive else { return }
        guard isEnabled else { return }

        // Already recording?
        if appState?.state != .idle {
            print("Munin: Mic active but already recording/processing, ignoring")
            return
        }

        // In cooldown?
        if let cooldownUntil = cooldownUntil, Date() < cooldownUntil {
            print("Munin: Mic active but in cooldown until \(cooldownUntil)")
            return
        }

        // Show custom floating prompt
        showMeetingPrompt()
    }

    private func showMeetingPrompt() {
        // Get meeting title from calendar if available
        let meetingTitle: String?
        if let event = CalendarService.shared.getCurrentEvent() {
            meetingTitle = event.title
        } else {
            meetingTitle = nil
        }

        // Create panel if needed
        if promptPanel == nil {
            promptPanel = MeetingPromptPanel()
        }

        promptPanel?.show(
            meetingTitle: meetingTitle,
            onStartRecording: { [weak self] in
                self?.handleStartRecording()
            },
            onDismiss: { [weak self] in
                self?.handleDismiss()
            }
        )

        print("Munin: Showing meeting detection prompt")
    }

    private func handleStartRecording() {
        // Stop monitoring immediately to prevent detecting our own mic usage
        micMonitor.stopMonitoring()
        Task {
            try? await appState?.startRecording()
        }
    }

    private func handleDismiss() {
        startCooldown()
    }

    private func startCooldown() {
        cooldownUntil = Date().addingTimeInterval(Self.cooldownDuration)
        print("Munin: Meeting detection cooldown until \(cooldownUntil!)")
    }
}
