# Meeting Recorder - SwiftUI macOS App

## Overview
A native macOS SwiftUI app that records meetings (screen + audio), transcribes them with whisper, and generates AI meeting notes with Claude.

## Architecture

### Audio Capture (BlackHole)
- **System audio:** Record from "BlackHole 2ch" AVFoundation device — captures everything the user hears (other meeting participants, shared audio, etc.)
- **Microphone:** Record from user's mic (AirPods, MacBook Microphone, etc.) — captures the user's voice
- **Both streams are mixed** into a single recording
- **Requires:** BlackHole 2ch installed (`brew install blackhole-2ch` or pkg from https://existential.audio/blackhole)
- **Requires:** Multi-Output Device configured in Audio MIDI Setup (AirPods + BlackHole 2ch) set as system output — so user hears audio AND BlackHole captures it

### Screen Capture
- Use ScreenCaptureKit (macOS 12.3+) or AVFoundation for screen recording
- Support multi-monitor — detect which screen has the meeting app
- Meeting app detection: look for running processes named "MSTeams", "Microsoft Teams", "zoom.us", "Google Chrome" (with meet.google.com), "Slack", "Webex", "FaceTime"

### Transcription
- Use whisper.cpp via `whisper-cli` (installed via `brew install whisper-cpp`)
- Models stored in `~/.local/share/whisper-models/ggml-{size}.bin`
- Supported sizes: tiny (~75MB), base (~142MB), small (~466MB), medium (~1.5GB), large (~2.9GB)
- Auto-download models from `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{size}.bin`
- Default to `small` model — good balance of speed and accuracy on Apple Silicon

### Note Generation
- Pipe transcript to `claude` CLI (Claude Code) for note generation
- Or use Anthropic API directly if API key is configured
- Notes format: Summary, Key Discussion Points, Decisions Made, Action Items, Follow-ups

## UI Requirements

### Main Window (small, floating-capable)
- **Idle state:** 
  - Start Recording button
  - Detected meeting apps + which screen
  - Audio device status (system audio device, mic device)
  - Settings gear icon

- **Recording state:**
  - 🔴 Recording indicator with elapsed time
  - **Live audio level meters** for both system audio and mic (this is critical — user needs visual confirmation audio is being captured)
  - Stop Recording button
  - Which screen is being recorded

- **Processing state:**
  - Progress steps with ✅/❌:
    - Extracting audio...
    - Transcribing (model: ggml-small.bin)...
    - Generating notes...
  - Show word count after transcription

- **Complete state:**
  - Summary of meeting (duration, word count)
  - Quick actions: Open Notes, Open Transcript, Open Folder
  - "Process Another" / "New Recording" button

### Settings
- Audio device selection (system audio input, mic input)
- Whisper model selection (with download management)
- Screen selection preference
- Meeting storage directory (default: ~/Documents/meetings/)
- Auto-detect meeting apps toggle

### Meeting History
- List of past meetings with date, duration, summary preview
- Search across transcripts and notes
- Open notes/transcript/recording for any past meeting

## File Storage
```
~/Documents/meetings/
  YYYY-MM-DD_HH-MM/
    recording.mov
    audio.wav
    transcript.txt
    notes.md
    meeting.meta    # JSON: duration, devices used, model, etc.
```

## Tech Stack
- **SwiftUI** for UI
- **AVFoundation** for audio capture + mixing
- **ScreenCaptureKit** for screen recording (preferred) or AVFoundation fallback
- **Process/shell** for whisper-cli and claude CLI invocation
- No external Swift dependencies if possible — keep it simple

## Key Learnings from CLI Version
1. **macOS ships Bash 3.2** — but this is Swift now, so irrelevant
2. **BlackHole 2ch** is the reliable way to capture system audio on macOS
3. **"Microsoft Teams Audio"** AVFoundation device does NOT reliably capture audio — use BlackHole instead
4. **MSTeams** is the process name for new Teams (not "Microsoft Teams")
5. **whisper-cli** is the binary name from `brew install whisper-cpp`
6. **whisper-cli -m <model_path> -f <audio.wav> -otxt -of <output_prefix>** is the transcription command
7. **Audio level meters are essential** — user had no way to verify audio capture in CLI version
8. **Multi-monitor:** Window center-point matching can fail if window extends past screen bounds. Use top-left position or overlap calculation.
9. **PyObjC is NOT available** on Homebrew Python — use native Swift/AppKit for screen bounds
10. **claude** CLI accepts piped input for note generation

## Process External Files
Also support processing existing recordings (from QuickTime, etc.):
- Drag & drop a .mov/.mp4/.wav file onto the app
- Or File → Open to select a recording
- Runs the same pipeline: extract audio → whisper → Claude notes
