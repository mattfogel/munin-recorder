# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
open Munin/Munin.xcodeproj
# Cmd+B to build, Cmd+R to run
```

**Requirements:**
- macOS 15+ (Core Audio Taps), Xcode 16+
- Real Apple Developer identity for code signing (free account works) — ad-hoc breaks menubar icon
- whisper.cpp with model at `~/.munin/models/ggml-base.en.bin`
- Claude CLI authenticated (`npm install -g @anthropic-ai/claude-code && claude`)

**Permissions needed:** Screen Recording, Microphone, Calendar, Notifications (granted on first run)

## Architecture

```
MeetingDetectionService (mic activity monitoring)
    ↓
MeetingPromptPanel (floating NSPanel prompt)
    ↓
User triggers recording (or CalendarAutoStartService pre-meeting prompt)
    ↓
AppState (state machine: idle → recording → processing)
    ├─ RecordingIndicatorWindow (mini floating window, hidden from screen share)
    ├─ NotificationNubPanel (custom floating notifications)
    ↓
AudioCaptureCoordinator
  ├─ SystemAudioCapture (Core Audio Taps + AVAudioEngine)
  ├─ AudioMixer (real-time stereo mixing + RMS levels via Accelerate/vDSP)
  └─ AudioFileWriter (AVAssetWriter → AAC m4a)
    ↓
TranscriptionService (m4a → wav → whisper.cpp → transcript.md)
    ↓
SummarizationService (claude CLI → summary.md)
    ↓
Output: ~/Meetings/DATE/TIME-name/
```

## Key Technical Details

**Audio pipeline:**
- All internal: 48kHz mono float32 PCM per source
- Whisper input: 16kHz 16-bit PCM WAV (converted via afconvert)
- File output: AAC m4a, 48kHz stereo, 128kbps

**Transcription segmentation:**
- Uses whisper.cpp `--split-on-word` plus VTT/JSON/word outputs.
- Word-level timings are re-segmented in `TranscriptionService` to prevent long cues spanning silence.
- If `~/.munin/models/ggml-silero-v6.2.0.bin` exists, VAD is enabled to split on silence.
- Tuning knobs: whisper `--max-len`, VAD (`--vad-min-silence-duration-ms`, `--vad-max-speech-duration-s`, `--vad-threshold`, `--vad-speech-pad-ms`),
  and word segmentation in `TranscriptionService` (`wordGapMs`, `punctuationGapMs`, `maxSegmentChars`).

**Threading:**
- `@MainActor` on AppState, AppDelegate for UI/state
- `@unchecked Sendable` on audio classes with dedicated dispatch queues
- Async/await throughout capture and processing

**Audio quality mitigations (in AudioMixer.swift):**
- 8192-sample buffers (~170ms) for timestamp jitter
- 200ms startup buffering before mixing begins
- 64-sample crossfade at buffer boundaries
- Stereo output: Left channel = mic, Right channel = system (enables speaker diarization)
- Soft limiter per channel (-6dB threshold, 8:1 ratio) prevents clipping
- Unity gain on both sources; limiter handles levels

## Module Responsibilities

| Module | Purpose |
|--------|---------|
| `/App/AppState.swift` | State machine, recording orchestration, audio levels |
| `/App/DebugLog.swift` | `debugLog()` function, conditional on build config |
| `/Audio/SystemAudioCapture.swift` | Core Audio Taps + mic via AVAudioEngine |
| `/Audio/AudioMixer.swift` | Real-time stereo mixing, RMS level monitoring (~15Hz) |
| `/Views/MainAppWindow.swift` | Main app window with recording controls |
| `/Views/MeetingPromptPanel.swift` | NSPanel floating prompt for meeting detection |
| `/Views/RecordingIndicatorWindow.swift` | NSPanel mini-window, hidden from screen share |
| `/Views/NotificationNubPanel.swift` | Custom floating notification panels |
| `/Views/AudioLevelView.swift` | SwiftUI VU meter bars |
| `/Services/MeetingDetectionService.swift` | Mic activity → prompt, UserDefaults persistence |
| `/Services/MicActivityMonitor.swift` | Detects when any app uses microphone |
| `/Services/CalendarService.swift` | EventKit integration for meeting names |
| `/Services/CalendarAutoStartService.swift` | Pre-meeting notifications with join & record |
| `/Processing/ProcessRunner.swift` | Async subprocess utility with timeout |
| `/Processing/TranscriptionService.swift` | whisper.cpp wrapper |
| `/Processing/SummarizationService.swift` | Claude CLI wrapper (non-fatal on failure) |

## Code Style

**Prefer modern macOS paradigms:**
- SwiftUI over AppKit for all UI (menus, windows, views)
- Use `MenuBarExtra` for menubar, not `NSStatusItem`
- async/await over callbacks/delegates
- Combine for reactive state (`@Published`, `@ObservedObject`)
- Only use AppKit when SwiftUI lacks capability (e.g., Core Audio, low-level system APIs)

**NSPanel usage (for floating windows):**
- `MeetingPromptPanel` and `RecordingIndicatorWindow` use NSPanel with NSHostingView for SwiftUI content
- `.nonactivatingPanel` style — doesn't steal focus from other apps
- `.floating` level — stays above normal windows
- `sharingType = .none` on recording indicator — hidden from screen share

## Debug Logging

Use `debugLog("message")` instead of `print("Munin: message")` for debug output.

- **Debug builds:** Always enabled
- **Release builds:** Disabled by default, enable via `defaults write com.munin.app MuninDebug -bool true`

Keep error-level prints (e.g., `print("Transcription error: \(error)")`) as raw `print()` statements — these should always appear.
