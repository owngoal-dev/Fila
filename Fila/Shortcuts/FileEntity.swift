import AppIntents
import FilaProtocol
import Foundation

/// One file or folder, as a Shortcut sees it.
///
/// Everything here came out of one `lstat` the daemon did — the same numbers
/// the properties screen shows, and never anything this process worked out for
/// itself. The identifier is the path, because a path is what every other
/// action takes: a shortcut chains "Find in Fila" into "Delete in Fila" by
/// carrying one of these across, and the second action resolves it as root all
/// over again.
@available(iOS 16.0, *)
struct FileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "File")
    }

    static var defaultQuery = FileEntityQuery()

    /// The absolute path. Also the identifier: two files with the same path are
    /// the same file, and nothing else about a file is stable enough to say
    /// that about — an inode is reused, a name repeats in every directory.
    var id: String { path }

    @Property(title: "Path")
    var path: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Is Folder")
    var isFolder: Bool

    /// `st_size`. What the file claims, not what it costs — a cloned or sparse
    /// file occupies less, and a directory's own size says nothing about what
    /// is inside it.
    @Property(title: "Size")
    var size: Int

    @Property(title: "Date Modified")
    var modified: Date

    @Property(title: "Date Created")
    var created: Date

    /// The mode bits in octal, `0644`-style, setuid and sticky included.
    ///
    /// A string rather than a number because that is how anyone reads them, and
    /// because nothing takes them back: Fila exposes no action that changes a
    /// file's mode. See `WriteIntents.swift` for why.
    @Property(title: "Permissions")
    var permissions: String

    @Property(title: "Owner ID")
    var ownerID: Int

    @Property(title: "Group ID")
    var groupID: Int

    /// Where a symlink points, verbatim and unresolved. Absent for everything
    /// that is not one.
    @Property(title: "Link Target")
    var linkTarget: String?

    // There is deliberately no "is protected" property. `FilaGuard`'s verdict
    // is the daemon's to give and it arrives only with a `statPath` — a listing
    // carries `FileNode`s and no verdicts — so an entity built from a listing
    // or a search could only report a guess. A shortcut branching on a guess
    // about whether a file is load-bearing is worse than one that simply asks
    // to delete it and is refused, which is what happens now.

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(path)")
    }

    init(path: String, node: FileNode) {
        self.path = path
        name = node.name.isEmpty ? (path as NSString).lastPathComponent : node.name
        isFolder = node.isNavigable
        size = Int(node.size)
        modified = Date(timeIntervalSince1970: node.modified)
        created = Date(timeIntervalSince1970: node.created)
        permissions = String(format: "%04o", node.mode & 0o7777)
        ownerID = Int(node.ownerID)
        groupID = Int(node.groupID)
        linkTarget = node.link?.target
    }

    init(_ details: FileDetails) {
        self.init(path: details.path, node: details.node)
    }

    /// An entry from a listing or a search, which carries the directory it was
    /// found in because a `FileNode` deliberately carries no path.
    init(directory: String, node: FileNode) {
        self.init(path: directory == "/" ? "/" + node.name : directory + "/" + node.name, node: node)
    }
}

/// How Shortcuts turns a remembered file back into a live one.
///
/// It re-`stat`s through the daemon rather than trusting whatever was stored in
/// the shortcut: a `FileEntity` sitting in someone's shortcut from last week
/// describes a file that may have been replaced, moved or made root-only since,
/// and every action that takes one has to act on what is there now.
@available(iOS 16.0, *)
struct FileEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [FileEntity] {
        // Waited for once, here, rather than once per identifier: with no
        // daemon every `details` below would spend the whole timeout finding
        // that out again, and ten remembered files would take a minute to
        // report the one thing that is wrong.
        _ = try await IntentSupport.session()
        var found: [FileEntity] = []
        for identifier in identifiers {
            guard let path = try? IntentSupport.path(identifier),
                  let details = try? await IntentSupport.details(of: path) else { continue }
            found.append(FileEntity(details))
        }
        return found
    }
}
