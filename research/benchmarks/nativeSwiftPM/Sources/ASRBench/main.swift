import Foundation
import MLXAudioSTT
import MLXAudioCore
struct Clip: Decodable { let id: String; let language: String; let text: String }
@main struct Bench {
static func main() async throws {
let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[2])
let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
let started = Date()
let model = try await Qwen3ASRModel.fromModelDirectory(URL(fileURLWithPath: args[1]))
print("LOAD_SECONDS \(Date().timeIntervalSince(started))")
for pass in 0..<2 {
for clip in clips {
let (rate, audio) = try loadAudioArray(from: root.appendingPathComponent(clip.id + ".wav"))
guard rate == 16000 else { fatalError("16kHz fixtures required") }
let time = Date()
let output = model.generate(audio: audio, maxTokens: 256, language: clip.language == "none" ? nil : clip.language)
let row: [String: Any] = ["pass":pass,"id":clip.id,"language":clip.language,"reference":clip.text,"text":output.text,"seconds":Date().timeIntervalSince(time),"peakMLXGB":output.peakMemoryUsage,"generatedTokens":output.generationTokens,"audioSeconds":Double(audio.size)/16000]
let json = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
print("RESULT " + String(decoding: json, as: UTF8.self))
}
}
}
}
