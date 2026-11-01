# Native model experiment — 1 November 2026

## Scope and reproducibility

Apple M5 MacBook Air, 32 GB unified memory; Apple Swift 6.4.2, macOS SDK 27.2. Isolated SwiftPM executables under `research/benchmarks/`, separate build caches, no app/test host. No personal audio, microphone, history or paid APIs. Only synthetic macOS speech plus silence and seeded noise. No engine integrated into VoicePaste.

- Swift MLXAudioSTT pinned to `0dda61b29c308175e302dceef77c3bd84551e92b`; dependencies fixed in `nativeSwiftPM/Package.resolved`.
- `mlx-community/Qwen3-ASR-0.6B-4bit` revision `313d850181767edf09f00a9c289becca70e58cd0`; `model.safetensors` 708,236,945 bytes. Other tokenizer/config assets bring total near 713 MB. Apache-2.0 model, MIT Swift SDK; transitive licences still need release attribution review.
- Whisper control source from canonical cached WhisperKit, commit `25c62997041c134b03ca82731ce2f6fd2cae1eb9`; installed `openai_whisper-large-v3-v20240930_626MB` weights/tokenizer read only. Despite its folder name, installed config identifies `/raid/yoach/tmp_whisper_turbo`, with 4 decoder layers and 32 encoder layers: this is the compressed **large-v3-turbo** control, not full 32-decoder-layer large-v3.
- No Qwen/FluidAudio model cache found in standard checked caches. One Qwen model downloaded. No Parakeet/1.7B/aligner downloaded.

First build failed because Xcode's `metal` executable was a stub for missing Metal Toolchain. `xcrun --find metal` alone was misleading; `xcrun metal --version` exposed the reason. With authorization, installed Apple's official component (`xcodebuild -downloadComponent MetalToolchain`, 838.9 MB, toolchain 27B47); no xcode-select change, sudo or global third-party packages. Second build uses the working Metal compiler.

## Dataset and meaning

13 clips: RU 3, EN 2, ZH 3 (Meijia Taiwan Mandarin), digital silence/noise 2, synthetic attenuated+Gaussian-noisy speech 3. Clean RU Milena / EN Samantha. Fixed 16kHz mono PCM. Fixture generator checks nonempty voice data. These are synthetic probes, **not real classroom or distant-speaker recordings**, not evidence of lecture performance.

Both raw decoders receive the same files with explicit RU/EN/ZH hints; silence/noise use automatic language. No app VAD/cleanup pipeline, no LLM punctuation pass. Two passes per loaded process; pass 0 first inference includes initialization, pass 1 warm. File decode is outside inference timing. Model load is separate. No shortcut-to-insertion or first-partial claim.

Normalized WER (RU/EN) and CER (ZH): NFKC, lowercase, ё→е, punctuation removed, ZH whitespace removed. Simplified/traditional differences are counted. Punctuation reported separately as mark sequence edit distance, **not aligned punctuation accuracy**. Synthetic voice phrasing does not uniquely establish punctuation placement. `/usr/bin/time -l` peak RSS is process memory, not a full accounting of unified GPU memory.

Results are recorded below only after actual successful runs. Reproduction and resource/raw result locations: `research/benchmarks/README.md`.

## SDK integration caveat found during compilation

Pinned upstream MLXAudioSTT imports `MLXFFT` from `Models/NemotronTranscribe/NemotronPerception.swift` but omits that product from its target dependencies. This breaks compilation of the entire STT module even when only Qwen is used. Isolated experiment applies a one-line target dependency repair via `benchmarks/patch_sdk.py`; source algorithms unchanged. This is additional release integration risk and is not a production-ready dependency endorsement. The patch never touches app package references.

Weights SHA-256: `70c7e67e588062adce4f10796e47ad42ead51c6671eda61a0987eae38ca95ddf`.

## Actual Qwen result

Successful native release process, all 26 inferences completed. Model load **1.639 s** (first tokenizer construction included), very first 5.04 s RU inference **5.444 s**. Warm pass table:

| Synthetic group | Clips | Normalized errors / reference units | Total inference / audio | RTF | Punctuation sequence edits / reference marks |
|---|---:|---:|---:|---:|---:|
| Clean RU | 3 | WER 0 / 31 | 0.733 / 14.240 s | 0.052 | 0 / 10 |
| Clean EN | 2 | WER 0 / 24 | 0.354 / 5.839 s | 0.061 | 1 / 3 |
| Clean ZH | 3 | CER 0 / 46 | 0.530 / 11.798 s | 0.045 | 1 / 6 |
| Synthetic-noisy RU | 1 | WER 2 / 11 (18.2%) | 0.274 / 5.040 s | 0.054 | 1 / 3 |
| Synthetic-noisy EN | 1 | WER 0 / 11 | 0.172 / 2.517 s | 0.068 | 0 / 1 |
| Synthetic-noisy ZH | 1 | CER 0 / 16 | 0.163 / 3.956 s | 0.041 | 0 / 2 |

Warm latency range for speech: **0.163–0.274 s**. Process peak RSS **828,784,640 bytes** (~790 MiB), model-reported MLX peak **1.373 GB**; these are different counters, not additive totals. Whole process 12.69 s for loading and 26 short inferences.

**Critical negative finding:** digital silence produced **“The.”** on both passes. Gaussian noise produced empty text. Real spoken “Thank you for your help…” remained present (not blanket-filtered). Qwen does not remove the need for a conservative VAD/no-speech guard. Synthetic noisy RU changed «Привет, это проверка диктовки» into «Риве — это проверка дисциплины»; fluency/punctuation do not prove lexical accuracy.

EN changed the comma to a full stop; ZH also split a sentence. Hence zero normalized lexical errors does not mean perfect punctuation. Tiny, clean, known synthetic texts are not enough to establish high classroom accuracy or rank models.

Evidence: `benchmarks/results/qwen06b4bit-synthetic.json` includes raw synthetic transcript and scores; `qwen06b4bit-resources.txt` holds resource counters.

### Background-load limitation

Although other agents paused application tests/builds, a pre-existing Apple `ANECompilerService` (PID 55907, already running for over seven hours) was consuming ~100% of one CPU core. It was not killed or modified. These timings are actual local probe values under that condition, not pristine benchmark lab measurements. Do not compare them to published claims or assert Qwen beats Whisper from this run.

## Actual installed Whisper control

The independent Whisper process **completed**, with the same 13 files and two passes. Load **62.271 s**, first RU inference **1.474 s**, whole process **86.02 s**, peak RSS **497,238,016 bytes** (~474 MiB). Sampled load stack was inside Core ML / Espresso ANE compilation, so slow load is an environment-specific compilation observation, not steady model startup.

| Warm group | Normalized errors / reference units | Total inference / audio | RTF |
|---|---:|---:|---:|
| Clean RU | WER 0 / 31 | 2.725 / 14.240 s | 0.191 |
| Clean EN | WER 0 / 24 | 1.739 / 5.839 s | 0.298 |
| Clean ZH | strict CER 1 / 46 | 3.121 / 11.798 s | 0.265 |
| Synthetic-noisy RU | WER 0 / 11 | 1.057 / 5.040 s | 0.210 |
| Synthetic-noisy EN | WER 0 / 11 | 0.888 / 2.517 s | 0.353 |
| Synthetic-noisy ZH | strict CER 3 / 16 | 0.877 / 3.956 s | 0.222 |

Warm speech latency **0.806–1.146 s**. Digital silence hallucinated **“Thank you.”** on both passes. Noise produced punctuation-only **“.”**; 0 lexical errors on that empty reference does not mean no output. App no-speech handling must suppress these raw results.

**Orthography caveat:** the clean ZH “error” is `3` versus `三`; noisy ZH uses Traditional `氣/們/園` versus Simplified `气/们/园`. Those are text formatting/script differences, not evidence of mishearing. Strict CER deliberately preserves them; do not use it to claim Qwen has superior Chinese accuracy. Punctuation comparison normalizes full-width punctuation and `。`/`.` equivalents; it does not penalize equivalent comma styles.

Evidence: `benchmarks/results/whisper626mb-synthetic.json`, `whisper626mb-resources.txt`.

## Decision supported by these measurements

The native Swift Qwen 0.6B 4-bit path **works on this M5 Air** and deserves a proper next experiment. On these same tiny synthetic clips its warm inference was shorter than the installed raw Whisper control, while first inference was slower. This is not proof of a better overall application engine: the noisy RU probe favoured Whisper, both hallucinate on silence, and SDK packaging needs an upstream repair. A durable default decision still requires mixed-language human dictation, actual permitted classroom audio, long-run memory/thermal tests, app VAD integration, cancellation and end-to-end insertion timing.

**Do not replace the production engine from this probe.** Preserve Whisper baseline; keep Qwen as an isolated measured candidate. Application package/release pipeline and personal installed model assets were not modified by this experiment. The Qwen SDK generated `tokenizer.json` only inside its isolated model cache.
