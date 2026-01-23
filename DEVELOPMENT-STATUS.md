# Munin Development Status

Last updated: 2026-01-23

## Current State

The app has a working window UI and core recording infrastructure. Menubar icon is not appearing (macOS 15 issue), but the window provides full functionality.

## What's Implemented

### App Structure
- [x] Xcode project with SwiftUI + AppKit hybrid
- [x] Window UI with Start/Stop recording button
- [x] Real-time recording duration timer
- [x] Granular processing status (Saving/Transcribing/Summarizing)
- [x] Error display in UI for failed operations
- [x] "Open Last Recording" button
- [x] macOS notifications on completion
- [x] App shows in Dock (LSUIElement=false for now)
- [x] MenuBarExtra working (requires proper code signing)
- [x] AppDelegate with permission checking

### Audio Capture
- [x] SystemAudioCapture using ScreenCaptureKit
- [x] SCStream configured with `capturesAudio=true` and `captureMicrophone=true` (macOS 15+)
- [x] Separate `.microphone` output handler for macOS 15+
- [x] AudioFileWriter with AVAssetWriter → .m4a (AAC, 48kHz, mono)
- [x] AudioCaptureCoordinator orchestrating the flow
- [x] Debug logging for audio sample counts

### Storage
- [x] MeetingStorage creates `~/Meetings/DATE/TIME-name/` folders
- [x] MeetingRecord model with URLs for audio.m4a, transcript.md, summary.md
- [x] FileNaming utilities for sanitization

### Processing Pipeline
- [x] ProcessRunner - generic async subprocess wrapper with timeout
- [x] TranscriptionService - whisper.cpp invocation, audio conversion via afconvert
- [x] SummarizationService - Claude CLI invocation with prompt

### Permissions
- [x] PermissionChecker for Screen Recording and Microphone status
- [x] PermissionPrompts with alerts and System Settings links
- [x] Privacy descriptions in Info.plist

## Known Issues

### 1. Microphone Audio Quality (Slight Jitter) - PARTIALLY FIXED
- **Symptom**: Mic audio has robotic/fuzzy artifacts when mixed with system audio
- **Root cause**: Async arrival of system audio and mic with no timestamp alignment
- **Fixes applied** (in AudioMixer.swift):
  - Increased buffer size: 4096 → 8192 samples (~170ms) to absorb timing jitter
  - High-quality resampling: `.max` quality + `AVSampleRateConverterAlgorithm_Mastering`
  - Startup buffering: Wait for ~200ms from both sources before mixing
  - Changed mixing condition: OR → AND (only mix when both have data, no silence padding)
  - Crossfade at buffer boundaries: 64 samples (~1.3ms) to eliminate clicks
- **If still problematic**, escalate to timestamp-based sync:
  - Use `CMSampleBufferGetPresentationTimeStamp()` to align samples by time
  - Implement a proper ring buffer with timestamp interpolation
  - Consider separate tracks instead of real-time mixing

### 2. Menubar Icon Not Appearing - FIXED
- **Cause**: Ad-hoc signing ("Sign to Run Locally")
- **Fix**: Use a real Apple Developer signing identity (even free account works)
- Go to Signing & Capabilities → set Team → enable "Automatically manage signing"
- This also fixes permissions resetting on every build

### 2. Screen Recording Permission Loop - FIXED
- **Cause**: Ad-hoc signing caused TCC to see each build as a new app
- **Fix**: Use proper code signing (same fix as menubar icon)

### 3. No App Icon
- Asset catalog has placeholder, no actual icon images
- **Status**: TODO

## Files Structure

```
Munin/
├── Munin.xcodeproj/
└── Munin/
    ├── App/
    │   ├── MuninApp.swift          # @main, WindowGroup + MenuBarExtra
    │   ├── AppDelegate.swift       # Permission checks on launch
    │   └── AppState.swift          # Recording state machine
    ├── Menubar/
    │   ├── StatusBarController.swift  # NSStatusItem (not working)
    │   └── MenuBuilder.swift          # NSMenu builder (not working)
    ├── Audio/
    │   ├── AudioCaptureCoordinator.swift
    │   ├── SystemAudioCapture.swift   # SCStream + mic
    │   └── AudioFileWriter.swift      # AVAssetWriter
    ├── Processing/
    │   ├── ProcessRunner.swift
    │   ├── TranscriptionService.swift
    │   └── SummarizationService.swift
    ├── Storage/
    │   ├── FileNaming.swift
    │   ├── MeetingRecord.swift
    │   └── MeetingStorage.swift
    ├── Permissions/
    │   ├── PermissionChecker.swift
    │   └── PermissionPrompts.swift
    └── Resources/
        ├── Info.plist
        ├── Assets.xcassets/
        └── Munin.entitlements
```

## Next Steps

### Immediate (to get recording working)
1. [x] Fix Screen Recording permission - clean rebuild, re-grant
2. [x] Verify audio capture works (check console for sample counts)
3. [x] Test full recording → stop → file saved flow
4. [x] Verify both system audio AND microphone are captured

### Short-term
5. [ ] Add app icon (create or generate PNG assets)
6. [ ] Test transcription with whisper.cpp installed
7. [ ] Test summarization with Claude CLI
8. [x] Add error display in UI for failed recordings

### Medium-term
9. [x] ~~Investigate menubar icon issue~~ Fixed by using proper code signing
10. [x] Add recording duration timer that updates in real-time
11. [x] Add "Open Last Recording" button that shows specific recording
12. [x] Add notification when processing completes

### Future (from original spec)
- Calendar integration (EventKit)
- App detection (NSWorkspace)
- Auto-start from calendar
- Meeting naming from calendar events

## Prerequisites for Testing

### whisper.cpp
```bash
# Install whisper.cpp and download model
# Place model at ~/.munin/models/ggml-base.en.bin
# Or update TranscriptionService.swift with correct path
```

### Claude CLI
```bash
npm install -g @anthropic-ai/claude-code
claude  # authenticate
```

## How to Resume Development

1. Open `Munin/Munin.xcodeproj` in Xcode
2. If Screen Recording permission issues:
   - System Settings → Privacy & Security → Screen Recording
   - Remove Munin, clean build (Cmd+Shift+K), rebuild
3. Run with Cmd+R
4. Window should appear with "Start Recording" button
5. Check Xcode console for debug output

## Console Output to Expect (Working Recording)

```
Munin: applicationDidFinishLaunching
Munin: Starting recording...
Munin: Created folder at /Users/matt/Meetings/DATE/TIME-unknown-meeting
Munin: Audio capture started successfully
Munin: Audio capture started
Munin: System audio samples received: 1
Munin: System audio samples received: 101
Munin: Microphone samples received: 1
Munin: Microphone samples received: 101
...
```

If you only see system audio OR only microphone, there's a capture issue.
If you see the TCC error, permission needs to be re-granted.
