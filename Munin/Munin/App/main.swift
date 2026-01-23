import AppKit

@MainActor
func runApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate

    app.run()
}

MainActor.assumeIsolated {
    runApp()
}
