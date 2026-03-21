# Meeting Recorder (SwiftUI macOS App)

## What is implemented
- Native SwiftUI macOS window app (`WindowGroup`, floating-capable)
- Core recording flow: start/stop recording, processing, completion states
- Live dual audio meters (system + mic) using `AVCaptureAudioDataOutput`
- Device discovery and selection for screen/system audio/mic
- Meeting app detection (Teams/Zoom/Google Meet/Slack/Webex/FaceTime) with recommended screen
- Recording pipeline using `ffmpeg` (screen + BlackHole + mic mix)
- Post-processing pipeline:
  - extract audio
  - transcribe with `whisper-cli`
  - generate notes with `claude`
- Process existing files via drag & drop and File -> Open
- Meeting history list with search over transcript/notes

## Prerequisites
- macOS on Apple Silicon
- BlackHole 2ch installed and configured as part of Multi-Output device
- `ffmpeg` in `PATH`
- `whisper-cli` in `PATH` (`brew install whisper-cpp`)
- `claude` in `PATH`

## Run
1. Open `MeetingRecorder/Package.swift` in Xcode.
2. Select the `MeetingRecorder` executable target.
3. Run the app.

On first run macOS will prompt for microphone/screen capture permissions.

## Storage
Meetings are written to:
- `~/Documents/meetings/YYYY-MM-DD_HH-mm/`

Each folder contains:
- `recording.mov`
- `audio.wav`
- `transcript.txt`
- `notes.md`
- `meeting.meta`
- `recording.log`
