import FilaFileOps
import FilaProtocol
import UIKit
import UniformTypeIdentifiers

/// Saves only user-selected file representations into the shared Inbox.
/// No daemon connection or private entitlements are used by this extension.
final class SaveActionViewController: UIViewController {
    private var started = false
    private let status = UILabel()
    private let done = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.text = String(localized: "Saving to Fila…")
        status.font = .preferredFont(forTextStyle: .body)
        status.numberOfLines = 0
        status.textAlignment = .center
        done.setTitle(String(localized: "Done"), for: .normal)
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)
        done.isHidden = true
        let stack = UIStackView(arrangedSubviews: [status, done])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            done.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { [weak self] in
            do {
                guard !providers.isEmpty else { throw POSIXError(.EINVAL) }
                for provider in providers {
                    try await Self.save(provider)
                }
                self?.status.text = String(localized: "Saved to Fila’s Inbox. Open Fila to view or move the files.")
            } catch {
                self?.status.text = String(localized: "Unable to Save All Files") + "\n\n" + error.localizedDescription
            }
            self?.done.isHidden = false
        }
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private static func save(_ provider: NSItemProvider) async throws {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "FilaAppGroupIdentifier") as? String,
              let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier),
              let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true })
        else { throw POSIXError(.EINVAL) }
        // The provider's URL is valid only inside this callback. Publish the
        // copy before returning; never retain the temporary URL for later.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    guard let url else { throw error ?? POSIXError(.EIO) }
                    let inbox = try SharedInbox.directory(in: group)
                    try SharedInbox.save(url, suggestedName: provider.suggestedName, in: inbox)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
