import AppKit
import SwiftUI

/// Floating panel that prompts user to record detected meetings
/// Appears even during DND since it's not a system notification
final class MeetingPromptPanel: NSPanel {
    private var autoDismissTimer: Timer?
    private var onStartRecording: (() -> Void)?
    private var onDismiss: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configure()
    }

    private func configure() {
        // Window behavior
        level = .floating
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true

        // Visual style
        backgroundColor = .clear
        isOpaque = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        // Appearance
        appearance = NSAppearance(named: .darkAqua)

        // Position in top-right
        positionTopRight()

        // Animation
        animationBehavior = .utilityWindow
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - frame.width - 20
        let y = screenFrame.maxY - frame.height - 20
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show(meetingTitle: String?, onStartRecording: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onStartRecording = onStartRecording
        self.onDismiss = onDismiss

        // Create SwiftUI content
        let contentView = MeetingPromptView(
            meetingTitle: meetingTitle ?? "Unknown Meeting",
            onStartRecording: { [weak self] in
                self?.handleStartRecording()
            },
            onDismiss: { [weak self] in
                self?.handleDismiss()
            }
        )

        self.contentView = NSHostingView(rootView: contentView)

        // Show with animation
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().alphaValue = 1
        }

        // Auto-dismiss after 15 seconds
        autoDismissTimer?.invalidate()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            self?.handleDismiss()
        }
    }

    private func handleStartRecording() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil

        closeWithAnimation { [weak self] in
            self?.onStartRecording?()
        }
    }

    private func handleDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil

        closeWithAnimation { [weak self] in
            self?.onDismiss?()
        }
    }

    private func closeWithAnimation(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion()
        }
    }
}

// MARK: - SwiftUI Content View

private struct MeetingPromptView: View {
    let meetingTitle: String
    let onStartRecording: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                MuninIcon()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)

                Text("Meeting detected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                // Dismiss X button
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.1))
                .clipShape(Circle())
            }

            // Meeting title
            Text(meetingTitle)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(2)

            // Buttons
            HStack(spacing: 10) {
                Button(action: onDismiss) {
                    Text("Not Now")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.1))
                .cornerRadius(6)

                Button(action: onStartRecording) {
                    HStack(spacing: 4) {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 11))
                        Text("Start Recording")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Color.red)
                .foregroundColor(.white)
                .cornerRadius(6)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.95))
                .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 8)
        )
    }
}
