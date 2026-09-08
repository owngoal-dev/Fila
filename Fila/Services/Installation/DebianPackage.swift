import Darwin
import FilaFormats
import FilaProtocol
import Foundation

/// The identity of a `.deb`, read from its `control` member without unpacking
/// anything else. The outer archive is `ar`; `control` sits inside a
/// `control.tar.*` member, which is spilled to the app workspace so libarchive
/// can open it as a second archive — it reads descriptors, not memory.
enum DebianPackage {
    struct Manifest {
        var package: String
        var version: String
    }

    static func manifest(ofDebAt path: String, session: FileSession) async throws -> Manifest {
        let workspace = try await session.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let descriptor = try await session.perform(retryOnDisconnect: true) { try await $0.open(path, flags: O_RDONLY) }
        let fileName = (path as NSString).lastPathComponent
        let spill = workspace.appendingPathComponent("control.tar").path
        return try await Task.detached {
            defer { close(descriptor) }
            let notAPackage = ViewerFailure.unsupportedContent(
                String(localized: "“\(fileName)” is not a valid Debian package. Choose another file.")
            )
            let outer = try ArchiveReader(descriptor: descriptor)
            while let entry = try outer.next() {
                guard entry.declaredPath.hasPrefix("control.tar") else { continue }
                let out = open(spill, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard out >= 0 else { throw FilaFailure(code: .operationFailed, systemError: errno, path: spill) }
                do { _ = try outer.read(into: out, maximumByteCount: 16 * 1_024 * 1_024) }
                catch { close(out); throw error }
                close(out)
                let inner = open(spill, O_RDONLY)
                guard inner >= 0 else { throw FilaFailure(code: .operationFailed, systemError: errno, path: spill) }
                defer { close(inner) }
                let control = try ArchiveReader(descriptor: inner)
                while let member = try control.next() {
                    guard member.name == "control", !member.isDirectory else { continue }
                    let text = String(decoding: try control.data(maximumByteCount: 1 << 20), as: UTF8.self)
                    var fields: [String: String] = [:]
                    for line in text.split(separator: "\n") where !line.hasPrefix(" ") {
                        guard let colon = line.firstIndex(of: ":") else { continue }
                        fields[String(line[..<colon])] = line[line.index(after: colon)...]
                            .trimmingCharacters(in: .whitespaces)
                    }
                    guard let package = fields["Package"], !package.isEmpty else { throw notAPackage }
                    return Manifest(package: package, version: fields["Version"] ?? "")
                }
                throw notAPackage
            }
            throw notAPackage
        }.value
    }
}
