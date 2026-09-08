import Foundation

public enum ArchivePath {
    /// Finder's layout database and ZIP metadata directory are not user files.
    /// Other dotfiles, including ordinary names starting with `._`, stay intact.
    public static func isFinderMetadata(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.last == ".DS_Store" || components.contains("__MACOSX")
    }

    /// Remove the compound tar suffix as one format, preserving dots in names.
    public static func extractionFolderName(for name: String) -> String {
        let file = (name as NSString).lastPathComponent
        let suffixes = [
            ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.zstd", ".tar.lzma", ".tar.lz4", ".tar.lz", ".tar.Z",
        ]
        if let suffix = suffixes.first(where: { file.lowercased().hasSuffix($0.lowercased()) }) {
            return String(file.dropLast(suffix.count))
        }
        return (file as NSString).deletingPathExtension
    }

    /// The one form of an entry name that may be appended to a destination.
    ///
    /// Checked by walking components, never by normalising the string:
    /// `FilaGuard.normalize` collapses a leading `..` against the root the way
    /// the kernel does, which is right for an absolute path and exactly wrong
    /// here — it would turn an escape into a legal-looking relative one.
    public static func validated(_ declared: String) -> String? {
        guard !declared.isEmpty, !declared.hasPrefix("/") else { return nil }
        var components: [String] = []
        for component in declared.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": return nil
            default: components.append(String(component))
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }
}
