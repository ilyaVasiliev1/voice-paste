"""Temporary upstream manifest repair; changes only isolated experiment checkout."""
import pathlib
p=pathlib.Path.home()/'Library/Caches/VoicePaste/EngineEvaluation/build/checkouts/mlx-audio-swift/Package.swift'
s=p.read_text();start=s.index('// MARK: - MLXAudioSTT');end=s.index('// MARK: - MLXAudioVAD',start)
part=s[start:end]
if '.product(name: "MLXFFT"' not in part:
 part=part.replace('.product(name: "MLXFast", package: "mlx-swift"),','.product(name: "MLXFast", package: "mlx-swift"),\n                .product(name: "MLXFFT", package: "mlx-swift"),')
 p.chmod(p.stat().st_mode | 0o200)
 p.write_text(s[:start]+part+s[end:])
