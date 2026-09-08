import FilaProvider
import FileProvider
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Files' view of one folder, on the replicated File Provider API.
///
/// The system keeps the on-disk replica, every download and every conflict;
/// this answers metadata, hands out content, and applies the mutations Files
/// asks for. It never talks to `filad`: whatever the extension's own
/// permissions can read is what Files can see. There is no trash — the domain
/// does not sync one, so Files deletes after its own confirmation.
@available(iOS 16.0, *)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
    fileprivate let domain: NSFileProviderDomain
    private let queue = DispatchQueue(label: "wiki.qaq.fila.fileprovider")
    private let logger = Logger(subsystem: "wiki.qaq.fila.fileprovider", category: "provider")
    private var tree: ProviderTree?
    private var watchers: [NSFileProviderItemIdentifier: DispatchSourceFileSystemObject] = [:]

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {
        queue.async {
            self.watchers.values.forEach { $0.cancel() }
            self.watchers = [:]
        }
    }

    /// The system trusts its replica and asks for changes only when told to;
    /// a folder on disk tells nobody. So an enumerated directory is watched
    /// for the life of this instance — once per container, however many
    /// enumerators the system makes for it, and it makes a new one after
    /// every signal — and a change there signals that container. Never
    /// signal on enumerator creation: that is the loop.
    ///
    /// ponytail: the working set watches the root only, not the whole tree.
    /// A change deep inside is noticed when that folder is open in Files, or
    /// when the app signals after its own jobs; watch every directory if not.
    fileprivate func watch(_ container: NSFileProviderItemIdentifier, at path: String) {
        // The strong capture is written out because the event handler below
        // takes `self` weakly: the compiler flags the two spellings sitting in
        // one nesting, and the outer block does hold the extension alive until
        // the source is installed.
        queue.async { [self] in
            guard watchers[container] == nil else { return }
            let descriptor = open(path, O_EVTONLY | O_DIRECTORY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                NSFileProviderManager(for: domain)?.signalEnumerator(for: container) { [weak self] error in
                    if let error {
                        self?.logger.error("Signal for \(container.rawValue, privacy: .public) failed: \(error)")
                    }
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers[container] = source
        }
    }

    // MARK: - The folder

    private func openTree() throws -> ProviderTree {
        if let tree {
            return tree
        }
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FilaAppGroupIdentifier") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              let location = try ProviderLocation.load(in: container)
        else { throw NSFileProviderError(.notAuthenticated) }
        let index = container
            .appendingPathComponent(".fila-provider", isDirectory: true)
            .appendingPathComponent(location.generation.uuidString, isDirectory: true)
            .appendingPathComponent("index.json")
        let tree = try ProviderTree(root: location.resolve(in: container), index: index)
        self.tree = tree
        return tree
    }

    /// Every request runs here, in order, and reports through `completion`
    /// with an error the system accepts.
    @discardableResult
    fileprivate func run<T>(_ body: @escaping (ProviderTree) throws -> T, label: String = #function, then completion: @escaping (Result<T, Error>) -> Void) -> Progress {
        queue.async {
            let result = Result { try body(self.openTree()) }.mapError(Self.mapped)
            if case let .failure(error) = result {
                self.logger.error("\(label, privacy: .public) failed: \(error)")
            }
            completion(result)
        }
        return Progress()
    }

    /// The parent Files named, as the tree names it. The trash is not a place
    /// anything can be put.
    private static func parent(_ identifier: NSFileProviderItemIdentifier) throws -> String? {
        switch identifier {
        case .rootContainer: return nil
        case .trashContainer: throw ProviderTree.Failure.unsupported
        default: return identifier.rawValue
        }
    }

    // MARK: - Items

    func item(for identifier: NSFileProviderItemIdentifier, request _: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress
    {
        run({ tree -> NSFileProviderItem in
            switch identifier {
            case .rootContainer: return ProviderItem.root
            case .trashContainer: throw NSFileProviderError(.noSuchItem)
            default: return try ProviderItem(tree.entry(identifier.rawValue))
            }
        }) { result in
            switch result {
            case let .success(item): completionHandler(item, nil)
            case let .failure(error): completionHandler(nil, error)
            }
        }
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version _: NSFileProviderItemVersion?,
                       request _: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress
    {
        let domain = domain
        return run({ tree -> (URL, ProviderItem) in
            let entry = try tree.entry(itemIdentifier.rawValue)
            // The system clones and unlinks what it is handed, so it has to be
            // a file of its own in its own temporary directory.
            guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
            let temporary = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString, isDirectory: false)
            try tree.exportContents(of: entry.id, to: temporary)
            return (temporary, ProviderItem(entry))
        }) { result in
            switch result {
            case let .success((url, item)): completionHandler(url, item, nil)
            case let .failure(error): completionHandler(nil, nil, error)
            }
        }
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions, request _: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress
    {
        run({ tree -> ProviderItem in
            let parent = try Self.parent(itemTemplate.parentItemIdentifier)
            let type = itemTemplate.contentType as UTType?
            var entry: ProviderTree.Entry
            do {
                if type?.conforms(to: .directory) == true {
                    entry = try tree.createDirectory(name: itemTemplate.filename, parent: parent)
                } else if type?.conforms(to: .symbolicLink) == true {
                    throw ProviderTree.Failure.unsupported
                } else {
                    entry = try tree.createFile(name: itemTemplate.filename, parent: parent, contents: url)
                }
            } catch ProviderTree.Failure.collision where options.contains(.mayAlreadyExist) {
                // A re-import after a crash or a merge: the item is the one
                // already there, whatever it holds.
                guard let existing = try tree.existing(name: itemTemplate.filename, parent: parent) else { throw ProviderTree.Failure.collision }
                entry = existing
            }
            if fields.contains(.contentModificationDate), let date = itemTemplate.contentModificationDate ?? nil {
                entry = try tree.setModificationDate(entry.id, date)
            }
            return ProviderItem(entry)
        }) { result in
            switch result {
            case let .success(item): completionHandler(item, [], false, nil)
            case let .failure(error): completionHandler(nil, [], false, error)
            }
        }
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion _: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options _: NSFileProviderModifyItemOptions, request _: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress
    {
        run({ tree -> (ProviderItem, NSFileProviderItemFields) in
            var entry = try tree.entry(item.itemIdentifier.rawValue)
            // Whatever is not applied here stays pending; the system stops
            // sending a field the provider never takes.
            var pending = changedFields
            if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                let parent = changedFields.contains(.parentItemIdentifier) ? try Self.parent(item.parentItemIdentifier) : entry.parent
                let name = changedFields.contains(.filename) ? item.filename : entry.name
                entry = try tree.move(entry.id, name: name, parent: parent)
                pending.remove(.filename)
                pending.remove(.parentItemIdentifier)
            }
            if changedFields.contains(.contents), let newContents {
                entry = try tree.replaceContents(of: entry.id, with: newContents)
                pending.remove(.contents)
            }
            if changedFields.contains(.contentModificationDate), let date = item.contentModificationDate ?? nil {
                entry = try tree.setModificationDate(entry.id, date)
                pending.remove(.contentModificationDate)
            }
            return (ProviderItem(entry), pending)
        }) { result in
            switch result {
            case let .success((item, pending)): completionHandler(item, pending, false, nil)
            case let .failure(error): completionHandler(nil, [], false, error)
            }
        }
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion _: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions, request _: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress
    {
        run({ tree in
            do { try tree.delete(identifier.rawValue, recursive: options.contains(.recursive)) }
            // Already gone is the outcome the caller asked for.
            catch let failure as ProviderTree.Failure where failure == .missing {}
        }) { result in
            switch result {
            case .success: completionHandler(nil)
            case let .failure(error): completionHandler(error)
            }
        }
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request _: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        ProviderEnumerator(container: containerItemIdentifier, provider: self)
    }

    // MARK: - Thumbnails

    /// Pictures only, downsampled from the file itself. Everything else gets
    /// the system's icon for its type.
    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress
    {
        queue.async {
            let tree = try? self.openTree()
            for identifier in itemIdentifiers {
                let data = tree.flatMap { Self.thumbnail(of: identifier.rawValue, in: $0, maxPixelSize: Int(max(size.width, size.height))) }
                perThumbnailCompletionHandler(identifier, data, nil)
            }
            completionHandler(nil)
        }
        return Progress()
    }

    private static let thumbnailSourceCeiling: Int64 = 32 * 1024 * 1024

    private static func thumbnail(of id: String, in tree: ProviderTree, maxPixelSize: Int) -> Data? {
        guard let entry = try? tree.entry(id), !entry.isDirectory, entry.size <= thumbnailSourceCeiling,
              UTType(filenameExtension: (entry.name as NSString).pathExtension)?.conforms(to: .image) == true,
              let path = try? tree.contentsPath(of: id),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: - Errors

    /// Only Cocoa and File Provider errors are accepted; anything else is
    /// treated as transient and retried forever, so the rest is wrapped the
    /// way the header asks.
    fileprivate static func mapped(_ error: Error) -> Error {
        switch error {
        case let failure as ProviderTree.Failure:
            switch failure {
            case .missing: return NSFileProviderError(.noSuchItem)
            case .collision: return NSFileProviderError(.filenameCollision)
            case .directoryNotEmpty: return NSFileProviderError(.directoryNotEmpty)
            case .invalidName: return CocoaError(.fileWriteInvalidFileName)
            case .unsupported: return NSFileProviderError(.excludedFromSync)
            case .permission: return CocoaError(.fileWriteNoPermission)
            case .noSpace: return CocoaError(.fileWriteOutOfSpace)
            case let .io(code): return NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        case is NSFileProviderError, is CocoaError:
            return error
        default:
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSFileProviderErrorDomain {
                return error
            }
            return NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid, userInfo: [NSUnderlyingErrorKey: nsError])
        }
    }
}

// MARK: - Items

@available(iOS 16.0, *)
private final class ProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion

    static let root = ProviderItem()

    override private init() {
        itemIdentifier = .rootContainer
        parentItemIdentifier = .rootContainer
        filename = "Fila"
        contentType = .folder
        capabilities = [.allowsContentEnumerating, .allowsAddingSubItems]
        documentSize = nil
        creationDate = nil
        contentModificationDate = nil
        itemVersion = NSFileProviderItemVersion(contentVersion: Data("root".utf8), metadataVersion: Data("root".utf8))
        super.init()
    }

    init(_ entry: ProviderTree.Entry) {
        itemIdentifier = NSFileProviderItemIdentifier(entry.id)
        parentItemIdentifier = entry.parent.map { NSFileProviderItemIdentifier($0) } ?? .rootContainer
        filename = entry.name
        contentType = entry.isDirectory
            ? .folder
            : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
        capabilities = entry.isDirectory
            ? [.allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming, .allowsReparenting, .allowsDeleting]
            : [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsEvicting]
        documentSize = entry.isDirectory ? nil : NSNumber(value: entry.size)
        creationDate = entry.created
        contentModificationDate = entry.modified
        itemVersion = NSFileProviderItemVersion(contentVersion: Data(entry.contentVersion.utf8), metadataVersion: Data(entry.metadataVersion.utf8))
        super.init()
    }
}

// MARK: - Enumeration

/// One container: a folder, the working set, the empty trash, or a single
/// document the system is watching.
@available(iOS 16.0, *)
private final class ProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    /// Strong: the system may keep an enumerator past the instance that made
    /// it, and nothing points back from the extension to its enumerators.
    private let provider: FileProviderExtension

    init(container: NSFileProviderItemIdentifier, provider: FileProviderExtension) {
        self.container = container
        self.provider = provider
        super.init()
        let watched: String?? = switch container {
        case .workingSet, .rootContainer: .some(nil)
        case .trashContainer: nil
        default: .some(container.rawValue)
        }
        guard let watched else { return }
        provider.run({ tree -> String in
            let entry = try watched.map { try tree.entry($0) }
            guard entry?.isDirectory ?? true else { throw ProviderTree.Failure.unsupported }
            return try tree.path(of: watched)
        }, label: "watch \(container.rawValue)") { result in
            guard case let .success(path) = result else { return }
            provider.watch(container, at: path)
        }
    }

    func invalidate() {}

    /// Whether a change to `entry` belongs in this enumeration.
    private func includes(_ entry: ProviderTree.Entry) -> Bool {
        switch container {
        case .workingSet: true
        case .trashContainer: false
        case .rootContainer: entry.parent == nil
        default: entry.parent == container.rawValue || entry.id == container.rawValue
        }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt _: NSFileProviderPage) {
        let container = container
        // ponytail: one page. Files pages for the scroll position, and a
        // Documents folder fits in one answer; page when a folder does not.
        provider.run({ tree -> [ProviderItem] in
            switch container {
            case .workingSet: return try tree.all().map(ProviderItem.init)
            case .trashContainer: return []
            case .rootContainer: return try tree.children(of: nil).map(ProviderItem.init)
            default:
                let entry = try tree.entry(container.rawValue)
                return entry.isDirectory ? try tree.children(of: entry.id).map(ProviderItem.init) : [ProviderItem(entry)]
            }
        }, label: "enumerateItems \(container.rawValue)") { result in
            switch result {
            case let .success(items):
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            case let .failure(error):
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        provider.run({ $0.anchor }, label: "currentSyncAnchor \(container.rawValue)") { result in
            completionHandler((try? result.get()).map { NSFileProviderSyncAnchor($0) })
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        provider.run({ tree -> ProviderTree.Changes in
            guard let changes = try tree.changes(since: anchor.rawValue) else { throw NSFileProviderError(.syncAnchorExpired) }
            return changes
        }, label: "enumerateChanges \(container.rawValue)") { result in
            switch result {
            case let .success(changes):
                let deleted = changes.deleted.filter(self.includes).map { NSFileProviderItemIdentifier($0.id) }
                if !deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: deleted)
                }
                let updated = changes.updated.filter(self.includes).map(ProviderItem.init)
                if !updated.isEmpty {
                    observer.didUpdate(updated)
                }
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(changes.anchor), moreComing: false)
            case let .failure(error):
                observer.finishEnumeratingWithError(error)
            }
        }
    }
}
