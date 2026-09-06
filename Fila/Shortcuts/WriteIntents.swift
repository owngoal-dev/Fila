import AppIntents
import FilaProtocol
import Foundation

/// The Shortcuts actions that change the filesystem.
///
/// # Why these exist here and not as `fila://` verbs
///
/// The URL scheme is read-only and always will be: any web page can open one,
/// with no caller identity behind it, and this app drives a root daemon. A
/// shortcut is a different thing — the user installed it deliberately and it
/// runs with their knowledge — so a write is defensible here in a way it never
/// is there.
///
/// "Deliberately" is doing real work in that sentence, though: shortcuts are
/// shared and imported, and someone running an imported one has read a
/// description, not a path. So everything below that can destroy something
/// stops and asks first, and the prompt names the path **as the daemon
/// resolved it** — `/var/mobile/x` confirmed as `/private/var/mobile/x` — so
/// that a shortcut cannot spell one place, show another, and act on a third.
///
/// # What is deliberately absent
///
/// **No permission, owner or flag change.** `setAttributes` is the one daemon
/// operation that does not consult `FilaGuard`, by design — a chmod does not
/// destroy a node, and editing what is inside `/System` is the point of the
/// app. That is a defensible rule for a person tapping a row in the properties
/// screen and an indefensible one for an imported automation: `chmod 000
/// /usr/lib/dyld` would be a single unguarded root syscall behind a tap, and
/// `chown` on a launch daemon plist is a persistence primitive. If it is ever
/// wanted here it needs the guard to grow an opinion about attribute changes
/// first, and that is a change to `filad`, not to this file.
///
/// **No symlink or hard link.** Same reason from the other end: a link is a
/// redirect, and a redirect planted somewhere privileged outlives the shortcut
/// that made it.
///
/// **No guard override.** `JobRequest.overrideGuard` exists for a person who
/// has read a dialog explaining what they are about to lose. It is not a
/// parameter, it is not a setting an intent reads, and every request built in
/// this file leaves it false.

// MARK: - Asking first

@available(iOS 16.0, *)
extension AppIntent {
    /// Stops and asks, and throws if the answer is no.
    ///
    /// The prompt names the resolved path on iOS 18 and later, where
    /// `requestConfirmation(dialog:)` exists. iOS 16 and 17 have only the
    /// no-argument form and a deprecated one that takes a dialog; the
    /// deprecated one is not used, so those systems confirm with the action's
    /// own parameter summary — still a stop, without the resolved spelling.
    func confirm(_ dialog: IntentDialog) async throws {
        if #available(iOS 18.0, *) {
            try await requestConfirmation(dialog: dialog)
        } else {
            try await requestConfirmation()
        }
    }
}

// MARK: - Create

@available(iOS 16.0, *)
struct CreateFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Folder"
    static var description = IntentDescription("Creates a folder, as root, inside another folder.")

    @Parameter(title: "Inside Folder")
    var parent: String

    @Parameter(title: "Name")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("Create folder \(\.$name) in \(\.$parent)")
    }

    /// No confirmation, and that is the whole of the reasoning: `mkdir(2)`
    /// fails with `EEXIST` rather than replacing anything, so there is no
    /// outcome here that loses a file. Asking anyway would train people to
    /// dismiss the prompts that matter.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FileEntity> {
        let parent = try IntentSupport.path(self.parent)
        let path = try IntentSupport.child(of: parent, named: name)
        try await IntentSupport.daemon { try await $0.create(.directory, at: path) }
        IntentSupport.announceChange(in: [parent])
        return .result(value: FileEntity(try await IntentSupport.details(of: path)))
    }
}

// MARK: - Copy and move

@available(iOS 16.0, *)
struct CopyItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy Item"
    static var description = IntentDescription(
        "Copies a file or folder into another folder, as root, without replacing anything already there."
    )

    @Parameter(title: "Item")
    var path: String

    @Parameter(title: "Into Folder")
    var destination: String

    static var parameterSummary: some ParameterSummary {
        Summary("Copy \(\.$path) into \(\.$destination)")
    }

    /// Confirmed even though nothing is overwritten — the job runs with
    /// `overwrite` false and a collision fails it with `EEXIST`.
    ///
    /// What is being confirmed is not a loss, it is a gain: this writes
    /// root-owned content at a path the shortcut chose, and
    /// `/Library/LaunchDaemons` is a path. Naming the resolved destination is
    /// the difference between a person agreeing to "copy my notes" and a person
    /// agreeing to what the shortcut actually spelled.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FileEntity> {
        let (source, destination, landing) = try await IntentSupport.transfer(path, into: self.destination)
        try await confirm("Copy \(source) into \(destination)?")
        try await IntentSupport.job(
            JobRequest(kind: .copy, sources: [source], destination: destination),
            kind: .copy,
            subtitle: OperationCenter.describe([source], destination: destination),
            announcing: [try IntentSupport.path(self.destination)]
        )
        return .result(value: FileEntity(try await IntentSupport.details(of: landing)))
    }
}

@available(iOS 16.0, *)
struct MoveItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Move Item"
    static var description = IntentDescription(
        "Moves a file or folder into another folder, as root, without replacing anything already there."
    )

    @Parameter(title: "Item")
    var path: String

    @Parameter(title: "Into Folder")
    var destination: String

    static var parameterSummary: some ParameterSummary {
        Summary("Move \(\.$path) into \(\.$destination)")
    }

    /// Destructive: the item stops being where it was, and moving something the
    /// system needs away from where the system looks for it breaks the device
    /// exactly as deleting it would. `FilaGuard` refuses the nodes that cannot
    /// be recovered from; the prompt covers everything else.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FileEntity> {
        let (source, destination, landing) = try await IntentSupport.transfer(path, into: self.destination)
        try await confirm("Move \(source) into \(destination)?")
        try await IntentSupport.job(
            JobRequest(kind: .move, sources: [source], destination: destination),
            kind: .move,
            subtitle: OperationCenter.describe([source], destination: destination),
            announcing: [
                try IntentSupport.path(self.destination),
                (try IntentSupport.path(path) as NSString).deletingLastPathComponent,
            ]
        )
        return .result(value: FileEntity(try await IntentSupport.details(of: landing)))
    }
}

// MARK: - Delete

@available(iOS 16.0, *)
struct DeleteItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete Item"
    static var description = IntentDescription(
        "Moves a file or folder to the trash, or deletes it permanently."
    )

    @Parameter(title: "Item")
    var path: String

    /// Off by default, matching the app: a trashed item is a `rename(2)` into
    /// Fila's own trash directory and can be put back from there, and an
    /// unrecoverable delete should never be what a parameter left at its
    /// default does.
    @Parameter(title: "Delete Permanently", default: false)
    var permanently: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Delete \(\.$path)") {
            \.$permanently
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Resolved before it is named: the prompt has to be about the file that
        // will actually be destroyed, not about the string that was typed.
        let asked = try IntentSupport.path(path)
        let target = try await IntentSupport.details(of: asked).path
        if permanently {
            try await confirm("Permanently delete \(target)? This cannot be undone.")
        } else {
            try await confirm("Move \(target) to the trash?")
        }
        try await IntentSupport.job(
            JobRequest(kind: .delete, sources: [target], useTrash: !permanently),
            kind: permanently ? .delete : .trash,
            subtitle: OperationCenter.describe([target]),
            announcing: [(asked as NSString).deletingLastPathComponent]
        )
        return .result()
    }
}

// MARK: - Write

@available(iOS 16.0, *)
struct WriteTextFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Write Text to File"
    static var description = IntentDescription(
        "Writes text to a file as root, replacing its contents and keeping its permissions, owner and dates."
    )

    @Parameter(title: "Path")
    var path: String

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Write \(\.$text) to \(\.$path)")
    }

    /// Destructive whenever the file exists, which is the usual case — this is
    /// how a shortcut edits a plist — so the prompt says which of the two it is
    /// about to do, against the resolved path.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FileEntity> {
        let path = try IntentSupport.path(self.path)
        // `try?` would be wrong here, and wrong in the one way this whole file
        // exists to prevent: it turns "could not find out" into "not there", so
        // a request that failed with `ECONNRESET` or `ELOOP` would be confirmed
        // as *Create* and then replace a file that was already sitting there.
        // Only "it is not there" means it is not there.
        let existing = try await IntentSupport.absentOrDetails(of: path)
        if let existing {
            let kind = existing.node.link?.resolvedKind ?? existing.node.kind
            // Writing "to" a directory would fail at the rename anyway; saying
            // so here means the confirmation is never about something
            // impossible.
            guard kind == .regular else { throw IntentFailure.notAFile(existing.path) }
            try await confirm("Replace the contents of \(existing.path)? This cannot be undone.")
        } else {
            try await confirm("Create \(path) with this text?")
        }

        let session = try await IntentSupport.session()
        do {
            // The app's one way of writing a file, unchanged: nothing here gets
            // its own `O_TRUNC` path, because a truncating write destroys a
            // file the user may have no copy of.
            try await AtomicSave.write(Data(text.utf8), to: path, link: session.link)
        } catch let failure as FilaFailure {
            throw IntentFailure.refused(failure)
        }
        IntentSupport.announceChange(in: [(path as NSString).deletingLastPathComponent])
        return .result(value: FileEntity(try await IntentSupport.details(of: path)))
    }
}
