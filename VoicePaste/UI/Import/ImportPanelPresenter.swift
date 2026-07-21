import AppKit
import UniformTypeIdentifiers

/// File type list shared by the main import detail and compact HUD. Every
/// accepted URL is routed to the same persistent `ImportManager` queue.
enum ImportPanelPresenter {
    static let allowedContentTypes: [UTType] = [
        .mpeg4Audio, // .m4a
        .wav,
        .mp3,
        .mpeg4Movie, // .mp4
        .quickTimeMovie, // .mov
        UTType(filenameExtension: "m4v") ?? .movie,
        UTType(filenameExtension: "ogg") ?? .audio
    ]

}
