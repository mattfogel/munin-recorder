---
topic: Meeting Detection Rethink
date: 2026-02-18
status: decided
---

# Meeting Detection Rethink

## What We're Building

Replace the naive mic-activity-based meeting detection with process-aware detection using CoreAudio's Process Object API. Instead of prompting whenever *any* app uses the mic, identify *which* process is using it and only prompt when it's a known conferencing app or browser.

## Why This Approach

**Problem:** Current detection uses `kAudioDevicePropertyDeviceIsRunningSomewhere` which fires for any mic usage (Voice Memos, Siri, music apps, etc.). There's also a race condition where Munin's own recording triggers a "Meeting detected" prompt before state transitions to `.recording`.

**Chosen approach:** CoreAudio Process API (`kAudioProcessPropertyIsRunningInput`, public API, macOS 14+) to identify the exact process using the mic, then match against an allowlist.

**Why not more ambitious:**
- AppleScript browser tab URL detection (Approach B) adds Automation permission prompts and complexity — defer to a later iteration
- Calendar correlation (Approach C) partially exists via `CalendarAutoStartService` already — don't merge yet

## Key Decisions

1. **Use CoreAudio Process Object API** — `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput` to identify which process has the mic open. Public API, no private frameworks needed.

2. **Allowlist-based filtering** — Only prompt when the mic-using process matches:
   - Native conferencing apps: Zoom (`us.zoom.xos`), Teams (`com.microsoft.teams2`), Webex, Slack, Discord, FaceTime, Skype
   - Browsers: Chrome, Safari, Arc, Brave, Edge, Firefox (assume any browser mic usage is a meeting)
   - Ignore everything else (Voice Memos, Siri, GarageBand, etc.)

3. **Fix the race condition** — Munin's own mic usage triggers detection before state transitions to `.recording`. Need to either:
   - Exclude Munin's own bundle ID from the allowlist (simplest), or
   - Ensure monitoring stops *before* mic capture starts

4. **Always prompt for browsers** — Without tab URL detection, treat any browser mic usage as a potential meeting. Accept some false positives from browser-based voice features rather than miss web meetings.

5. **Keep existing debouncing** — 10-minute cooldown, state-based gating, 15-second auto-dismiss all stay.

## Competitive Context

- **Granola:** Likely uses this same CoreAudio Process API + AppleScript tab URLs + calendar correlation
- **Krisp:** Virtual audio device approach (user must configure apps to use Krisp mic) — too much friction
- **Bot-based products** (Otter, Fireflies, tl;dv): Calendar-only detection, irrelevant to local recording model

## Open Questions

- Should we show the detected app name in the prompt? (e.g., "Zoom meeting detected" vs "Meeting detected")
- What's the minimum macOS version we want to support? Process Object API requires macOS 14+. Current app targets macOS 26.
- Should unknown apps using the mic still have a fallback prompt, or strictly only allowlisted apps?

## Technical References

- CoreAudio Process Object API: `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyBundleID`
- Working Swift implementation: [insidegui/AudioCap CoreAudioUtils.swift](https://github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/CoreAudioUtils.swift)
- OverSight (Objective-See) for alternative PID detection via unified logs: [github.com/objective-see/OverSight](https://github.com/objective-see/OverSight)
- Existing Munin files to modify: `MicActivityMonitor.swift`, `MeetingDetectionService.swift`, `MeetingPromptPanel.swift`
