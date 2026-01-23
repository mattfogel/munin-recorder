# Munin - Project Specification

A local macOS menubar app that records meeting audio, transcribes locally using Whisper, and summarizes using Claude API. Essentially a privacy-focused, local-first clone of Granola.

---

## Project Goals

1. **Record any audio on the Mac** - system audio (other participants) + microphone (user's voice)
2. **Transcribe locally** - using whisper.cpp for complete privacy
3. **Summarize via Claude Code CLI** - Claude Code CLI for high-quality meeting summaries
4. **Simple UX** - menubar app with manual start/stop, plus smart auto-detection
5. **Organized storage** - local markdown files in a predictable folder structure

---

## Target Environment

- **OS**: macOS 12.3+ (required for ScreenCaptureKit)
- **Hardware**: MacBook Pro M1 Pro, 16GB RAM
- **User**: Technical user comfortable with granting permissions

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Swift Menubar App                         │
├──────────┬──────────┬──────────┬──────────┬────────────────┤
│  Manual  │  App     │ Calendar │  Status  │  Recording     │
│  Toggle  │ Detector │  Monitor │ Display  │  Manager       │
└────┬─────┴────┬─────┴────┬─────┴──────────┴───────┬────────┘
     │          │          │                        │
     │          │          ▼                        ▼
     │          │    ┌──────────┐           ┌──────────────┐
     │          │    │ EventKit │           │ScreenCapture │
     │          │    │ (Calendar│           │    Kit       │
     │          │    │  Access) │           │ (Audio)      │
     │          │    └──────────┘           └──────┬───────┘
     │          ▼                                  │
     │   ┌─────────────┐                          ▼
     │   │ NSWorkspace │                   ┌──────────────┐
     │   │ (App Launch │                   │  Audio File  │
     │   │  Detection) │                   │   (.m4a)     │
     │   └─────────────┘                   └──────┬───────┘
     │                                            │
     └─────────────► Post-Call Pipeline ◄─────────┘
                            │
              ┌─────────────┼─────────────┐
              ▼             ▼             ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │whisper.cpp│  │ Claude   │  │  File    │
        │(Transcribe)│  │  Code    │  │ Storage  │
        └─────┬─────┘  │  (CLI)   │  └────┬─────┘
              │        └─────┬─────┘       │
              ▼              ▼             ▼
        transcript.md   summary.md    ~/Meetings/
```

---

## Tech Stack

| Component | Technology | Notes |
|-----------|------------|-------|
| UI | Swift + AppKit | Menubar-only app (LSUIElement = true) |
| Audio Capture | ScreenCaptureKit | Captures system audio without virtual devices |
| Microphone | AVFoundation | Standard mic capture |
| Audio Mixing | AVFoundation | Mix system + mic into single stream |
| Calendar | EventKit | Access local Calendar.app (syncs with Google/Outlook) |
| App Detection | NSWorkspace | didLaunchApplicationNotification |
| Transcription | whisper.cpp | CLI invocation or Swift bindings |
| Summarization | Claude Code CLI | `claude` command with prompt piped in |
| Storage | FileManager | Local filesystem, markdown files |

---

## Permissions Required

The app needs these entitlements and runtime permissions:

### Entitlements (in .entitlements file)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
```

Note: For personal use, we can run without sandboxing to simplify file access and whisper.cpp invocation. For distribution, would need proper sandboxing with temporary exceptions.

### Info.plist Keys
```xml
<key>NSMicrophoneUsageDescription</key>
<string>MeetingRecorder needs microphone access to record your voice during meetings.</string>

<key>NSCalendarsUsageDescription</key>
<string>MeetingRecorder uses your calendar to automatically name recordings and detect upcoming meetings.</string>

<!-- For ScreenCaptureKit - triggers Screen Recording permission -->
<key>NSScreenCaptureUsageDescription</key>
<string>MeetingRecorder needs screen recording permission to capture meeting audio from other participants.</string>

<!-- Menubar-only app -->
<key>LSUIElement</key>
<true/>
```

### Runtime Permission Flow
1. On first launch, prompt for Screen Recording permission (required for ScreenCaptureKit)
2. On first recording, prompt for Microphone permission
3. On first calendar access, prompt for Calendar permission

---

## File Structure

### App Output Structure
```
~/Meetings/
├── 2025-01-22/
│   ├── standup-with-engineering/
│   │   ├── audio.m4a
│   │   ├── transcript.md
│   │   └── summary.md
│   └── 1430-unknown-meeting/
│       ├── audio.m4a
│       ├── transcript.md
│       └── summary.md
└── 2025-01-23/
    └── client-call-acme-corp/
        ├── audio.m4a
        ├── transcript.md
        └── summary.md
```

### Folder Naming Logic (in priority order)
1. **Calendar event title** - sanitized (lowercase, hyphens, no special chars)
2. **Manual input** - user types name when stopping recording
3. **Timestamp fallback** - `HHMM-unknown-meeting` format

### File Formats

**audio.m4a**
- AAC encoded, 44.1kHz or 48kHz
- Mono is fine for transcription (smaller files)
- Keep original for archival

**transcript.md**
```markdown
# Meeting Transcript
**Date**: 2025-01-22
**Duration**: 45 minutes
**Participants**: (if detectable from audio)

---

[00:00] Speaker 1: Hello everyone, let's get started...

[00:15] Speaker 2: Thanks for joining. First item on the agenda...

...
```

**summary.md**
```markdown
# Meeting Summary
**Date**: 2025-01-22
**Meeting**: Standup with Engineering
**Duration**: 45 minutes

## Key Points
- ...

## Action Items
- [ ] @person - Task description (due date if mentioned)

## Decisions Made
- ...

## Follow-ups Needed
- ...
```

---

## Component Details

### 1. Menubar UI

**States:**
- Idle (gray icon)
- Recording (red icon, possibly pulsing)
- Processing (yellow/orange icon)

**Menu Items:**
- Status text ("Recording: 12:34" or "Idle")
- "Start Recording" / "Stop Recording" (toggle)
- "---" separator
- "Open Meetings Folder"
- "Preferences..." (future: configure storage location, whisper model, etc.)
- "---" separator
- "Quit"

**Keyboard Shortcut:**
- Global hotkey to toggle recording (e.g., Cmd+Shift+R) - optional but nice to have

### 2. Audio Capture (ScreenCaptureKit)

**Key Classes:**
- `SCShareableContent` - enumerate available audio sources
- `SCStreamConfiguration` - configure capture settings
- `SCStream` - the actual capture stream
- `SCStreamOutput` - delegate to receive audio buffers

**Implementation Notes:**
```swift
// Basic flow:
// 1. Get shareable content
let content = try await SCShareableContent.current

// 2. Create a stream configuration for audio only
let config = SCStreamConfiguration()
config.capturesAudio = true
config.excludesCurrentProcessAudio = false // Include all audio
config.sampleRate = 48000
config.channelCount = 1 // Mono for transcription

// 3. Create filter (capture entire display's audio)
let display = content.displays.first!
let filter = SCContentFilter(display: display, excludingWindows: [])

// 4. Create and start stream
let stream = SCStream(filter: filter, configuration: config, delegate: self)
try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
try await stream.startCapture()
```

**Microphone Capture:**
- Use AVAudioEngine or AVCaptureSession in parallel
- Mix with system audio before saving, or save as separate tracks and merge

**Audio File Writing:**
- Use AVAssetWriter to write AAC-encoded .m4a
- Buffer audio samples and write continuously during recording

### 3. Transcription (whisper.cpp)

**Installation:**
```bash
# Clone and build whisper.cpp
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp
make

# Download model (recommend medium for quality/speed balance on M1)
./models/download-ggml-model.sh medium

# Or for faster processing, use small or base
./models/download-ggml-model.sh small
```

**Invocation from Swift:**
```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/path/to/whisper.cpp/main")
process.arguments = [
    "-m", "/path/to/whisper.cpp/models/ggml-medium.bin",
    "-f", audioFilePath,
    "-of", outputPath,  // Output file prefix
    "-otxt",            // Output as text
    "--print-progress",
    "-l", "en"          // Language hint
]

let pipe = Pipe()
process.standardOutput = pipe
process.standardError = pipe

try process.run()
process.waitUntilExit()
```

**Model Recommendations for M1 Pro 16GB:**
- `small` - Fast (~10x realtime), decent quality
- `medium` - Good balance (~5x realtime), recommended
- `large-v3` - Best quality (~2x realtime), may be slow for long meetings

**Output Parsing:**
whisper.cpp can output in multiple formats. We want timestamps for the transcript:
```bash
./main -m models/ggml-medium.bin -f audio.wav --output-txt --output-vtt
```

### 4. Summarization (Claude Code CLI)

**Prerequisites:**
- Claude Code installed (`npm install -g @anthropic-ai/claude-code` or via Anthropic's install script)
- User has authenticated Claude Code (runs `claude` and completes auth flow once)

**Invocation from Swift:**
```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")  // or wherever claude is installed

// Pass the prompt via stdin with the transcript
let prompt = """
Please summarize this meeting transcript. Include:
1. Key points discussed
2. Action items with owners if mentioned  
3. Decisions made
4. Follow-ups needed

Format the output as markdown with clear sections.

<transcript>
\(transcriptContent)
</transcript>
"""

process.arguments = [
    "--print",           // Output response to stdout (no interactive mode)
    "--output-format", "text",  // Plain text output
    "-p", prompt         // Pass prompt directly
]

let outputPipe = Pipe()
process.standardOutput = outputPipe
process.standardError = Pipe()

try process.run()
process.waitUntilExit()

let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
let summary = String(data: outputData, encoding: .utf8) ?? ""
```

**Alternative: Pipe transcript via stdin:**
```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
process.arguments = [
    "--print",
    "--output-format", "text",
    "-p", "Summarize this meeting transcript with key points, action items, decisions, and follow-ups. Format as markdown."
]

let inputPipe = Pipe()
let outputPipe = Pipe()
process.standardInput = inputPipe
process.standardOutput = outputPipe

try process.run()

// Write transcript to stdin
inputPipe.fileHandleForWriting.write(transcriptContent.data(using: .utf8)!)
inputPipe.fileHandleForWriting.closeFile()

process.waitUntilExit()
```

**Finding Claude Code Binary:**
```swift
// Claude Code could be in various locations depending on install method
let possiblePaths = [
    "/usr/local/bin/claude",
    "/opt/homebrew/bin/claude",
    "\(NSHomeDirectory())/.local/bin/claude",
    "\(NSHomeDirectory())/.npm-global/bin/claude"
]

func findClaudeBinary() -> String? {
    for path in possiblePaths {
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }
    // Try `which claude` as fallback
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    which.arguments = ["claude"]
    let pipe = Pipe()
    which.standardOutput = pipe
    try? which.run()
    which.waitUntilExit()
    let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return path?.isEmpty == false ? path : nil
}
```

**Error Handling:**
- Check if `claude` binary exists before attempting summarization
- Handle case where user hasn't authenticated (Claude Code will prompt, but non-interactive mode may fail)
- Timeout for very long transcripts (Claude Code should handle this, but set reasonable limit)
- Parse exit code: 0 = success, non-zero = error

**First-Run Setup:**
If Claude Code isn't found or isn't authenticated, show user instructions:
```
Claude Code is required for meeting summaries.

1. Install: npm install -g @anthropic-ai/claude-code
   Or visit: https://docs.anthropic.com/claude-code

2. Authenticate: Run 'claude' in Terminal and complete the login flow

3. Restart MeetingRecorder
```

### 5. Calendar Integration (EventKit)

**Access:**
```swift
import EventKit

let eventStore = EKEventStore()

// Request access
eventStore.requestAccess(to: .event) { granted, error in
    if granted {
        // Can now query calendars
    }
}
```

**Finding Current/Upcoming Meetings:**
```swift
// Get events in the next hour
let calendars = eventStore.calendars(for: .event)
let now = Date()
let oneHourFromNow = now.addingTimeInterval(3600)

let predicate = eventStore.predicateForEvents(
    withStart: now,
    end: oneHourFromNow,
    calendars: calendars
)

let events = eventStore.events(matching: predicate)

// Filter to likely meetings (has video link, or multiple attendees, etc.)
let meetings = events.filter { event in
    event.hasAttendees || 
    event.notes?.contains("zoom.us") ?? false ||
    event.notes?.contains("meet.google.com") ?? false ||
    event.url?.absoluteString.contains("zoom") ?? false
}
```

### 6. App Detection (NSWorkspace)

**Monitored Apps:**
```swift
let meetingApps = [
    "us.zoom.xos",           // Zoom
    "com.google.Chrome",     // Meet (browser)
    "com.apple.Safari",      // Meet (browser)
    "com.microsoft.teams",   // Teams
    "com.microsoft.teams2",  // Teams (new version)
    "com.webex.meetingmanager", // Webex
    "com.slack.Slack"        // Slack huddles
]
```

**Notification Observer:**
```swift
NSWorkspace.shared.notificationCenter.addObserver(
    self,
    selector: #selector(appDidLaunch(_:)),
    name: NSWorkspace.didLaunchApplicationNotification,
    object: nil
)

@objc func appDidLaunch(_ notification: Notification) {
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          let bundleID = app.bundleIdentifier else { return }
    
    if meetingApps.contains(bundleID) {
        // Prompt user: "Zoom launched. Start recording?"
    }
}
```

---

## Build Phases

### Phase 1: Menubar Shell + Manual Recording
**Goal:** Click to start/stop, saves audio file to ~/Meetings

- [ ] Create new Xcode project (macOS App, Swift, AppKit)
- [ ] Configure as menubar-only app (LSUIElement)
- [ ] Implement basic menubar with icon and menu
- [ ] Request Screen Recording permission on launch
- [ ] Implement ScreenCaptureKit audio capture
- [ ] Implement microphone capture with AVAudioEngine
- [ ] Mix both audio streams
- [ ] Write to .m4a file using AVAssetWriter
- [ ] Create folder structure on stop
- [ ] Basic error handling and status display

**Deliverable:** Can manually record a meeting, audio saves to ~/Meetings/DATE/TIMESTAMP/audio.m4a

### Phase 2: Transcription Pipeline
**Goal:** After recording stops, transcribe with whisper.cpp

- [ ] Bundle or locate whisper.cpp binary
- [ ] Download/bundle appropriate model
- [ ] Run whisper.cpp as subprocess after recording
- [ ] Parse output and format as transcript.md
- [ ] Show "Processing..." status in menubar
- [ ] Handle errors (whisper not found, model missing, etc.)

**Deliverable:** Recording automatically transcribes, transcript.md appears alongside audio.m4a

### Phase 3: Summarization
**Goal:** Call Claude Code CLI to generate summary

- [ ] Detect Claude Code binary location
- [ ] Check if user has authenticated Claude Code
- [ ] Invoke `claude` with transcript via subprocess
- [ ] Parse output and save as summary.md
- [ ] Handle errors (claude not found, not authenticated, etc.)
- [ ] Show setup instructions if Claude Code missing
- [ ] Optional: Show notification when summary ready

**Deliverable:** Full pipeline works - record → transcribe → summarize, all files in folder

### Phase 4: Calendar Integration
**Goal:** Auto-name folders from calendar events

- [ ] Request Calendar permission
- [ ] Query EventKit for current/recent events
- [ ] Match recording time to calendar event
- [ ] Use event title for folder naming
- [ ] Fallback logic (manual input → timestamp)
- [ ] Optional: Show upcoming meetings in menu

**Deliverable:** Folders named after calendar events when available

### Phase 5: App Detection
**Goal:** Prompt to record when meeting app launches

- [ ] Monitor NSWorkspace for app launches
- [ ] Detect meeting apps (Zoom, Teams, browser for Meet)
- [ ] Show notification/prompt asking to start recording
- [ ] Quick-start from notification
- [ ] Preference to enable/disable per app

**Deliverable:** "Zoom launched. Start recording?" prompt appears

### Phase 6: Calendar Auto-Start
**Goal:** Begin recording automatically before scheduled meetings

- [ ] Background timer checking upcoming events
- [ ] Configurable lead time (e.g., 2 minutes before)
- [ ] Auto-start recording with event name
- [ ] Notification that recording started
- [ ] Preference to enable/disable

**Deliverable:** Recording starts automatically for calendar meetings

---

## Configuration (Future)

For Phase 1-3, hardcode sensible defaults. Later, add Preferences window:

```swift
struct AppSettings {
    var meetingsFolder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meetings")
    var whisperModelPath: String = "~/.meetingrecorder/models/ggml-medium.bin"
    var whisperBinaryPath: String = "~/.meetingrecorder/bin/whisper"
    var claudeCodePath: String? = nil  // Auto-detected, but can override
    var autoDetectApps: Bool = true
    var autoStartFromCalendar: Bool = false
    var calendarLeadTimeMinutes: Int = 2
    var audioQuality: AudioQuality = .medium // .low, .medium, .high
}
```

---

## Error Handling

| Scenario | Handling |
|----------|----------|
| Screen Recording permission denied | Show alert with instructions to enable in System Preferences |
| Microphone permission denied | Show alert, offer to continue with system audio only |
| No audio devices available | Show error, disable recording |
| Whisper binary not found | Show setup instructions |
| Whisper model not found | Offer to download, show progress |
| Claude Code not installed | Show install instructions, skip summarization |
| Claude Code not authenticated | Show auth instructions, skip summarization |
| Claude Code timeout | Retry once, then save transcript without summary |
| Disk full | Alert user, stop recording gracefully |
| Recording interrupted | Save what we have, mark as incomplete |

---

## Testing Checklist

### Audio Capture
- [ ] Records system audio (play YouTube video during test)
- [ ] Records microphone input
- [ ] Both sources audible in output file
- [ ] Audio quality acceptable
- [ ] Long recording (1+ hour) works without issues
- [ ] Recording survives sleep/wake

### Transcription
- [ ] Whisper processes audio successfully
- [ ] Timestamps present and accurate
- [ ] Multiple speakers somewhat distinguishable
- [ ] Non-English handled (if configured)
- [ ] Large files don't crash

### Summarization
- [ ] Claude Code binary detected correctly
- [ ] Invocation succeeds with valid transcript
- [ ] Summary quality is useful
- [ ] Action items extracted
- [ ] Long transcripts handled
- [ ] Graceful failure if Claude Code not installed/authenticated

### Calendar
- [ ] Events from all synced calendars visible
- [ ] Correct event matched to recording time
- [ ] Special characters in event titles handled

### UX
- [ ] Menubar icon visible and clear
- [ ] Status updates correctly
- [ ] Notifications appear when appropriate
- [ ] No memory leaks over long usage

---

## Dependencies

### Required
- macOS 12.3+ (for ScreenCaptureKit)
- Xcode 14+ (for Swift 5.7+)

### External
- whisper.cpp (build from source or download release)
- Whisper model file (download separately)
- Claude Code CLI (user installs and authenticates separately)

### No External Swift Packages Required
Keep dependencies minimal. Use built-in frameworks:
- ScreenCaptureKit
- AVFoundation
- EventKit
- AppKit

---

## Security Notes

1. **Claude Code Auth** - Handled by Claude Code itself, no credentials stored in this app
2. **Audio Files** - Stored only locally, never uploaded
3. **Transcript Privacy** - Warn user that transcripts are sent to Claude via Claude Code
4. **No Analytics** - App should not phone home or collect any usage data
5. **Code Signing** - Ad-hoc signing fine for personal use; proper signing needed for distribution

---

## Future Enhancements (Out of Scope for MVP)

- Speaker diarization (who said what)
- Search across all transcripts
- Export to Notion/Obsidian
- Meeting analytics (talk time, etc.)
- Real-time transcription display
- Integration with meeting platforms (auto-join detection)
- iOS companion app
- Encrypted storage option
