---
title: "feat: Process-aware meeting detection"
type: feat
date: 2026-02-18
---

## Enhancement Summary

**Deepened on:** 2026-02-18
**Sections enhanced:** All
**Agents used:** architecture-strategist, performance-oracle, security-sentinel, code-simplicity-reviewer, pattern-recognition-specialist, best-practices-researcher, framework-docs-researcher

### Key Improvements
1. **Simplified from 5 phases to 2** — removed retry logic, suppression flag, MeetingApp struct, and calendar coordination (all YAGNI)
2. **Fixed CFString memory leak** — must use `Unmanaged<CFString>.takeRetainedValue()` for `kAudioProcessPropertyBundleID`
3. **Fixed deadlock risk** — original `queue.sync` in `suppressDetection()` would deadlock from @MainActor
4. **Improved architecture** — monitor returns bundleID only, name resolved on @MainActor; self-filtering by PID instead of bundle ID
5. **Dictionary allowlist** — maps bundleID prefix to display name, eliminating NSWorkspace lookup for known apps

### Critical Bugs Found in Original Plan
- **CFString memory leak** in `getProcessBundleID()` — CoreAudio returns a +1 CFString that must be released via `Unmanaged.takeRetainedValue()`
- **Deadlock** in `suppressDetection()` — `queue.sync` from @MainActor while callback bridges to @MainActor = deadlock
- **Thread safety violation** — `NSWorkspace.shared.runningApplications` called from background DispatchQueue

---

# feat: Process-aware meeting detection

## Overview

Replace the naive `kAudioDevicePropertyDeviceIsRunningSomewhere` mic detection with CoreAudio's Process Object API to identify *which* process is using the mic. Only prompt when a known conferencing app or browser is the mic user — eliminating false positives from Voice Memos, Siri, GarageBand, etc. Also fix the self-detection race condition where Munin's own recording triggers a "Meeting detected" prompt.

## Problem Statement / Motivation

Current `MicActivityMonitor` fires whenever *any* app uses the microphone. This causes:
1. **False positives** from non-meeting apps (Voice Memos, Siri, dictation, GarageBand)
2. **Self-detection race condition** — Munin's own mic capture triggers a "Meeting detected" prompt before `AppState.state` transitions to `.recording`
3. **Generic prompts** — even when detection works, it often shows "Meeting detected" instead of identifying the app, because `detectMicUsingApp()` only checks the frontmost app by display name

## Proposed Solution

Use the CoreAudio Process Object API (public, macOS 14+) to enumerate audio processes and check `kAudioProcessPropertyIsRunningInput` per process. Match bundle IDs against a curated allowlist. Filter out Munin's own PID.

### Architecture

```
kAudioDevicePropertyDeviceIsRunningSomewhere fires (existing trigger)
    ↓
Enumerate kAudioHardwarePropertyProcessObjectList
    ↓
For each process, check kAudioProcessPropertyIsRunningInput (skip if false)
    ↓
Get kAudioProcessPropertyBundleID (only for active-input processes)
    ↓
Skip if PID == Munin's own PID
    ↓
Match against knownMeetingApps dictionary (prefix match)
    ↓
If match → fire callback with bundleID string
If no match → ignore (no prompt)
    ↓
MeetingDetectionService (@MainActor) resolves display name + shows prompt
```

**Key API selectors:**
- `kAudioHardwarePropertyProcessObjectList` — all audio client processes
- `kAudioProcessPropertyIsRunningInput` — is this process using mic input?
- `kAudioProcessPropertyBundleID` — CFString bundle identifier (caller must release)
- `kAudioProcessPropertyPID` — process ID

**Reference implementation:** [insidegui/AudioCap CoreAudioUtils.swift](https://github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/CoreAudioUtils.swift)

### Research Insights

**API confirmed available macOS 14+ (Sonoma).** Identical in macOS 15.4 and 26.2 SDKs. The Process Object API has no additional entitlement or TCC requirements — works unsandboxed with no special permissions.

**`kAudioProcessPropertyIsRunningInput` polling is reliable.** However, property *listeners* for this selector do not fire reliably (known HAL limitation reported on Apple Developer Forums). Use the existing `kAudioDevicePropertyDeviceIsRunningSomewhere` listener as the trigger, then poll process properties inside the callback. This is the correct pattern.

**`AudioObjectGetPropertyData` is empirically thread-safe for reads.** JUCE, PortAudio, and AudioCap all call it from multiple threads without synchronization. Do NOT call from the realtime audio render callback (can cause priority inversion). Calling from `com.munin.micmonitor` DispatchQueue is correct.

**Process list is dynamic.** Processes connect/disconnect from HAL continuously. Always re-enumerate on each callback — do not cache the list.

**Common error: `kAudioHardwareBadObjectError` (`'!obj'`).** A process can vanish between enumeration and property read. Handle gracefully (return nil, continue iteration).

## Implementation Plan

### Phase 1: Process enumeration in MicActivityMonitor

**Files:** `Munin/Services/MicActivityMonitor.swift`

Replace `detectMicUsingApp()` (lines 183-208) with CoreAudio Process Object API enumeration.

1. Add a bundle ID allowlist as a `Dictionary<String, String>` mapping prefix → display name. This eliminates the need for NSWorkspace lookup on the background thread:

```swift
// MicActivityMonitor.swift

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

private static let myPID = ProcessInfo.processInfo.processIdentifier
```

2. Replace `detectMicUsingApp()` with `detectMeetingApp()`. Returns `(bundleID: String, name: String)?`:

```swift
// MicActivityMonitor.swift

/// Enumerate CoreAudio process objects to find which known meeting app
/// is currently using microphone input.
func detectMeetingApp() -> (bundleID: String, name: String)? {
    // 1. Get all audio process objects
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

    // 2. Check each process: isRunningInput first (cheapest filter), then bundleID
    for processID in processIDs {
        guard isProcessRunningInput(processID) else { continue }

        // Skip self by PID (more direct than bundle ID comparison)
        if getProcessPID(processID) == Self.myPID { continue }

        guard let bundleID = getProcessBundleID(processID) else { continue }

        // 3. Match against allowlist (prefix match for Electron helper variants)
        if let name = Self.knownMeetingApps.first(where: { bundleID.hasPrefix($0.key) })?.value {
            debugLog("Meeting app detected: \(name) (\(bundleID))")
            return (bundleID: bundleID, name: name)
        } else {
            debugLog("Non-meeting app using mic: \(bundleID)")
        }
    }
    return nil
}
```

3. Add CoreAudio helper methods. **Critical: use `Unmanaged<CFString>.takeRetainedValue()` for bundleID** — the header states "the caller is responsible for releasing the returned CFObject":

```swift
// MicActivityMonitor.swift

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
/// IMPORTANT: kAudioProcessPropertyBundleID returns a +1 CFString.
/// Must use Unmanaged.takeRetainedValue() to avoid memory leak.
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
```

4. Update the callback signature to pass the app name string (not a struct):

```swift
// MicActivityMonitor.swift — change callback signature
var onMicActivityChanged: ((Bool, String?) -> Void)?
// Bool = mic active, String? = detected meeting app name (nil if no match or mic deactivated)
```

In `deviceRunningChangedCallback`, when mic becomes active, call `detectMeetingApp()` and pass the name. When mic deactivates, pass `nil`.

### Phase 2: Update MeetingDetectionService + startup check

**Files:** `Munin/Services/MeetingDetectionService.swift`

1. Update `handleMicActivityChanged` to accept `String?` (app name). The self-detection race condition is fixed by PID filtering in Phase 1 — no additional suppression flag needed:

```swift
// MeetingDetectionService.swift
private func handleMicActivityChanged(_ isActive: Bool, appName: String?) {
    guard isActive else { return }
    guard appState?.state == .idle else { return }
    guard !isInCooldown() else { return }

    // Only prompt if a meeting app was identified
    guard let appName else {
        debugLog("Mic active but no meeting app detected, ignoring")
        return
    }

    showMeetingPrompt(appName: appName)
}
```

2. Wire callback in setup:

```swift
// MeetingDetectionService.swift
micMonitor.onMicActivityChanged = { [weak self] isActive, appName in
    Task { @MainActor [weak self] in
        self?.handleMicActivityChanged(isActive, appName: appName)
    }
}
```

3. **Startup check** — in `MicActivityMonitor.updateDefaultInputDevice()`, after checking `isMicCurrentlyActive()`, run process enumeration immediately so Munin detects meetings already in progress at launch:

```swift
// MicActivityMonitor.swift — in updateDefaultInputDevice()
if isMicCurrentlyActive() {
    let result = detectMeetingApp()
    onMicActivityChanged?(true, result?.name)
}
```

### Research Insights

**Why no retry logic:** The original plan included a 300ms retry for a theoretical timing gap between mic activation and process object availability. Multiple reviewers flagged this as YAGNI — the CoreAudio property updates propagate in <100ms (per best practices research), and the process is typically already in the list when the callback fires. If testing reveals a real gap, add a retry then. Don't solve theoretical problems.

**Why no suppressDetection() flag:** The original plan added a synchronous suppression flag with `queue.sync`. This has two problems:
1. **Deadlock risk** — calling `queue.sync` from @MainActor while the callback bridges to @MainActor via `Task { @MainActor in }` creates a potential deadlock.
2. **Redundant** — PID-based self-filtering in `detectMeetingApp()` already prevents self-detection. The existing `appState?.state == .idle` guard is a second layer. A third layer adds complexity for no benefit.

**Why no calendar coordination (Phase 5 deferred):** Two overlapping prompts (calendar + mic detection) is mildly annoying but not broken. Adding cross-service coupling for a cosmetic issue is premature. If users complain, add `lastNotificationDate` to `CalendarAutoStartService` then.

**Why no MeetingApp struct:** The only consumer (`MeetingPromptPanel.show(appName:)`) takes a `String?`. The bundleID is only needed internally for allowlist matching. Passing a tuple from the monitor and a `String?` through the callback keeps the API minimal.

## Technical Considerations

**Threading:** `detectMeetingApp()` runs on `MicActivityMonitor`'s dedicated `com.munin.micmonitor` queue, same as existing CoreAudio callbacks. `AudioObjectGetPropertyData` is thread-safe for reads. Display name resolution uses the `knownMeetingApps` dictionary (static, immutable) — no main thread access needed for known apps.

**Performance:** Process enumeration = 1 IPC call for the list + N calls for `isRunningInput` + M calls for `bundleID` (M <= N). At N=15 (typical), total ~30 IPC calls = ~0.3-0.6ms. Runs on an event-driven callback (not polling), fires only on mic state transitions. No concern.

**CFString memory management:** `kAudioProcessPropertyBundleID` returns a +1 CFString per the SDK header: "The caller is responsible for releasing the returned CFObject." Must use `Unmanaged<CFString>.takeRetainedValue()`. The pattern in `SystemAudioCapture.getDeviceUID()` (lines 72-88) is the existing codebase reference. SDL2 had the same leak bug — see [SDL#9943](https://github.com/libsdl-org/SDL/issues/9943).

**Error handling:** `kAudioHardwareBadObjectError` (`'!obj'`) can occur if a process disconnects between enumeration and property read. The current code handles this gracefully — `AudioObjectGetPropertyData` returns an error, the guard returns nil, and iteration continues.

**Prefix matching trade-off:** Using prefix matching for all entries is simple but could theoretically match a malicious app with a crafted bundle ID. In practice, bundle ID namespaces make collisions extremely unlikely. For future hardening, exact matching for known-stable apps + prefix matching only for Electron apps (Slack, Discord, Chrome) would narrow the surface.

**Listener API choice:** Stick with the existing `AudioObjectAddPropertyListener` (C-style) pattern. `AudioObjectRemovePropertyListenerBlock` has known issues with block identity — removal can silently fail. The codebase already uses the proc-based API correctly with `Unmanaged` pointer passing.

## Acceptance Criteria

- [x] Voice Memos, Siri, dictation, and other non-meeting mic usage does NOT trigger a prompt
- [x] Zoom, Teams, Slack, Discord, FaceTime, Skype, Webex calls trigger a prompt with the app name
- [x] Chrome/Safari/Arc/Brave/Edge/Firefox mic usage triggers a prompt with the browser name
- [x] Munin's own recording does NOT trigger a "Meeting detected" prompt (PID filtering)
- [x] Prompt shows detected app name (e.g., "Meeting detected in Zoom")
- [x] Existing debouncing preserved: 10-minute cooldown, idle-only detection, 15-second auto-dismiss
- [x] Detection works when Munin launches during an ongoing meeting (startup check)
- [x] `debugLog` output shows which process was detected (or why detection was suppressed)
- [x] No CFString memory leaks (verify with Instruments Leaks template)

## Dependencies & Risks

**Risk: Process Object API timing gap.** `kAudioProcessPropertyIsRunningInput` may not reflect the true state at the exact moment `kAudioDevicePropertyDeviceIsRunningSomewhere` fires (HAL propagation delay <100ms). **Mitigation:** Accept this for MVP. If testing shows missed detections, add a Combine `.debounce(for: .milliseconds(300))` on the mic activity signal — more idiomatic than a retry loop in a codebase already using Combine.

**Risk: Bundle ID changes.** Apps occasionally change bundle IDs (Zoom: `us.zoom.ZoomVideoNS` → `us.zoom.xos`). **Mitigation:** Prefix matching + `debugLog` output for unrecognized mic-using processes (easy to spot and add new IDs).

**Risk: Electron helper processes.** Some Electron apps run audio in a helper process with a different bundle ID suffix. **Mitigation:** Prefix matching (e.g., `com.tinyspeck.slackmacgap` matches both main app and `.helper`).

**Risk: `Unmanaged.passUnretained(self)` lifetime.** Pre-existing pattern in `MicActivityMonitor` — if the object is deallocated while listeners are registered, dangling pointer crash. **Mitigation:** The object lives for app lifetime (held by `MeetingDetectionService`). Document the contract: must call `stopMonitoring()` before deallocation.

**Not in scope (future iterations):**
- AppleScript browser tab URL detection (identify Google Meet vs generic Chrome)
- User-configurable allowlist
- Monitoring non-default input devices
- CalendarAutoStartService duplicate prompt suppression

## References & Research

- Brainstorm: `docs/brainstorms/2026-02-18-meeting-detection-rethink-brainstorm.md`
- CoreAudio Process Object API: `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyPID`
- SDK header: `CoreAudio.framework/Versions/A/Headers/AudioHardware.h` (lines 586-633 for process list, 1955-1970 for process properties)
- Reference implementation: [insidegui/AudioCap CoreAudioUtils.swift](https://github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/CoreAudioUtils.swift)
- CFString leak precedent: [SDL2 #9943](https://github.com/libsdl-org/SDL/issues/9943)
- OverSight (alternative approach via unified logs): [github.com/objective-see/OverSight](https://github.com/objective-see/OverSight)
- Existing files to modify:
  - `Munin/Services/MicActivityMonitor.swift` (Phase 1 — replace detection, add CoreAudio helpers)
  - `Munin/Services/MeetingDetectionService.swift` (Phase 2 — update callback handling)
  - `Munin/Views/MeetingPromptPanel.swift` (no changes needed — already accepts `appName`)
