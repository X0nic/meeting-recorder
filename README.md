# meeting

A macOS CLI for recording meetings (screen + system audio + mic), then transcribing with Whisper and generating structured notes with Claude.

## Requirements
- macOS
- Homebrew
- ffmpeg (AVFoundation capture)
- whisper (whisper.cpp or OpenAI whisper CLI)
- Claude CLI

## Setup
```bash
./setup.sh
```

## Usage
```bash
meeting start          # record all screens (default)
meeting start 1        # record a specific screen by index
meeting stop           # stop recording, transcribe, and create notes
meeting list           # show past meetings with duration + summary
meeting notes 1        # view notes by index or folder name
meeting search roadmap # search transcripts and notes
```

## Storage
Meetings are saved under:
```
~/Documents/meetings/YYYY-MM-DD_HH-MM/
```
Each folder includes:
- `recording.mov`
- `audio.wav`
- `transcript.txt`
- `notes.md`

## Notes format
```
# Meeting Notes — YYYY-MM-DD HH:MM

## Summary
Brief 2-3 sentence overview

## Key Discussion Points
- Point 1
- Point 2

## Decisions Made
- Decision 1
- Decision 2

## Action Items
- [ ] Action item (@person if mentioned)

## Follow-ups
- Follow-up item

## Raw Transcript
[link to transcript.txt]
```

## Tips
- On first run, macOS will prompt for Screen Recording permission. Approve it for your terminal.
- For system audio capture, you may need a loopback device (e.g., BlackHole) and select it when prompted.
- Use these env vars to skip prompts:
  - `MEETING_SYS_AUDIO` / `MEETING_MIC_AUDIO`
  - `MEETINGS_DIR`

## Troubleshooting
- List devices:
  ```bash
  ffmpeg -f avfoundation -list_devices true -i ""
  ```
- If audio isn’t captured, confirm the correct device indices and retry.
