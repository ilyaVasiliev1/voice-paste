#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
CACHE="$HOME/Library/Caches/VoicePaste/EngineEvaluation"
swift build -c release --package-path "$ROOT/nativeWhisperPM" --scratch-path "$CACHE/whisper-build"
/usr/bin/time -l "$CACHE/whisper-build/release/WhisperBench" "$CACHE/clips" > "$CACHE/whisper-results.log" 2> "$CACHE/whisper-resources.log"
python3 "$ROOT/score.py" "$CACHE/whisper-results.log" > "$CACHE/whisper-scored.json"
