#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This setup script is intended for macOS." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install it from https://brew.sh/" >&2
  exit 1
fi

echo "Installing dependencies (ffmpeg, whisper-cpp)..."
brew install ffmpeg whisper-cpp

if ! command -v claude >/dev/null 2>&1; then
  echo "Claude CLI not found. Install and authenticate it before running 'meeting stop'." >&2
fi

MEETINGS_DIR="${MEETINGS_DIR:-$HOME/Documents/meetings}"
mkdir -p "$MEETINGS_DIR"

chmod +x "$(dirname "$0")/meeting"

echo "Setup complete."
cat <<MSG

Next steps:
  1) Add this repo to your PATH, or copy the 'meeting' script to a PATH directory.
  2) Run: meeting start
  3) Approve the macOS Screen Recording permission prompt.

Optional env vars:
  MEETING_SYS_AUDIO / MEETING_MIC_AUDIO (AVFoundation audio device indices)
  MEETINGS_DIR (custom storage path)
MSG
