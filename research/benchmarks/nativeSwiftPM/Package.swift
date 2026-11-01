// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "ASRBench", platforms: [.macOS(.v15)], dependencies: [
.package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "0dda61b29c308175e302dceef77c3bd84551e92b")
], targets: [.executableTarget(name: "ASRBench", dependencies: [.product(name: "MLXAudioSTT", package: "mlx-audio-swift"), .product(name: "MLXAudioCore", package: "mlx-audio-swift")])])
