import FilaFormats
import FilaProtocol
import Foundation

/// The images beside the one being viewed, in the order the folder shows them,
/// so a swipe lands on the image the next row would have opened.
///
/// Membership is by name, which is all a listing knows without opening every
/// file. A file that claims to be an image and is not shows its own refusal
/// on its own page, the way it would have if it had been tapped.
struct ImageGallery: Sendable {
    let directory: String
    let names: [String]
    /// The image on screen. The viewer container keeps it current, so reopening
    /// as Image after trying another format starts where the user was.
    var index: Int

    func path(at index: Int) -> String {
        directory == "/" ? "/" + names[index] : directory + "/" + names[index]
    }

    /// Nil unless there is somewhere to swipe to. Every file tap waits for
    /// this, so anything that is not an image by name returns at once. The
    /// filter runs off the main thread: a folder can show tens of thousands of
    /// rows, and an extension the format table does not name costs a `UTType`
    /// lookup.
    static func collect(_ nodes: [FileNode], in directory: String, around name: String) async -> ImageGallery? {
        guard FileFormat.detect(name: name) == .image else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let names = nodes.compactMap { node -> String? in
                let kind = node.kind == .symbolicLink ? node.link?.resolvedKind : node.kind
                guard kind == .regular, FileFormat.detect(name: node.name) == .image else { return nil }
                return node.name
            }
            guard names.count > 1, let index = names.firstIndex(of: name) else { return nil }
            return ImageGallery(directory: directory, names: names, index: index)
        }.value
    }
}
