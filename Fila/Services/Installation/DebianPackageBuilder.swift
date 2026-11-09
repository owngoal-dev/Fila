import Darwin
import FilaFormats
import FilaProtocol
import Foundation

/// Assembles a `.deb` from a folder that already holds the three members of
/// one — what *Extract* leaves behind: `debian-binary`, `control.tar.*` and
/// `data.tar.*`.
///
/// `data.tar.*` is copied byte for byte. That is not laziness: those members
/// are the binaries the package installs, with their ad-hoc signatures and
/// permission bits, and repacking them means re-signing every Mach-O inside or
/// the device kills the app at launch. Nothing here touches them, so what comes
/// out installs exactly what went in.
///
/// `control.tar.*` is rewritten only where the caller changes something
/// (`Architecture`, `Version`); otherwise its bytes are copied as they are.
enum DebianPackageBuilder {
    /// The three members, by path.
    struct Layout {
        var binary: String
        var control: String
        var data: String
    }

    /// The architecture label a package carries. It names the bootstrap layout
    /// the package installs into; it does not move anything inside the payload
    /// (`/var/jb` against rootful paths), which stays the packager's business.
    enum Architecture: String, CaseIterable, Sendable {
        case arm64 = "iphoneos-arm64"
        case arm64e = "iphoneos-arm64e"

        var title: String {
            switch self {
            case .arm64e: "arm64e"
            case .arm64: "arm64"
            }
        }

        /// `iphoneos-arm64e`, `iphoneos-arm64`, or nil for a label that names
        /// neither layout.
        init(label: String) {
            self = label.hasSuffix("arm64e") ? .arm64e : .arm64
        }

        init?(field: String) {
            if let known = Architecture(rawValue: field) {
                self = known
            } else if field.hasSuffix("arm64e") {
                self = .arm64e
            } else if field.hasSuffix("arm64") {
                self = .arm64
            } else {
                return nil
            }
        }
    }

    struct Request {
        var layout: Layout
        var architecture: Architecture
        var version: String
        var destination: String
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    // MARK: - Look at a folder

    /// The members of a `.deb` layout in `directory`, by name alone: this runs
    /// while a menu is being built, so it reads no headers.
    ///
    /// `control.tar.*` and `data.tar.*` take the compressions dpkg accepts; a
    /// folder with two of either is refused rather than guessed at.
    static func layout(in directory: String, names: [String]) throws -> Layout {
        func pick(_ prefix: String) throws -> String {
            let matches = names.filter { $0 == prefix || $0.hasPrefix(prefix + ".") }
            guard matches.count == 1, let name = matches.first else {
                throw Failure(message: String(
                    localized: "This folder has \(matches.count) “\(prefix)” members. A package needs exactly one.",
                ))
            }
            return (directory as NSString).appendingPathComponent(name)
        }
        return Layout(
            binary: try pick("debian-binary"),
            control: try pick("control.tar"),
            data: try pick("data.tar"),
        )
    }

    /// The label the package's own `control` declares — what dpkg will compare
    /// against the device. Reading it costs one small member, so the menu can
    /// offer the choice that is actually right instead of letting a person pick
    /// a wrong one and find out at install time.
    static func declaredArchitecture(of layout: Layout, session: FileSession) async throws -> Architecture? {
        guard let text = try await controlText(of: layout, session: session) else { return nil }
        let fields = try ControlFields(text: text)
        guard let label = fields.value(of: "Architecture") else { return nil }
        return Architecture(field: label)
    }

    // MARK: - Build

    /// Writes `request.destination` and nothing else. The archive is staged
    /// beside it under a temporary name and renamed into place once complete,
    /// so a cancelled or failed build never leaves something that looks like a
    /// package and is not one.
    static func build(_ request: Request, session: FileSession, progress: @escaping @Sendable (String) -> Void) async throws {
        let layout = request.layout
        let workspace = try await session.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        // 1. `debian-binary` is the format's version and nothing else.
        let archive = try await readMember(layout.binary, session: session)
        guard archive == Data("2.0\n".utf8) else {
            throw Failure(message: String(localized: "“debian-binary” does not say 2.0, so this is not a package layout."))
        }

        // 2. The package's own `control` decides which label it may carry.
        //    Its binaries cannot: one version ships the same three fat
        //    libraries and the same arm64-only helper in both the arm64 and the
        //    arm64e package, and the only difference between them is this field
        //    and the prefix on every payload path.
        progress(String(localized: "Reading the package metadata"))
        let control = try await readControlTar(layout, session: session)
        var fields = try ControlFields(text: control.text)
        if let declared = fields.value(of: "Architecture").flatMap(Architecture.init(field:)),
           declared != request.architecture {
            throw Failure(message: String(localized: "This package is \(declared.title), which is not supported."))
        }
        fields.set("Architecture", request.architecture.rawValue)
        if !request.version.isEmpty { fields.set("Version", request.version) }
        let rewritten = try rewrite(
            control,
            text: fields.text,
            compression: Self.compression(for: layout.control),
            workspace: workspace,
        )
        defer { try? FileManager.default.removeItem(at: rewritten) }

        // 4. The ar container, written beside its destination and renamed onto
        // it only once every member is in.
        let parent = (request.destination as NSString).deletingLastPathComponent
        let staging = (parent as NSString).appendingPathComponent(".fila-deb-\(UUID().uuidString)")
        let destination = try await session.perform {
            try await $0.open(staging, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o600)
        }
        do {
            progress(String(localized: "Writing the package"))
            try await writeContainer(
                layout: layout,
                controlTar: rewritten,
                archive: archive,
                to: destination,
                session: session,
                progress: progress,
            )
            close(destination)
            _ = try await session.perform { access in
                let outcome = try await access.setAttributes(.newItemDefaults, at: staging)
                try await access.rename(staging, to: request.destination, exclusive: true, overrideGuard: false)
                return outcome
            }
        } catch {
            close(destination)
            _ = try? await session.perform {
                try await $0.remove(staging, directory: false, overrideGuard: false)
            }
            throw error
        }
    }

    /// Streams the three members into an `ar`: the four bytes of
    /// `debian-binary`, the control tar that was just written, then the payload
    /// from the descriptor it already lives at.
    private static func writeContainer(
        layout: Layout,
        controlTar: URL,
        archive: Data,
        to destination: Int32,
        session: FileSession,
        progress: @escaping @Sendable (String) -> Void,
    ) async throws {
        let writer = try ArWriter(descriptor: destination)
        try writer.addMember(name: "debian-binary", data: archive, mode: 0o100644)

        let control = open(controlTar.path, O_RDONLY)
        guard control >= 0 else {
            throw FilaFailure(code: .operationFailed, systemError: errno, path: controlTar.path)
        }
        defer { close(control) }
        var status = stat()
        guard fstat(control, &status) == 0 else { throw FilaFailure(errno: errno, path: controlTar.path) }
        try writer.addMember(
            name: (layout.control as NSString).lastPathComponent,
            source: control,
            byteCount: Int64(status.st_size),
        )

        progress(String(localized: "Copying the payload"))
        let data = try await session.perform { try await $0.open(layout.data, flags: O_RDONLY) }
        defer { close(data) }
        guard fstat(data, &status) == 0 else { throw FilaFailure(errno: errno, path: layout.data) }
        try writer.addMember(
            name: (layout.data as NSString).lastPathComponent,
            source: data,
            byteCount: Int64(status.st_size),
        )
    }

    // MARK: - control.tar

    private struct ControlTar {
        var members: [Member]
        var text: String
        var controlPath: String

        struct Member {
            var path: String
            var kind: FileKind
            var mode: mode_t
            var modified: Date
            var linkTarget: String?
            var bytes: Data
        }
    }

    /// The text of the `control` member, or nil when the archive has none.
    private static func controlText(of layout: Layout, session: FileSession) async throws -> String? {
        let descriptor = try await session.perform { try await $0.open(layout.control, flags: O_RDONLY) }
        defer { close(descriptor) }
        let reader = try ArchiveReader(descriptor: descriptor)
        while let entry = try reader.next() {
            guard entry.name == "control", entry.kind == .regular else { continue }
            let text = try reader.data(maximumByteCount: 1 << 20)
            return String(decoding: text, as: UTF8.self)
        }
        return nil
    }

    private static func readControlTar(_ layout: Layout, session: FileSession) async throws -> ControlTar {
        let descriptor = try await session.perform { try await $0.open(layout.control, flags: O_RDONLY) }
        defer { close(descriptor) }
        let reader = try ArchiveReader(descriptor: descriptor)
        var members: [ControlTar.Member] = []
        var text: String?
        var controlPath: String?
        while let entry = try reader.next() {
            if entry.isDirectory { continue }
            let bytes: Data = entry.kind == .regular
                ? try reader.data(maximumByteCount: 16 * 1024 * 1024)
                : Data()
            if entry.name == "control", entry.kind == .regular {
                text = String(decoding: bytes, as: UTF8.self)
                controlPath = entry.declaredPath
            }
            members.append(ControlTar.Member(
                path: entry.declaredPath,
                kind: entry.kind,
                mode: entry.mode,
                modified: entry.modified ?? Date(),
                linkTarget: entry.linkTarget,
                bytes: bytes,
            ))
            guard members.count <= 512 else {
                throw Failure(message: String(localized: "The control archive holds too many members."))
            }
        }
        guard let text, let controlPath else {
            throw Failure(message: String(localized: "The control archive has no “control” file."))
        }
        return ControlTar(members: members, text: text, controlPath: controlPath)
    }

    private static func rewrite(
        _ controlTar: ControlTar,
        text: String,
        compression: ArchiveFormat,
        workspace: URL,
    ) throws -> URL {
        let url = workspace.appendingPathComponent("control." + compression.filenameExtension)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw FilaFailure(code: .operationFailed, systemError: errno, path: url.path)
        }
        defer { close(descriptor) }
        try writeControlTar(controlTar, text: text, format: compression, to: descriptor)
        return url
    }

    /// The one place a `control.tar` is written, so the member names, modes and
    /// the replacement of `control` cannot drift between *pack* and *save*.
    private static func writeControlTar(
        _ controlTar: ControlTar,
        text: String,
        format: ArchiveFormat,
        to descriptor: Int32,
    ) throws {
        let writer = try ArchiveWriter(descriptor: descriptor, format: format)
        for member in controlTar.members {
            if member.path == controlTar.controlPath {
                try writer.addData(member.path, Data(text.utf8), mode: member.mode, modified: member.modified)
            } else if let target = member.linkTarget {
                try writer.addSymbolicLink(member.path, target: target, mode: member.mode, modified: member.modified)
            } else {
                try writer.addData(member.path, member.bytes, mode: member.mode, modified: member.modified)
            }
        }
        try writer.finish()
    }

    // MARK: - The editor

    /// The `control` text as the editor shows it.
    static func controlText(in layout: Layout, session: FileSession) async throws -> String {
        guard let text = try await controlText(of: layout, session: session) else {
            throw Failure(message: String(localized: "The control archive has no “control” file."))
        }
        return text
    }

    /// A text that may be written as a package's `control` file: dpkg needs the
    /// three fields that decide identity and layout, and a control file without
    /// them is a package that installs as something else.
    static func validated(_ text: String) throws -> String {
        let fields = try ControlFields(text: text)
        for field in ["Package", "Version", "Architecture"] where fields.value(of: field) == nil {
            throw Failure(message: String(localized: "The control file needs a \(field) field."))
        }
        return fields.text
    }

    /// Replaces the `control` member inside `layout.control` itself, keeping the
    /// archive's compression, its other members and their bytes.
    ///
    /// Written to a temporary beside it and put in place with `replaceItem`,
    /// which carries the original's metadata across: a save that fails half way
    /// leaves the file the user had.
    static func saveControl(_ text: String, in layout: Layout, session: FileSession) async throws {
        let text = try validated(text)
        let control = try await readControlTar(layout, session: session)
        let parent = (layout.control as NSString).deletingLastPathComponent
        let staging = (parent as NSString).appendingPathComponent(".fila-control-\(UUID().uuidString)")
        let descriptor = try await session.perform {
            try await $0.open(staging, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o600)
        }
        var closed = false
        do {
            try writeControlTar(
                control,
                text: text,
                format: Self.compression(for: layout.control),
                to: descriptor,
            )
            close(descriptor)
            closed = true
            _ = try await session.perform {
                let outcome = try await $0.setAttributes(.newItemDefaults, at: staging)
                try await $0.replaceItem(at: layout.control, withTemporary: staging)
                return outcome
            }
        } catch {
            if !closed { close(descriptor) }
            _ = try? await session.perform {
                try await $0.remove(staging, directory: false, overrideGuard: false)
            }
            throw error
        }
    }

    private static func compression(for path: String) -> ArchiveFormat {
        switch (path as NSString).pathExtension {
        case "gz": .tarGzip
        case "bz2": .tarBzip2
        case "xz": .tarXz
        case "lzma": .tarLzma
        case "zst", "zstd": .tarZstd
        case "lz": .tarLzip
        case "lz4": .tarLz4
        default: .tar
        }
    }

    private static func readMember(_ path: String, session: FileSession) async throws -> Data {
        let descriptor = try await session.perform { try await $0.open(path, flags: O_RDONLY) }
        defer { close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = read(descriptor, &bytes, bytes.count)
        guard count >= 0 else { throw FilaFailure(errno: errno, path: path) }
        return Data(bytes[0 ..< count])
    }
}

/// The `control` file as fields, kept in the order they were read: dpkg does
/// not care about the order, but a person editing the same file again does, and
/// a rewritten package should be a diff of exactly what changed.
struct ControlFields {
    private(set) var lines: [String]

    init(text: String) throws {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.contains(where: { $0.hasPrefix("Package:") }) else {
            throw DebianPackageBuilder.Failure(message: String(localized: "The control file has no “Package” field."))
        }
        self.lines = lines
    }

    var text: String { lines.joined(separator: "\n") + "\n" }

    func value(of field: String) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix(field + ":") }) else { return nil }
        return line.dropFirst(field.count + 1).trimmingCharacters(in: .whitespaces)
    }

    mutating func set(_ field: String, _ value: String) {
        if let index = lines.firstIndex(where: { $0.hasPrefix(field + ":") }) {
            lines[index] = "\(field): \(value)"
        } else {
            lines.append("\(field): \(value)")
        }
    }
}
