import AppKit
import SwiftUI
import EventKit

/// Reusable notification panel that appears in the top-right corner
/// Replaces system notifications for better visibility during DND and full-screen modes
final class NotificationNubPanel: NSPanel {
    private var autoDismissTimer: Timer?
    private var onAction: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configure()
    }

    private func configure() {
        // Window behavior - assistive tech level to appear above all windows
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
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

        // Dark appearance
        appearance = NSAppearance(named: .darkAqua)

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

    // MARK: - Show Variants

    /// Simple info notification (e.g., "Recording Started")
    /// Auto-dismisses after 3 seconds
    func showInfo(title: String, subtitle: String) {
        let contentView = NotificationNubView(
            variant: .info(title: title, subtitle: subtitle),
            onDismiss: { [weak self] in self?.dismissAnimated() },
            onAction: nil,
            onSecondaryAction: nil,
            onTertiaryAction: nil
        )

        show(contentView: contentView, autoDismissAfter: 3.0)
    }

    /// Status notification with optional error state (e.g., "Meeting Processed")
    /// Auto-dismisses after 8 seconds, clickable to perform action
    func showStatus(title: String, subtitle: String, isError: Bool, onTap: (() -> Void)? = nil) {
        self.onAction = onTap

        let contentView = NotificationNubView(
            variant: .status(title: title, subtitle: subtitle, isError: isError),
            onDismiss: { [weak self] in self?.dismissAnimated() },
            onAction: onTap != nil ? { [weak self] in
                self?.dismissAnimated()
                onTap?()
            } : nil,
            onSecondaryAction: nil,
            onTertiaryAction: nil
        )

        show(contentView: contentView, autoDismissAfter: 8.0)
    }

    /// Interactive meeting reminder with three buttons
    /// Auto-dismisses after 30 seconds
    func showMeetingReminder(
        event: EKEvent,
        minutesUntilStart: Int,
        onStartRecording: @escaping () -> Void,
        onJoinAndRecord: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let contentView = NotificationNubView(
            variant: .meetingReminder(
                title: event.title ?? "Untitled Meeting",
                minutesUntilStart: minutesUntilStart
            ),
            onDismiss: { [weak self] in
                self?.dismissAnimated()
                onDismiss()
            },
            onAction: { [weak self] in
                self?.dismissAnimated()
                onStartRecording()
            },
            onSecondaryAction: { [weak self] in
                self?.dismissAnimated()
                onJoinAndRecord()
            },
            onTertiaryAction: { [weak self] in
                self?.dismissAnimated()
                onDismiss()
            }
        )

        show(contentView: contentView, autoDismissAfter: 30.0)
    }

    // MARK: - Private

    private func show<V: View>(contentView: V, autoDismissAfter seconds: TimeInterval) {
        autoDismissTimer?.invalidate()

        self.contentView = NSHostingView(rootView: contentView)

        // Resize to fit content
        if let hostingView = self.contentView as? NSHostingView<V> {
            hostingView.invalidateIntrinsicContentSize()
            let size = hostingView.fittingSize
            setContentSize(size)
        }

        positionTopRight()

        // Fade in (200ms)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().alphaValue = 1
        }

        // Auto-dismiss timer
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.dismissAnimated()
        }
    }

    private func dismissAnimated() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil

        // Fade out (150ms)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
        }
    }
}

// MARK: - SwiftUI Content View

private enum NotificationVariant {
    case info(title: String, subtitle: String)
    case status(title: String, subtitle: String, isError: Bool)
    case meetingReminder(title: String, minutesUntilStart: Int)
}

private struct NotificationNubView: View {
    let variant: NotificationVariant
    let onDismiss: () -> Void
    let onAction: (() -> Void)?
    let onSecondaryAction: (() -> Void)?
    let onTertiaryAction: (() -> Void)?

    var body: some View {
        Group {
            switch variant {
            case .info(let title, let subtitle):
                infoView(title: title, subtitle: subtitle)

            case .status(let title, let subtitle, let isError):
                statusView(title: title, subtitle: subtitle, isError: isError)

            case .meetingReminder(let title, let minutesUntilStart):
                meetingReminderView(title: title, minutesUntilStart: minutesUntilStart)
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

    // MARK: - Info View (simple notification)

    private func infoView(title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            MuninIcon()
                .fill(Color.white)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

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
    }

    // MARK: - Status View (clickable notification)

    private func statusView(title: String, subtitle: String, isError: Bool) -> some View {
        let content = HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(isError ? .orange : .green)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if onAction != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
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
        }

        return Group {
            if onAction != nil {
                Button(action: { onAction?() }) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    // MARK: - Meeting Reminder View (interactive with buttons)

    private func meetingReminderView(title: String, minutesUntilStart: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                MuninIcon()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting Starting Soon")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)

                    let timeText = minutesUntilStart == 1 ? "1 minute" : "\(minutesUntilStart) minutes"
                    Text("\(title) starts in \(timeText)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

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
            HStack(spacing: 8) {
                // Dismiss button
                Button(action: { onTertiaryAction?() }) {
                    Text("Dismiss")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.1))
                .cornerRadius(6)

                // Start Recording button
                Button(action: { onAction?() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 11))
                        Text("Record")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Color.red)
                .foregroundColor(.white)
                .cornerRadius(6)

                // Join & Record button
                Button(action: { onSecondaryAction?() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 11))
                        Text("Join & Record")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(6)
            }
        }
    }
}
