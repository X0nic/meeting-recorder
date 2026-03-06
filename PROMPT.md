# Initial Prompt for Claude Code / Codex

Use this to kick off the project:

---

Build a native macOS SwiftUI app called "Meeting Recorder" that records meetings with screen capture + audio, then transcribes and generates AI notes.

Read AGENTS.md for the full spec. Key points:

1. **SwiftUI app** — small floating window, not a menu bar app
2. **Audio capture** via AVFoundation from BlackHole 2ch (system audio) + mic (user's voice), mixed together
3. **Live audio level meters** — this is the most important UI element. User MUST be able to see audio levels in real-time to confirm capture is working
4. **Screen recording** via ScreenCaptureKit with multi-monitor support
5. **Meeting app detection** — find which screen has Teams/Zoom/Meet running
6. **Transcription** — shell out to `whisper-cli` with model auto-discovery
7. **Note generation** — shell out to `claude` CLI
8. **Process existing files** — drag & drop or File → Open for QuickTime recordings
9. **Meeting history** — list past meetings, search transcripts

Start with the core recording + audio levels UI. Get audio capture working first since that's been the hardest part. Then add transcription and notes.

The app should work with:
- macOS 26+ (Apple Silicon M2)  
- BlackHole 2ch installed
- whisper-cpp installed (`whisper-cli` in PATH)
- Claude Code installed (`claude` in PATH)
