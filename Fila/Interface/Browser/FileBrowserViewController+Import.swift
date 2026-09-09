import AlertController
import FilaBackendUI
import FilaProtocol
import PhotosUI
import Then
import UIKit
import UniformTypeIdentifiers

extension FileBrowserViewController: UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    func importDocuments() {
        guard !isTrash else { return }
        recordDirectoryUse()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true).then {
            $0.delegate = self
            $0.allowsMultipleSelection = true
        }
        anchor(picker, to: view)
        present(picker, animated: true)
    }

    func importPhotos() {
        guard !isTrash else { return }
        recordDirectoryUse()
        // A standalone PHPicker needs neither PhotoKit authorization nor an
        // Info.plist photo-library usage description.
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        controller.dismiss(animated: true) { [self] in
            importSelection(count: urls.count) { index, staging in
                try await FileImport.document(urls[index], into: staging)
            }
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) { [self] in
            importSelection(count: results.count) { index, staging in
                try await FileImport.photo(results[index].itemProvider, into: staging)
            }
        }
    }

    private func importSelection(count: Int, prepare: @escaping (Int, URL) async throws -> URL) {
        guard count > 0, !isTrash else { return }
        Task {
            do {
                // Import one at a time so identical names in the selection use
                // the same replacement choice as a collision on disk.
                for index in 0 ..< count {
                    let staging = try await session.makeTemporaryDirectory()
                    do {
                        let file = try await prepareImport { try await prepare(index, staging) }
                        let outcome = try await performTransfer(
                            JobRequest(kind: .copy, sources: [file.path], destination: directory)
                        )
                        if outcome.code != .success {
                            throw outcome
                        }
                    } catch {
                        try FileManager.default.removeItem(at: staging)
                        throw error
                    }
                    try FileManager.default.removeItem(at: staging)
                }
            } catch {
                if (error as? FilaFailure)?.code == .cancelled || error is CancellationError {
                    return
                }
                let message = FailureMessage.text(for: error)
                guard viewIfLoaded?.window != nil, presentedViewController == nil else {
                    FeedbackAlert.show(String(localized: "Import Failed"), message: message)
                    return
                }
                let alert = AlertViewController(
                    title: String(localized: "Import Failed"),
                    message: message
                ) { context in
                    context.allowSimpleDispose()
                    context.addAction(title: String.LocalizationValue("OK"), attribute: .accent) { context.dispose() }
                }
                present(alert, animated: true)
            }
        }
    }

    private func prepareImport(_ body: () async throws -> URL) async throws -> URL {
        let progress = AlertProgressIndicatorViewController(
            title: String.LocalizationValue("Preparing…"),
            message: String.LocalizationValue("Loading the selected file for import.")
        )
        let reveal = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(StatusView.revealDelay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled, viewIfLoaded?.window != nil, presentedViewController == nil else { return }
            await withCheckedContinuation { continuation in
                present(progress, animated: true) { continuation.resume() }
            }
        }
        let result: Result<URL, Error>
        do { result = try await .success(body()) }
        catch { result = .failure(error) }
        reveal.cancel()
        await reveal.value
        if progress.presentingViewController != nil, !progress.isBeingDismissed {
            await withCheckedContinuation { continuation in
                progress.dismiss(animated: true) { continuation.resume() }
            }
        }
        return try result.get()
    }
}
