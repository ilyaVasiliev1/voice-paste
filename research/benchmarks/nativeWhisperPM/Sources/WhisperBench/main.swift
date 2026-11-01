import Foundation
import WhisperKit
struct Clip: Decodable { let id: String; let language: String; let text: String }
@main struct Bench {
static func main() async throws {
let home = FileManager.default.homeDirectoryForCurrentUser
let installed = home.appendingPathComponent("Library/Application Support/VoicePaste/Models")
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
let time = Date()
let engine = try await WhisperKit(WhisperKitConfig(model: "large-v3-v20240930_626MB", modelFolder: installed.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB").path, tokenizerFolder: installed.appendingPathComponent("tokenizers"), verbose: false, download: false))
print("LOAD_SECONDS \(Date().timeIntervalSince(time))")
for pass in 0..<2 { for clip in clips {
let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: root.appendingPathComponent(clip.id + ".wav").path)
let start = Date()
let results = try await engine.transcribe(audioArray: samples, decodeOptions: DecodingOptions(language: clip.language == "none" ? nil : clip.language))
let text = results.map(\.text).joined(separator: " ")
let row: [String: Any] = ["pass":pass,"id":clip.id,"language":clip.language,"reference":clip.text,"text":text,"seconds":Date().timeIntervalSince(start),"audioSeconds":Double(samples.count)/16000]
print("RESULT " + String(decoding: try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),as:UTF8.self))
}}
}
}
