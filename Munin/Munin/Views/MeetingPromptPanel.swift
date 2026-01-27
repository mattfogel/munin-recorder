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
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configure()
    }

    private func configure() {
        // Window behavior - use maximum level to ensure we're above time-sensitive notifications
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .transient]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        ignoresMouseEvents = false

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

    func show(appName: String?, onStartRecording: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onStartRecording = onStartRecording
        self.onDismiss = onDismiss

        // Create SwiftUI content
        let contentView = MeetingPromptView(
            appName: appName,
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
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
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
    let appName: String?
    let onStartRecording: () -> Void
    let onDismiss: () -> Void

    private var headerText: String {
        if let appName = appName {
            return "Meeting detected in \(appName)"
        } else {
            return "Meeting detected"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                MuninIcon()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)

                Text(headerText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

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
