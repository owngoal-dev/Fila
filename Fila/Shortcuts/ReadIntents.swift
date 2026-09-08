import AppIntents
import FilaProtocol
import Foundation

/// The Shortcuts actions that read and navigate.
///
/// These have exactly the safety profile of the `fila://` scheme — they look at
/// the filesystem and they move the app around in it — and the three that
/// navigate *are* the scheme: they hand a `fila://` URL back to the app rather
/// than reaching into the view hierarchy, so a link and a shortcut cannot drift
/// apart about what "reveal" means. Everything that changes the filesystem is
/// in `WriteIntents.swift`, behind a confirmation, and is deliberately not
/// spellable as a URL.
///
/// Every one of them reaches the filesystem through `filad`. There is no
/// `FileManager` in this file and there must not be: the app runs as `mobile`
/// and would answer questions about a filesystem the user is not looking at.

// MARK: - Navigate

// The three below are the only ones that leave a trail, and they leave exactly
// the trail a tap does. Merely navigating to a directory does not record it:
// the browser records explicit use or backgrounding while it is current. These
// all set `openAppWhenRun`; `recordsRecents` applies to links and shortcuts alike.
//
// Nothing else in this file records anything. A shortcut that lists a folder or
// reads a file at three in the morning shows no browser and touches no
// preference — which is the honest answer, because nobody visited anything.

@available(iOS 16.0, *)
struct OpenPathIntent: AppIntent {
    static var title: LocalizedStringResource = "Open in Fila"
    static var description = IntentDescription("Opens a folder — or the folder holding a file — in Fila.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Path", default: "/")
    var path: String

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$path) in Fila")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentSupport.navigate("open", ["path": IntentSupport.path(path)])
        return .result()
    }
}

@available(iOS 16.0, *)
struct RevealItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Reveal in Fila"
    static var description = IntentDescription("Opens the folder that contains this item and selects it.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Path")
    var path: String

    static var parameterSummary: some ParameterSummary {
        Summary("Reveal \(\.$path) in Fila")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentSupport.navigate("reveal", ["path": IntentSupport.path(path)])
        return .result()
    }
}

/// Which of an installed app's two directories to open.
@available(iOS 16.0, *)
enum AppContainerKind: String, AppEnum {
    /// Where the `.app` itself lives — read-only on a stock device, which is
    /// half of why people open a file manager at all.
    case bundle
    /// The app's own Documents, Library and tmp.
    case data

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Container")
    }

    static var caseDisplayRepresentations: [AppContainerKind: DisplayRepresentation] = [
        .bundle: DisplayRepresentation(title: "Bundle"),
        .data: DisplayRepresentation(title: "Data"),
    ]
}

@available(iOS 16.0, *)
struct OpenAppContainerIntent: AppIntent {
    static var title: LocalizedStringResource = "Open App Container"
    static var description = IntentDescription(
        "Opens an installed app's bundle or data container in Fila, by bundle identifier."
    )
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Bundle Identifier")
    var bundleIdentifier: String

    @Parameter(title: "Container", default: .bundle)
    var container: AppContainerKind

    static var parameterSummary: some ParameterSummary {
        Summary("Open the \(\.$container) container of \(\.$bundleIdentifier)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        // Checked here as well as in the parser, because the parser's refusal
        // would arrive as "not an absolute path", which is not what went wrong.
        guard FilaLink.isBundleIdentifier(identifier) else {
            throw IntentFailure.invalidBundleIdentifier(bundleIdentifier)
        }
        // Mapped case by case rather than passing the raw value across. The two
        // spellings happen to match today, and if one were ever renamed the
        // parser would not fail — `AppContainer(rawValue:)` falls back to
        // `.bundle`, so the shortcut would quietly open the wrong directory.
        // An exhaustive switch cannot drift in silence.
        let target: FilaLink.AppContainer
        switch container {
        case .bundle: target = .bundle
        case .data: target = .data
        }
        try await IntentSupport.navigate("app", ["bundle": identifier, "container": target.rawValue])
        return .result()
    }
}

// MARK: - Inspect

@available(iOS 16.0, *)
struct GetItemPropertiesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get File Info"
    static var description = IntentDescription(
        "Reads an item's size, dates, permissions and owner, as root."
    )

    @Parameter(title: "Path")
    var path: String

    static var parameterSummary: some ParameterSummary {
        Summary("Get info about \(\.$path)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FileEntity> {
        .result(value: FileEntity(try await IntentSupport.details(of: IntentSupport.path(path))))
    }
}

@available(iOS 16.0, *)
struct ListDirectoryIntent: AppIntent {
    static var title: LocalizedStringResource = "List Folder"
    static var description = IntentDescription("Lists the contents of a folder for use in other Fila actions.")

    @Parameter(title: "Folder", default: "/")
    var path: String

    @Parameter(title: "Include Hidden Items", default: false)
    var includesHidden: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("List \(\.$path)") {
            \.$includesHidden
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[FileEntity]> {
        let directory = try IntentSupport.path(path)
        let session = try await IntentSupport.session()
        var entries: [FileEntity] = []
        try await IntentSupport.mapping {
            for try await page in DirectoryReader.pages(in: directory, session: session) {
                for node in page where includesHidden || !node.isHidden {
                    entries.append(FileEntity(directory: directory, node: node))
                }
                // Refused rather than cut short: a shortcut cannot tell a capped
                // list from a complete one, and a script that believes it has
                // seen every file in a folder will act on that belief.
                guard entries.count <= IntentSupport.listEntryLimit else {
                    throw IntentFailure.tooManyEntries(directory)
                }
            }
        }
        return .result(value: entries)
    }
}

@available(iOS 16.0, *)
struct FindFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Files"
    static var description = IntentDescription(
        "Searches a folder and its subfolders for names containing the text you enter."
    )

    @Parameter(title: "Name Contains")
    var query: String

    @Parameter(title: "Starting Folder", default: "/")
    var path: String

    /// The bound has to be a literal here, and `FileSearch.resultLimit` is the
    /// real ceiling — `perform` clamps to it, so the two cannot drift into a
    /// shortcut asking for more than the walk will ever produce.
    @Parameter(title: "Maximum Results", default: 100, inclusiveRange: (1, 100))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$query) in \(\.$path)") {
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[FileEntity]> {
        let root = try IntentSupport.path(path)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FilaLink.isPlausibleQuery(needle) else { throw IntentFailure.invalidSearch(query) }
        let session = try await IntentSupport.session()

        // The same walk the search screen runs — breadth-first, in the app,
        // over listings the daemon paged out. Its own ceilings apply and the
        // parameter cannot exceed them, so the number the shortcut asked for is
        // the number it can actually be given.
        //
        // ponytail: the limit caps what is *collected*, not what is walked —
        // `FileSearch.run` has no way to be stopped short of cancelling its
        // task, so "find one thing below `/`" still costs a full search. Same
        // cost the search screen pays for every query. Give `FileSearch` a
        // result limit of its own the day that is too slow to live with.
        let wanted = min(limit, FileSearch.resultLimit)
        var found: [FileEntity] = []
        await FileSearch.run(root: root, needle: needle, session: session) { _ in } onHit: { hit in
            guard found.count < wanted else { return }
            found.append(FileEntity(directory: hit.directory, node: hit.node))
        }
        return .result(value: found)
    }
}

@available(iOS 16.0, *)
struct ReadTextFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Text from File"
    static var description = IntentDescription(
        "Reads a text file as root and returns its contents."
    )

    @Parameter(title: "Path")
    var path: String

    static var parameterSummary: some ParameterSummary {
        Summary("Get text from \(\.$path)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let path = try IntentSupport.path(self.path)
        let details = try await IntentSupport.details(of: path)
        // A directory read as text is not an empty string, and a device node
        // read as text can block forever. Only a regular file — or a link that
        // resolves to one — is a file to read.
        let kind = details.node.link?.resolvedKind ?? details.node.kind
        guard kind == .regular else { throw IntentFailure.notAFile(path) }

        // One byte past the ceiling, so a file that is exactly too big is
        // refused rather than silently handed over short.
        let session = try await IntentSupport.session()
        let data = try await IntentSupport.mapping {
            try await session.read(path, limit: IntentSupport.textByteLimit + 1)
        }
        guard data.count <= IntentSupport.textByteLimit else { throw IntentFailure.tooLarge(path) }
        guard let text = String(data: data, encoding: .utf8) else { throw IntentFailure.notText(path) }
        return .result(value: text)
    }
}
