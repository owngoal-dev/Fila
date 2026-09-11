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
                try await FileImport.item(results[index].itemProvider, conformingTo: [.image], into: staging)()
            }
        }
    }

    private func importSelection(count: Int, prepare: @escaping @MainActor (Int, URL) async throws -> URL) {
        guard count > 0, !isTrash else { return }
        Task { await FileDelivery.importFiles(count: count, into: .local(directory), from: self, prepare: prepare) }
    }
}
