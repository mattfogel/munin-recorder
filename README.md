# Munin

A macOS meeting recorder that keeps your data local and AI-accessible.

**Why Munin?** Meeting transcription services lock your notes in walled gardens where they can't be queried by your own tools. Munin stores everything locally as plain markdown files, making your meeting history available to Claude Code, local search, and any other AI agent you choose to use.

Records system audio + microphone, transcribes in real time using Apple's native speech recognition, and summarizes via Claude CLI. Your meetings, your files, your control.

## Current Status

**Working:**
- Window UI and menubar with custom raven icon
- Audio capture (system + mic) with real-time level monitoring
- Recording indicator mini-window (hidden from screen share)
- Auto-detect meetings via mic activity with floating prompt
- Calendar auto-start: notifies before scheduled meetings with option to join & record
- Custom floating notification panels (not system notifications)
- Streaming transcription via Apple SpeechAnalyzer (live during recording, speaker diarization)
- Summarization via Claude CLI
- Calendar integration for meeting names and participants

## Architecture

```
┌─────────────────────────────────────────────────────┐
│              Swift Menubar/Window App               │
├─────────────┬─────────────┬────────────────────────┤
│  Toggle     │  Status     │  Recording Manager     │
│  Button     │  Display    │  (AudioCaptureCoord.)  │
└─────────────┴─────────────┴───────────┬────────────┘
                                        │
                            ┌───────────┴───────────┐
                            │  Core Audio Taps      │
                            │  (System + Mic)       │
                            └───────────┬───────────┘
                                        │
                            ┌───────────▼───────────┐
                            │  AudioMixer           │
                            │  (stereo mix + levels) │
                            └──┬────────────────┬───┘
                               │                │
                ┌──────────────▼──┐    ┌───────▼───────────┐
                │  AVAssetWriter  │    │  SpeechAnalyzer    │
                │  → audio.m4a   │    │  (mic + system)    │
                └──────────┬─────┘    │  → transcript.md   │
                           │          └───────┬────────────┘
              ┌────────────┼──────────────────┼──────────────┐
              │            │                  │              │
              ▼            ▼                  ▼              ▼
        ~/Meetings/   Claude CLI        Live diarized   Speaker labels
        DATE/TIME/    → summary.md      transcription   (Me / Them)
```

## Requirements

- macOS 26+ (SpeechAnalyzer APIs + Core Audio Taps)
- Xcode 16+
- Claude CLI (authenticated)

## Setup

### 1. Clone and open

```bash
git clone <repo>
cd munin
open Munin/Munin.xcodeproj
```

### 2. Code signing

**Important:** Use a real Apple Developer identity (free account works).
- Xcode → Signing & Capabilities → set Team → enable "Automatically manage signing"
- Ad-hoc signing breaks menubar icon and causes permission loops.

### 3. Install Claude CLI

```bash
npm install -g @anthropic-ai/claude-code
claude  # authenticate once
```

### 4. Grant permissions

On first run, grant:
- Screen Recording (System Settings → Privacy & Security)
- Microphone access
- Speech Recognition (for live transcription)
- Calendar access (optional, for auto-naming recordings)
- Notifications (for completion alerts)

The speech recognition model for your locale will be downloaded automatically on first recording.

## Usage

1. Run app (Cmd+R in Xcode)
2. Click "Start Recording"
3. Have your meeting
4. Click "Stop Recording"
5. Wait for processing (Saving → Finalizing transcription → Summarizing)
6. Files saved to `~/Meetings/DATE/TIME-name/`

## Output Files

```
~/Meetings/
└── 2025-01-23/
    └── 1430-unknown-meeting/
        ├── audio.m4a      # AAC, 48kHz, stereo (L=mic, R=system)
        ├── transcript.md  # Timestamped transcript
        └── summary.md     # Key points, action items
```

## Project Structure

```
Munin/
├── App/
│   ├── MuninApp.swift           # @main entry, MenuBarExtra
│   ├── AppDelegate.swift        # Permission checks, app lifecycle
│   ├── AppState.swift           # Recording state machine
│   └── DebugLog.swift           # Conditional debug logging
├── Views/
│   ├── MainAppWindow.swift          # Main app window UI
│   ├── MeetingPromptPanel.swift     # Floating meeting detection prompt
│   ├── RecordingIndicatorWindow.swift # Mini recording status window
│   ├── NotificationNubPanel.swift   # Custom floating notifications
│   ├── AudioLevelView.swift         # VU meter bars
│   └── MuninIcon.swift              # Raven icon rendering
├── Audio/
│   ├── AudioCaptureCoordinator.swift
│   ├── SystemAudioCapture.swift # Core Audio Taps
│   ├── AudioMixer.swift         # Real-time mixing + level monitoring
│   └── AudioFileWriter.swift    # AVAssetWriter
├── Services/
│   ├── MeetingDetectionService.swift  # Mic activity monitoring
│   ├── MicActivityMonitor.swift       # Low-level mic detection
│   ├── CalendarService.swift          # EventKit integration
│   └── CalendarAutoStartService.swift # Pre-meeting notifications
├── Processing/
│   ├── ProcessRunner.swift                # Async subprocess wrapper
│   ├── StreamingTranscriptionService.swift # SpeechAnalyzer streaming engine
│   └── SummarizationService.swift
├── Storage/
│   ├── MeetingStorage.swift
│   └── MeetingRecord.swift
└── Permissions/
    ├── PermissionChecker.swift
    └── PermissionPrompts.swift
```

## Roadmap

### Future Enhancements
- Smart meeting detection (Accessibility APIs to detect Zoom's "Meeting" menu, Teams windows)
- Auto-stop recording when meeting ends
- Add CLI args to simplify Claude Code calls? (e.g. if it's possible to not load plugins/mcps, not store history, etc)
- Note-taking window when a meeting starts, let me change meeting name and take my own notes which will be combined with the meeting summary
- Preferences window (storage location, etc.)
- Global hotkey (Cmd+Shift+R)
- Real-time transcription display in UI
- Settings toggle for transcription on/off



## Troubleshooting

### Debug Logging

Debug logs are **always enabled** in Debug builds (Cmd+R in Xcode).

In Release builds, logs are disabled by default. Enable them with:
```bash
defaults write com.munin.app MuninDebug -bool true
```

Disable with:
```bash
defaults delete com.munin.app MuninDebug
```

### Menubar icon not appearing
Use proper code signing, not "Sign to Run Locally".

### Permission keeps resetting
Same fix—proper code signing makes TCC recognize the app consistently.

### Only system audio OR only mic
Check console for sample counts. Both should show increasing numbers:
```
Munin: System audio samples received: 101
Munin: Microphone samples received: 101
```

### Audio quality issues
Stereo output (mic on left, system on right) with per-channel soft limiting. If issues persist, check console for sample counts matching between sources.

## Technical Notes

### Audio Capture
Uses Core Audio Taps for system audio capture. Microphone captured via AVAudioEngine. Output is stereo (mic=left, system=right) for speaker diarization, with soft limiting to prevent clipping.

### Transcription
Uses Apple's native `SpeechAnalyzer` + `SpeechTranscriber` APIs (macOS 26) for streaming transcription during recording. Two independent transcriber instances run in parallel — one for microphone ("Me") and one for system audio ("Them") — providing automatic speaker diarization.

Audio is converted from 48kHz float32 to 16kHz Int16 via `AVAudioConverter` before feeding to the analyzers. The speech model is downloaded automatically on first use via `AssetInventory`.

### Summarization
Invokes `claude --print -p "..." < transcript.md` and captures stdout.
