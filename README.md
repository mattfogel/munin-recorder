# Munin

A macOS meeting recorder that keeps your data local and AI-accessible.

**Why Munin?** Meeting transcription services lock your notes in walled gardens where they can't be queried by your own tools. Munin stores everything locally as plain markdown files, making your meeting history available to Claude Code, local search, and any other AI agent you choose to use.

Records system audio + microphone, transcribes locally with whisper.cpp, and summarizes via Claude CLI. Your meetings, your files, your control.

## Current Status

**Working:**
- Window UI and menubar with custom raven icon
- Audio capture (system + mic) with real-time level monitoring
- Recording indicator mini-window (hidden from screen share)
- Auto-detect meetings via mic activity with floating prompt
- Transcription via whisper.cpp
- Summarization via Claude CLI
- Calendar integration for meeting names

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

### 3b. (Optional but recommended) Install VAD model

For better segmentation across silence, install the Silero VAD model:

```bash
mkdir -p ~/.munin/models
cp path/to/ggml-silero-v6.2.0.bin ~/.munin/models/
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
│   ├── MuninApp.swift           # @main entry, MenuBarExtra
│   ├── AppDelegate.swift        # Permission checks, app lifecycle
│   └── AppState.swift           # Recording state machine
├── Views/
│   ├── MeetingPromptPanel.swift     # Floating meeting detection prompt
│   ├── RecordingIndicatorWindow.swift # Mini recording status window
│   └── AudioLevelView.swift         # VU meter bars
├── Audio/
│   ├── AudioCaptureCoordinator.swift
│   ├── SystemAudioCapture.swift # Core Audio Taps
│   ├── AudioMixer.swift         # Real-time mixing + level monitoring
│   └── AudioFileWriter.swift    # AVAssetWriter
├── Services/
│   ├── MeetingDetectionService.swift # Mic activity monitoring
│   ├── MicActivityMonitor.swift      # Low-level mic detection
│   └── CalendarService.swift         # EventKit integration
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

### Phase 7: Calendar Auto-Start
**Goal:** Offer to begin recording automatically before scheduled meetings

- [ ] Background timer checking upcoming events
- [ ] Configurable lead time (e.g., 2 minutes before)
- [ ] Notification offering to Start event and recording (use the event link in the invite to start the event!)
- [ ] Notification that recording started
- [ ] Preference to enable/disable

### Future Enhancements
- Add CLI args to simplify Claude Code calls? (e.g. if it's possible to not load plugins/mcps, not store history, etc)
- Note-taking window when a meeting starts, let me change meeting name and take my own notes which will be combined with the meeting summary
- Preferences window (storage location, whisper model, etc.)
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
Converts m4a → wav via `afconvert`, then runs whisper.cpp with VTT + JSON + word timings.
Word-level timings are re-segmented in-app to avoid long cues spanning silence.
If `~/.munin/models/ggml-silero-v6.2.0.bin` exists, VAD is enabled to split on silence.

**Tuning knobs (transcription):**
- `--max-len`: lower for shorter segments, higher for fewer splits.
- VAD: `--vad-min-silence-duration-ms`, `--vad-max-speech-duration-s`, `--vad-threshold`, `--vad-speech-pad-ms`.
- Word segmentation in `TranscriptionService`: `wordGapMs`, `punctuationGapMs`, `maxSegmentChars`.

**Troubleshooting (transcription timing/segmentation):**
- Lines appear too early: reduce `--max-len`, lower `--vad-max-speech-duration-s`, or reduce `wordGapMs`.
- Over-splitting/fragmented lines: increase `--max-len`, raise `--vad-min-silence-duration-ms`, or increase `wordGapMs`.
- Missing quiet speech: lower `--vad-threshold` or increase `--vad-speech-pad-ms`.

### Summarization
Invokes `claude --print -p "..." < transcript.md` and captures stdout.
