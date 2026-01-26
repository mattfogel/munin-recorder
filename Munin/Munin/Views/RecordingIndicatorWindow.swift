import AppKit
import SwiftUI
import Combine

/// Mini floating window showing recording status
/// Hidden from screen share via sharingType = .none
final class RecordingIndicatorWindow: NSPanel {
    private static let positionKey = "RecordingIndicatorPosition"

    private var hostingView: NSHostingView<RecordingIndicatorView>?
    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 56),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configure()
        setupContent()
        restorePosition()
    }

    private func configure() {
        // Window behavior
        level = .floating
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true

        // Hide from screen share
        sharingType = .none

        // Visual style
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        // Dark appearance
        appearance = NSAppearance(named: .darkAqua)

        // Animation
        animationBehavior = .utilityWindow

        // Save position when moved
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    private func setupContent() {
        guard let appState = appState else { return }

        let contentView = RecordingIndicatorView(
            appState: appState,
            onStop: { [weak self] in
                Task { @MainActor in
                    await self?.appState?.stopRecording()
                }
            }
        )

        hostingView = NSHostingView(rootView: contentView)
        self.contentView = hostingView
    }

    private func restorePosition() {
        if let positionString = UserDefaults.standard.string(forKey: Self.positionKey),
           let data = positionString.data(using: .utf8),
           let point = try? JSONDecoder().decode(CGPoint.self, from: data) {
            // Validate position is on screen
            if let screen = NSScreen.main, screen.visibleFrame.contains(point) {
                setFrameOrigin(point)
                return
            }
        }

        // Default: bottom-right corner
        positionBottomRight()
    }

    private func positionBottomRight() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - frame.width - 20
        let y = screenFrame.minY + 20
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func windowDidMove(_ notification: Notification) {
        savePosition()
    }

    private func savePosition() {
        if let data = try? JSONEncoder().encode(frame.origin),
           let string = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(string, forKey: Self.positionKey)
        }
    }

    func showAnimated() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().alphaValue = 1
        }
    }

    func hideAnimated() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
        }
    }
}

// MARK: - SwiftUI Content View

private struct RecordingIndicatorView: View {
    @ObservedObject var appState: AppState
    let onStop: () -> Void

    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 10) {
            // Recording indicator - Munin icon
            MuninIcon()
                .fill(Color.white)
                .frame(width: 14, height: 14)

            // Timer
            Text(formatDuration(elapsedTime))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .fixedSize()

            Spacer()

            // Audio levels
            AudioLevelView(levels: appState.audioLevels)
                .frame(width: 36, height: 24)

            // Stop button
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.red.opacity(0.8))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 200, height: 56)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.95))
                .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
    }

    private func startTimer() {
        elapsedTime = appState.recordingDuration
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                elapsedTime = appState.recordingDuration
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
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
