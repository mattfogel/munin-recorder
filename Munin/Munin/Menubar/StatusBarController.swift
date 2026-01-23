import AppKit
import Combine

@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem?
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Munin")
        button.image?.isTemplate = true

        menuBuilder = MenuBuilder(appState: appState)
        statusItem?.menu = menuBuilder?.buildMenu()
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

        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Munin - Idle")
            button.image?.isTemplate = true

        case .recording:
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Munin - Recording")
            button.contentTintColor = .systemRed

        case .processing:
            button.image = NSImage(systemSymbolName: "gear.circle", accessibilityDescription: "Munin - Processing")
            button.image?.isTemplate = true
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
