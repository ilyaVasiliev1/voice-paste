// swift-tools-version:6.2
import PackageDescription
import Foundation
let package = Package(name: "WhisperBench", platforms: [.macOS(.v15)], dependencies: [
.package(path: NSHomeDirectory() + "/Library/Caches/VoicePaste/SourcePackages/checkouts/WhisperKit")
], targets: [.executableTarget(name: "WhisperBench", dependencies: [.product(name: "WhisperKit", package: "WhisperKit")])])
