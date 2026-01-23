import AppKit
import Combine

@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem!
    private let appState: AppState
    private var menuBuilder: MenuBuilder?
    private var cancellables = Set<AnyCancellable>()
    private var durationTimer: Timer?

    init(appState: AppState) {
        self.appState = appState
        setupStatusItem()
        observeState()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            // Try system symbol image
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            if let image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Munin")?
                .withSymbolConfiguration(config) {
                button.image = image
                button.image?.isTemplate = true
                print("Munin: Set image on button")
            } else {
                // Fallback: create a simple colored image
                let size = NSSize(width: 18, height: 18)
                let image = NSImage(size: size, flipped: false) { rect in
                    NSColor.red.setFill()
                    NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
                    return true
                }
                button.image = image
                print("Munin: Set fallback red circle image")
            }
        }

        menuBuilder = MenuBuilder(appState: appState)
        statusItem.menu = menuBuilder?.buildMenu()

        print("Munin: Setup complete - button: \(String(describing: statusItem.button)), image: \(String(describing: statusItem.button?.image))")
    }

    private func observeState() {
        appState.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
                self?.updateTimer(for: state)
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    private func updateIcon(for state: AppState.RecordingState) {
        guard let button = statusItem?.button else { return }

        // Reset tint color
        button.contentTintColor = nil

        switch state {
        case .idle:
            if let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Munin - Idle") {
                button.image = image
                button.image?.isTemplate = true
                button.title = ""
            } else {
                button.image = nil
                button.title = "●"
            }

        case .recording:
            if let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Munin - Recording") {
                button.image = image
                button.contentTintColor = .systemRed
                button.title = ""
            } else {
                button.image = nil
                button.title = "⏺"
            }

        case .processing:
            if let image = NSImage(systemSymbolName: "gear.circle", accessibilityDescription: "Munin - Processing") {
                button.image = image
                button.image?.isTemplate = true
                button.title = ""
            } else {
                button.image = nil
                button.title = "⚙"
            }
        }
    }

    private func updateTimer(for state: AppState.RecordingState) {
        durationTimer?.invalidate()
        durationTimer = nil

        if state == .recording {
            durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.rebuildMenu()
                }
            }
        }
    }

    private func rebuildMenu() {
        statusItem?.menu = menuBuilder?.buildMenu()
    }
}
