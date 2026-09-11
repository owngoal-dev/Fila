import AlertController
import FilaFormats
import FilaProtocol
import UIKit

extension FileActions {
    /// What a tap unpacks rather than opens: the archives people make to carry
    /// files. A package (`.deb`, `.ipa`, `.tipa`), a static library (`.a`), a
    /// disk image or an installer payload is something to look inside, and a
    /// tap on one in `/var/jb/usr/lib` must not write its members beside it.
    /// Neither does a lone `.gz` or `.xz`: that is one compressed file — a man
    /// page, a changelog — usually in a system folder; only `.tar.gz` and its
    /// kind are archives.
    static func extractsOnTap(_ name: String) -> Bool {
        let name = name.lowercased() as NSString
        switch name.pathExtension {
        case "zip", "7z", "rar", "tar", "tgz", "txz", "tbz", "lha", "lzh", "cab": return true
        case "gz", "xz", "bz2", "zst", "lz4", "lzma": return name.deletingPathExtension.hasSuffix(".tar")
        default: return false
        }
    }

    private struct Extraction: Hashable {
        let archive: String
        let members: [ArchiveSelection]?
        let destination: String
    }

    /// Extractions under way. A second tap before the card covers the screen
    /// would otherwise publish a second copy beside the first; different
    /// members of the same archive are a different extraction.
    private static var extracting: Set<Extraction> = []

    /// Every extraction — a tap, a menu, the archive browser — goes through
    /// here. The helper publishes one top-level item directly, or groups
    /// several in a folder named after the archive, and never replaces what is
    /// already there.
    ///
    /// - `destination`: the archive's own folder when nil.
    /// - `estimate`: the listed sizes, when a listing exists, checked against
    ///   the free space before anything starts. Advisory only; the job checks
    ///   real writes.
    /// - `encrypted`: the listing already knows a password is needed. Without
    ///   a listing the job finds out, and the password is asked for then.
    func extract(
        _ archive: String,
        members: [ArchiveSelection]? = nil,
        into destination: String? = nil,
        estimate: ArchiveSpaceEstimate? = nil,
        encrypted: Bool = false,
        password: String? = nil
    ) {
        let destination = destination ?? (archive as NSString).deletingLastPathComponent
        let extraction = Extraction(archive: archive, members: members, destination: destination)
        guard !Self.extracting.contains(extraction) else { return }
        if encrypted, password == nil {
            return promptArchivePassword { [self] password in
                extract(archive, members: members, into: destination, estimate: estimate, password: password)
            }
        }
        presenter?.setEditing(false, animated: true)
        let center = session.operations
        Self.extracting.insert(extraction)
        Task {
            do {
                if let estimate, let warning = try? await spaceWarning(for: estimate, at: destination) {
                    Self.extracting.remove(extraction)
                    return confirmLowSpace(warning) { [self] in
                        extract(archive, members: members, into: destination, password: password)
                    }
                }
                let cover = jobCover()
                let identifier = try await center.startJob(
                    // Options are not optional for an archive job — the helper
                    // refuses one without them. Nil members is every member.
                    JobRequest(
                        kind: .extract,
                        sources: [archive],
                        destination: destination,
                        archive: ArchiveOptions(password: password, members: members, organizeExtraction: true)
                    ),
                    kind: .extract,
                    title: OperationCenter.Kind.extract.runningTitle,
                    subtitle: OperationCenter.describe([archive], destination: destination),
                    // A wrong password is a question, not a failure: failures
                    // are reported below, and the success toast still shows.
                    feedback: .successOnly
                ) { [self] outcome in
                    Self.extracting.remove(extraction)
                    cover.settle { [self] in
                        switch outcome.code {
                        case .success, .cancelled: break
                        case .wrongPassword:
                            promptArchivePassword { [self] password in
                                extract(archive, members: members, into: destination, password: password)
                            }
                        default: report(outcome)
                        }
                    }
                }
                cover.show(job: identifier, in: center)
            } catch {
                Self.extracting.remove(extraction)
                report(error)
            }
        }
    }

    func promptArchivePassword(_ handler: @escaping (String) -> Void) {
        guard let presenter = activePresenter else { return }
        let alert = AlertInputViewController(
            title: String.LocalizationValue("Enter Password"),
            message: String.LocalizationValue("This archive is encrypted. Enter its password to extract."),
            placeholder: String.LocalizationValue("Password"),
            text: "",
            doneButtonText: String.LocalizationValue("Extract")
        ) { password in
            guard !password.isEmpty else { return }
            handler(password)
        }
        presenter.present(alert, animated: true)
    }

    /// The sentence to show when `estimate` does not comfortably fit, or nil.
    private func spaceWarning(for estimate: ArchiveSpaceEstimate, at destination: String) async throws -> String? {
        let available = try await availableSpace(at: destination)
        guard estimate.needsWarning(availableByteCount: available) else { return nil }
        return estimate.hasUnknownSize
            ? String(localized: "This archive does not list a size for every item. Check free space before extracting.")
            : String(
                format: String(localized: "These items need %1$@, which is more than %2$@ of the %3$@ free here."),
                FilePresentation.byteLabel(estimate.byteCount),
                ArchiveSpaceEstimate.warningFraction.formatted(.percent),
                FilePresentation.byteLabel(available)
            )
    }

    private func confirmLowSpace(_ message: String, extract: @escaping () -> Void) {
        guard let presenter = activePresenter else { return }
        let alert = AlertViewController(title: String(localized: "Low Storage Space"), message: message) { context in
            context.addAction(title: String.LocalizationValue("Close")) { context.dispose() }
            context.addAction(title: String.LocalizationValue("Extract"), attribute: .accent) {
                context.dispose { extract() }
            }
        }
        presenter.present(alert, animated: true)
    }

    /// A new extraction folder does not exist yet. Ask the backend for the
    /// nearest existing ancestor, whose resolved volume will receive it.
    private func availableSpace(at destination: String) async throws -> Int64 {
        guard destination.hasPrefix("/") else { throw FilaFailure(code: .invalidRequest, path: destination) }
        var path = destination
        while true {
            do {
                return try await session.perform(retryOnDisconnect: true) { [path] in
                    try await $0.volumeInfo(for: path).availableByteCount
                }
            } catch let failure as FilaFailure where failure.systemError == ENOENT && path != "/" {
                path = (path as NSString).deletingLastPathComponent
            }
        }
    }
}
