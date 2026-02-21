import Foundation
import CoreAudio
import AudioToolbox

/// Monitors microphone activity via Core Audio property listeners.
/// When mic becomes active, uses the Process Object API to identify which
/// process is using input, and matches against a known meeting app allowlist.
final class MicActivityMonitor: @unchecked Sendable {
    private var currentDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var isMonitoring = false
    private let queue = DispatchQueue(label: "com.munin.micmonitor")

    /// Callback: (isActive, appName?) — appName is non-nil only when a known meeting app is using the mic.
    var onMicActivityChanged: ((Bool, String?) -> Void)?

    private static let myPID = ProcessInfo.processInfo.processIdentifier

    /// Known meeting apps: bundle ID prefix → display name.
    /// Prefix matching catches Electron helper processes (e.g. com.tinyspeck.slackmacgap.helper).
    private static let knownMeetingApps: [String: String] = [
        // Native conferencing
        "us.zoom":                      "Zoom",
        "com.microsoft.teams":          "Microsoft Teams",
        "com.webex":                    "Webex",
        "com.tinyspeck.slackmacgap":    "Slack",
        "com.hhopperbot.Discord":       "Discord",
        "com.discord":                  "Discord",
        "com.apple.FaceTime":           "FaceTime",
        "com.skype.skype":              "Skype",
        // Browsers (any browser mic usage treated as potential meeting)
        "com.google.Chrome":            "Google Chrome",
        "com.apple.Safari":             "Safari",
        "company.thebrowser.Browser":   "Arc",
        "com.brave.Browser":            "Brave",
        "com.microsoft.edgemac":        "Microsoft Edge",
        "org.mozilla.firefox":          "Firefox",
    ]

    init() {}

    func startMonitoring() {
        queue.async { [weak self] in
            self?.setupMonitoring()
        }
    }

    func stopMonitoring() {
        queue.async { [weak self] in
            self?.teardownMonitoring()
        }
    }

    private func setupMonitoring() {
        guard !isMonitoring else { return }

        // Get default input device
        updateDefaultInputDevice()

        // Listen for default input device changes
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AudioObjectAddPropertyListener(
            systemObjectID,
            &defaultDeviceAddress,
            defaultDeviceChangedCallback,
            selfPtr
        )

        isMonitoring = true
        debugLog("MicActivityMonitor started")
    }

    private func teardownMonitoring() {
        guard isMonitoring else { return }

        // Remove device-specific listener
        removeDeviceListener()

        // Remove default device listener
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AudioObjectRemovePropertyListener(
            systemObjectID,
            &defaultDeviceAddress,
            defaultDeviceChangedCallback,
            selfPtr
        )

        isMonitoring = false
        currentDeviceID = kAudioObjectUnknown
        debugLog("MicActivityMonitor stopped")
    }

    private func updateDefaultInputDevice() {
        // Remove old listener if device changed
        removeDeviceListener()

        // Get new default input device
        var deviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            debugLog("Failed to get default input device")
            return
        }

        currentDeviceID = deviceID
        addDeviceListener()

        // Check current state — if mic already active, detect which app is using it
        let isActive = isMicCurrentlyActive()
        debugLog("Monitoring device \(deviceID), currently active: \(isActive)")
        if isActive {
            let appName = detectMeetingApp()?.name
            onMicActivityChanged?(true, appName)
        }
    }

    private func addDeviceListener() {
        guard currentDeviceID != kAudioObjectUnknown else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AudioObjectAddPropertyListener(
            currentDeviceID,
            &address,
            deviceRunningChangedCallback,
            selfPtr
        )
    }

    private func removeDeviceListener() {
        guard currentDeviceID != kAudioObjectUnknown else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AudioObjectRemovePropertyListener(
            currentDeviceID,
            &address,
            deviceRunningChangedCallback,
            selfPtr
        )
    }

    func isMicCurrentlyActive() -> Bool {
        guard currentDeviceID != kAudioObjectUnknown else { return false }

        var isRunning: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            currentDeviceID,
            &address,
            0,
            nil,
            &propertySize,
            &isRunning
        )

        return status == noErr && isRunning != 0
    }

    // MARK: - Process Object API (Meeting App Detection)

    /// Enumerate CoreAudio process objects to find which known meeting app
    /// is currently using microphone input. Returns nil if no match.
    func detectMeetingApp() -> (bundleID: String, name: String)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processIDs
        ) == noErr else { return nil }

        for processID in processIDs {
            // Check isRunningInput first (cheapest filter)
            guard isProcessRunningInput(processID) else { continue }

            // Skip self by PID
            if getProcessPID(processID) == Self.myPID { continue }

            guard let bundleID = getProcessBundleID(processID) else { continue }

            // Match against allowlist (prefix match for Electron helper variants)
            if let name = Self.knownMeetingApps.first(where: { bundleID.hasPrefix($0.key) })?.value {
                debugLog("Meeting app detected: \(name) (\(bundleID))")
                return (bundleID: bundleID, name: name)
            } else {
                debugLog("Non-meeting app using mic: \(bundleID)")
            }
        }
        return nil
    }

    private func isProcessRunningInput(_ processID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }

    private func getProcessPID(_ processID: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &pid)
        return pid
    }

    /// Read bundle ID from a CoreAudio process object.
    /// kAudioProcessPropertyBundleID returns a +1 CFString — must use
    /// Unmanaged.takeRetainedValue() to transfer ownership and avoid leaks.
    private func getProcessBundleID(_ processID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rawPtr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &rawPtr) { ptr in
            AudioObjectGetPropertyData(processID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let unmanaged = rawPtr else { return nil }
        return unmanaged.takeRetainedValue() as String
    }

    fileprivate func handleDefaultDeviceChanged() {
        queue.async { [weak self] in
            self?.updateDefaultInputDevice()
        }
    }

    fileprivate func handleRunningStateChanged() {
        let isActive = isMicCurrentlyActive()
        debugLog("Mic activity changed: \(isActive)")
        let appName = isActive ? detectMeetingApp()?.name : nil
        onMicActivityChanged?(isActive, appName)
    }
}

// MARK: - Callbacks

private func defaultDeviceChangedCallback(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = clientData else { return noErr }
    let monitor = Unmanaged<MicActivityMonitor>.fromOpaque(clientData).takeUnretainedValue()
    monitor.handleDefaultDeviceChanged()
    return noErr
}

private func deviceRunningChangedCallback(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = clientData else { return noErr }
    let monitor = Unmanaged<MicActivityMonitor>.fromOpaque(clientData).takeUnretainedValue()
    monitor.handleRunningStateChanged()
    return noErr
}
