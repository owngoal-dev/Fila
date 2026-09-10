import FilaFileOps
import FilaProtocol
import SnapKit
import Then
import UIKit
import UniformTypeIdentifiers

/// Saves only user-selected file representations into the shared Inbox.
/// No daemon connection or private entitlements are used by this extension.
final class SaveActionViewController: UIViewController {
    private var started = false
    private let status = UILabel()
    private let done = UIButton(type: .system)
    private let activity = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.do {
            $0.text = String(localized: "Saving to Fila…")
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.numberOfLines = 0
            $0.textAlignment = .center
        }
        done.do {
            $0.setTitle(String(localized: "Done"), for: .normal)
            $0.addTarget(self, action: #selector(finish), for: .touchUpInside)
            $0.isHidden = true
        }
        let title = UILabel().then {
            $0.text = String(localized: "Save to Fila")
            $0.font = .preferredFont(forTextStyle: .title2)
            $0.adjustsFontForContentSizeCategory = true
            $0.textAlignment = .center
        }
        activity.startAnimating()
        let stack = UIStackView(arrangedSubviews: [title, activity, status, done]).then {
            $0.axis = .vertical
            $0.spacing = 20
        }
        view.addSubview(stack)
        stack.snp.makeConstraints {
            $0.leading.trailing.equalTo(view.layoutMarginsGuide)
            $0.centerY.equalToSuperview()
        }
        done.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { [weak self] in
            var saved = 0
            do {
                guard !providers.isEmpty, providers.count <= 100 else { throw POSIXError(.EINVAL) }
                for provider in providers {
                    try await Self.save(provider)
                    saved += 1
                }
                self?.status.text = String(localized: "Saved to Fila’s Inbox. Open Fila to view or move the files.")
            } catch {
                self?.status.text = String(localized: "Unable to save all files. Open Fila to view any that were saved.") + "\n"
                    + String(localized: "Saved \(saved) of \(providers.count) files to Fila’s Inbox.")
                    + "\n\n" + error.localizedDescription
            }
            self?.activity.stopAnimating()
            self?.done.isHidden = false
        }
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private static func save(_ provider: NSItemProvider) async throws {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "FilaAppGroupIdentifier") as? String,
              let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else { throw POSIXError(.EINVAL) }
        let type = provider.registeredTypeIdentifiers.first { candidate in
            guard let type = UTType(candidate) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .url)
        }
        // Read off the provider here: the callback runs on the provider's own
        // queue, and NSItemProvider is not Sendable.
        let suggestedName = provider.suggestedName
        // Provider URLs live only for the callback. Copy before it returns.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            @Sendable func receive(_ url: URL?, _ error: Error?) {
                do {
                    guard let url, url.isFileURL else { throw error ?? POSIXError(.EINVAL) }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if scoped {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    let inbox = try SharedInbox.directory(in: group)
                    try SharedInbox.save(url, suggestedName: suggestedName, in: inbox)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
            if let type {
                provider.loadFileRepresentation(forTypeIdentifier: type, completionHandler: receive)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    receive(item as? URL, error)
                }
            } else {
                continuation.resume(throwing: POSIXError(.ENOTSUP))
            }
        }
    }
}
