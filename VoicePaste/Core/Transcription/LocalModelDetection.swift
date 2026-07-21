import Foundation

/// Single shared criterion for "is a verified WhisperKit model already on
/// disk" (`L-001`/`AT-004`), used by both `ModelManager` (startup readiness
/// check) and `WhisperKitTranscriber` (actual load path) so the two can never
/// drift apart — a readiness state that disagrees with what WhisperKit
/// itself would actually load is exactly the `AT-004` regression this type
/// exists to prevent.
///
/// WhisperKit's download (see `HubApi.localRepoLocation` in
/// `ArgmaxCore/External/Hub/HubApi.swift`) nests the model a few levels below
/// `downloadBase` (`<downloadBase>/models/argmaxinc/whisperkit-coreml/<variant>`),
/// so detection must walk into subfolders rather than assume a flat root —
/// while still succeeding at depth 0 for a caller that already points
/// straight at the model folder (e.g. existing unit tests).
///
/// Filesystem-only: doesn't guess WhisperKit's internal cache layout or
/// require importing its Hub-facing internals, so this type stays available
/// even in build environments where the WhisperKit package can't resolve
/// (see `WhisperKitTranscriber`'s isolation comment).
enum LocalModelDetection {
    private static let requiredComponents = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    /// Lower bound on the *total* size of a candidate model folder for it to
    /// be trusted as a real, fully-downloaded model rather than a stub/torn
    /// download.
    ///
    /// Observed real-world regression: a download that was interrupted (or
    /// never actually ran) left behind only the `.mlmodelc` folder skeletons
    /// plus tiny placeholder files (`coremldata.bin`, a few hundred bytes) —
    /// no `model.mil`, no weights — totalling ~36 KB on disk. `isVerified`
    /// previously only checked folder *existence*, so it happily reported
    /// this stub as a verified model; WhisperKit then failed at load time
    /// with "Failed to parse ML Program … model.mil cannot be read".
    ///
    /// The shipped model (`ModelCatalog.approximateSizeBytes`, 626 MB) is a
    /// specific variant that may change size across catalog updates, so this
    /// threshold intentionally does NOT hardcode that figure — instead it
    /// picks a size floor far below any real Whisper CoreML model (even the
    /// smallest published variants are well over this) but far above what a
    /// torn/partial download or folder skeleton could ever produce.
    static let minimumPlausibleTotalBytes: Int64 = 50 * 1024 * 1024 // 50 MB

    /// Recursively looks for an already-downloaded, verified model folder
    /// under `directory` (a compiled `.mlmodelc` or source `.mlpackage` for
    /// each required component), returning the folder that satisfies all of
    /// them, or `nil` if none is found within `maxDepth` levels.
    ///
    /// "Verified" requires more than folder existence: each component's
    /// actual model payload (`model.mil` for a compiled `.mlmodelc`, or
    /// `model.mlmodel` for a source `.mlpackage`) must exist with non-zero
    /// size, AND the candidate folder's total on-disk size must clear
    /// `minimumPlausibleTotalBytes` — together these reject a stub/torn
    /// download that only has empty directory scaffolding.
    static func discoverModelFolder(in directory: URL, maxDepth: Int = 4) -> URL? {
        func hasNonEmptyFile(at url: URL) -> Bool {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
            return size > 0
        }
        func componentsPresent(_ folder: URL) -> Bool {
            requiredComponents.allSatisfy { name in
                let compiledPayload = folder.appendingPathComponent("\(name).mlmodelc/model.mil")
                let packagePayload = folder.appendingPathComponent("\(name).mlpackage/Data/com.apple.CoreML/model.mlmodel")
                return hasNonEmptyFile(at: compiledPayload) || hasNonEmptyFile(at: packagePayload)
            }
        }
        func totalSize(of folder: URL) -> Int64 {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                      values.isDirectory != true
                else { continue }
                total += Int64(values.fileSize ?? 0)
            }
            return total
        }
        func isVerified(_ folder: URL) -> Bool {
            componentsPresent(folder) && totalSize(of: folder) >= minimumPlausibleTotalBytes
        }
        func search(_ folder: URL, depth: Int) -> URL? {
            if isVerified(folder) { return folder }
            guard depth < maxDepth,
                  let children = try? FileManager.default.contentsOfDirectory(
                      at: folder,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles]
                  )
            else { return nil }
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                if let found = search(child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }
        return search(directory, depth: 0)
    }
}
