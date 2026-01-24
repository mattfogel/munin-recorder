# Munin

A privacy-focused macOS meeting recorder. Records system audio + microphone, transcribes locally with whisper.cpp, and summarizes via Claude CLI.

## Current Status

**Working:** Window UI, audio capture (system + mic), file output, transcription pipeline, summarization pipeline, menubar icon (with proper signing).

**Known Issues:**
- No app icon yet

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
                            │  AVAssetWriter        │
                            │  → audio.m4a          │
                            └───────────┬───────────┘
                                        │
              ┌─────────────────────────┼─────────────────────────┐
              │                         │                         │
              ▼                         ▼                         ▼
        whisper.cpp              Claude CLI              ~/Meetings/
        → transcript.md          → summary.md            DATE/TIME/
```

## Requirements

- macOS 15+ (Core Audio Taps)
- Xcode 16+
- whisper.cpp with model
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

### 3. Install whisper.cpp

```bash
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp && make
./models/download-ggml-model.sh base.en
mkdir -p ~/.munin/models
cp models/ggml-base.en.bin ~/.munin/models/
```

### 4. Install Claude CLI

```bash
npm install -g @anthropic-ai/claude-code
claude  # authenticate once
```

### 5. Grant permissions

On first run, grant:
- Screen Recording (System Settings → Privacy & Security)
- Microphone access
- Calendar access (optional, for auto-naming recordings)
- Notifications (for completion alerts)

## Usage

1. Run app (Cmd+R in Xcode)
2. Click "Start Recording"
3. Have your meeting
4. Click "Stop Recording"
5. Wait for processing (Saving → Transcribing → Summarizing)
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
│   ├── MuninApp.swift           # @main entry
│   ├── AppDelegate.swift        # Permission checks
│   └── AppState.swift           # Recording state machine
├── Audio/
│   ├── AudioCaptureCoordinator.swift
│   ├── SystemAudioCapture.swift # Core Audio Taps
│   └── AudioFileWriter.swift    # AVAssetWriter
├── Processing/
│   ├── ProcessRunner.swift      # Async subprocess wrapper
│   ├── TranscriptionService.swift
│   └── SummarizationService.swift
├── Storage/
│   ├── MeetingStorage.swift
│   └── MeetingRecord.swift
└── Permissions/
    ├── PermissionChecker.swift
    └── PermissionPrompts.swift
```

## Roadmap


### Phase 5: App Detection
**Goal:** Prompt to record when meeting starts in a meeting app

- [x] Detect meeting has started (e.g. in Zoom, Teams, browser for Meet or browser-based Teams meeting) - investigate if/how we could detect that a meeting has started in one of these apps?
- [x] Show notification/prompt asking to start recording
- [x] Quick-start from notification
- [ ] Custom notification pop-up for better UX
- [ ] Preference to enable/disable per app

### Phase 6: Calendar Auto-Start
**Goal:** Begin recording automatically before scheduled meetings

- [ ] Background timer checking upcoming events
- [ ] Configurable lead time (e.g., 2 minutes before)
- [ ] Notification offering to Start recording with event name
- [ ] Notification that recording started
- [ ] Preference to enable/disable

### Future Enhancements
- Preferences window (storage location, whisper model, etc.)
- Speaker diarization (who said what) - step one, "Me" (for mic input) and "Them" for system audio
- Search across all transcripts
- Global hotkey (Cmd+Shift+R)
- Real-time transcription display



## Troubleshooting

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
Converts m4a → wav via `afconvert`, then runs whisper.cpp with `--output-txt --output-vtt`.

### Summarization
Invokes `claude --print -p "..." < transcript.md` and captures stdout.
