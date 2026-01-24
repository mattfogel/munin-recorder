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

**Permissions needed:** Screen Recording, Microphone (granted on first run)

## Architecture

```
User triggers recording
    ↓
AppState (state machine: idle → recording → processing)
    ↓
AudioCaptureCoordinator
  ├─ SystemAudioCapture (Core Audio Taps + AVAudioEngine)
  ├─ AudioMixer (real-time mixing via Accelerate/vDSP)
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
- All internal: 48kHz mono float32 PCM
- Whisper input: 16kHz 16-bit PCM WAV (converted via afconvert)
- File output: AAC m4a, 48kHz mono, 128kbps

**Threading:**
- `@MainActor` on AppState, AppDelegate for UI/state
- `@unchecked Sendable` on audio classes with dedicated dispatch queues
- Async/await throughout capture and processing

**Audio quality mitigations (in AudioMixer.swift):**
- 8192-sample buffers (~170ms) for timestamp jitter
- 200ms startup buffering before mixing begins
- 64-sample crossfade at buffer boundaries
- System audio gain 0.65, mic gain 1.0

## Module Responsibilities

| Module | Purpose |
|--------|---------|
| `/App/AppState.swift` | State machine, recording orchestration |
| `/Audio/SystemAudioCapture.swift` | Core Audio Taps + mic via AVAudioEngine (~580 lines) |
| `/Audio/AudioMixer.swift` | Real-time sample mixing, Accelerate-based |
| `/Processing/ProcessRunner.swift` | Async subprocess utility with timeout |
| `/Processing/TranscriptionService.swift` | whisper.cpp wrapper |
| `/Processing/SummarizationService.swift` | Claude CLI wrapper (non-fatal on failure) |
