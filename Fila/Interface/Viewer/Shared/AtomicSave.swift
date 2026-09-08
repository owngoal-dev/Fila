import FilaClient
import FilaLog
import FilaProtocol
import Foundation

/// The only way an editor in this app writes a file.
///
/// Write a temporary beside the target, then ask the daemon to put it in place:
/// `replaceItem` carries the original's mode, owner, times, xattrs and BSD flags
/// across and `rename(2)`s, so a power cut during a save leaves either the old
/// file or the new one and never half of either. A half-written launchd plist is
/// a boot loop on a phone that cannot be booted into anything else.
///
/// The temporary is created `O_CREAT | O_EXCL` under a name nothing else would
/// pick, because an editor that can be raced into writing through a symlink an
/// attacker planted is an editor that writes anywhere as root.
///
/// Every editor here routes through this one function. There is deliberately no
/// second path and no `O_TRUNC` anywhere in the app: truncating over the
/// original destroys a file the user may have no copy of.
enum AtomicSave {
    static func write(_ data: Data, to path: String, link: DaemonLink) async throws {
        let directory = (path as NSString).deletingLastPathComponent
        let temporary = (directory as NSString)
            .appendingPathComponent(".fila-tmp-\(UUID().uuidString)")

        let file = try await DescriptorFile.open(
            temporary,
            flags: O_CREAT | O_EXCL | O_WRONLY,
            mode: 0o600,
            link: link
        )
        do {
            try file.write(data)
            file.close()
        } catch {
            file.close()
            await FileSession.shared.discardTemporary(temporary)
            throw error
        }

        do {
            try await link.replaceItem(at: path, withTemporary: temporary)
        } catch {
            await FileSession.shared.discardTemporary(temporary)
            throw error
        }
        // Every write an editor in this app makes, in the one place they all
        // go through. The byte count, never a byte: a save that "did nothing"
        // and a save of an empty document look identical from the outside.
        FilaLog.info("saved \(data.count) bytes to \(path)")
    }
}
