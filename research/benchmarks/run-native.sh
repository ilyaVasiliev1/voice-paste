#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
CACHE="$HOME/Library/Caches/VoicePaste/EngineEvaluation"
python3 "$ROOT/make_fixtures.py" "$CACHE/clips"
swift package --package-path "$ROOT/nativeSwiftPM" --scratch-path "$CACHE/build" resolve
python3 "$ROOT/patch_sdk.py"
swift build -c release --package-path "$ROOT/nativeSwiftPM" --scratch-path "$CACHE/build"
/usr/bin/time -l "$CACHE/build/release/ASRBench" "$CACHE/model" "$CACHE/clips" > "$CACHE/results.log" 2> "$CACHE/resources.log"
python3 "$ROOT/score.py" "$CACHE/results.log" > "$CACHE/scored.json"
