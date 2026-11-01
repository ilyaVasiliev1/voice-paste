# Isolated native ASR experiment

No application/test host, user history, microphone or private audio is opened. Weights and build products stay under `~/Library/Caches/VoicePaste/EngineEvaluation`. Only one 0.6B 4-bit Qwen model is downloaded; no aligner or 1.7B weights.

## Reproduce

1. Xcode with working Metal compiler: `xcrun metal --version`. If it reports missing toolchain, the official prerequisite is `xcodebuild -downloadComponent MetalToolchain` (839 MB on this machine). `xcrun --find metal` alone finds a stub and does not prove availability.
2. On an empty model cache: `python3 research/benchmarks/download_model.py`. SDK commit and model revision are fixed in the package/downloader; `Package.resolved` fixes transitive versions.
3. `zsh research/benchmarks/run-native.sh`. Run without a concurrent build, test, or transcription. First process load and two passes are recorded separately; pass 0 includes first-inference initialization, pass 1 is warm. Model download/build are excluded from inference time.
4. Raw transcripts/timings: `EngineEvaluation/results.log`; normalized scores: `scored.json`; `/usr/bin/time -l` process peak RSS and resource counters: `resources.log`. Peak RSS is not total GPU/unified-memory residency.

The 13 fixtures are synthesized with installed macOS voices Milena, Samantha, Meijia (Taiwan Mandarin), plus digital silence and seeded Gaussian noise. Three speech variants add deterministic Gaussian noise and attenuation. They are **not classroom/far-field tests**. Fixture generation requires the voices; silent/missing voice assets invalidate a run.

Normalization: NFKC, lowercase, ё→е, punctuation ignored for WER/CER. Chinese CER removes spaces. Punctuation sequence edit distance is reported separately; it measures mark sequence, not placement/F1. These synthetic readings do not have unique spoken punctuation ground truth. Chinese simplified/traditional output differences remain counted; interpret them explicitly.

The harness calls the model directly, without the app's VAD/hallucination filters. Silence/noise output tests the decoder itself. It does not measure shortcut-to-insertion latency, streaming UI, classroom accuracy, long-duration thermals, cancellation, or file pipeline performance. No model is promoted to production based on this probe.

## Installed Whisper control

`nativeWhisperPM` links the existing canonical source cache (read-only) rather than changing the app target. Source commit used: `25c62997041c134b03ca82731ce2f6fd2cae1eb9`. It reads only installed `openai_whisper-large-v3-v20240930_626MB` model/tokenizer assets (config: 4 decoder layers, turbo architecture), not history. Build with its own `--scratch-path "$CACHE/whisper-build"`; run `WhisperBench "$CACHE/clips"` under `/usr/bin/time -l`, save `whisper-results.log`, and score with the same `score.py`. It intentionally has no app's VAD/cleanup filters, like the Qwen raw decoder. Tokenizer/model downloads are disabled; missing assets are an error. Comparing this raw baseline to app pipeline behavior would be misleading.

Pinned SDK currently needs `patch_sdk.py`: `MLXAudioSTT` imports `MLXFFT` in an unrelated Nemotron file but omitted the target dependency. The script repairs only the isolated cached SDK manifest. `run-native.sh` resolves, patches, then builds. This local workaround is a recorded SDK integration risk, not an app dependency change. Punctuation scoring normalizes full-width marks and equivalent Chinese full stops.
