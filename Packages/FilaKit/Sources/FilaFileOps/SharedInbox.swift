import Darwin
import FilaProtocol
import Foundation

/// User-selected imports shared by the app and its Save to Fila action.
public enum SharedInbox {
    public static func directory(in group: URL) throws -> URL {
        let group = try FilaPath.resolve(group.path)
        let inbox = URL(fileURLWithPath: group).appendingPathComponent("Inbox", isDirectory: true)
        let operations = FileOperations(bootstrapRoot: group)
        var status = stat()
        if lstat(inbox.path, &status) != 0 {
            guard errno == ENOENT else { throw FilaFailure(errno: errno) }
            do { try operations.create(.directory, at: inbox.path, mode: 0o700) }
            catch let error as FilaFailure where error.systemError == EEXIST {}
        }
        guard lstat(inbox.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw FilaFailure(errno: EINVAL)
        }
        return inbox
    }

    /// Exclusive atomic copies preserve existing names and never alter the source.
    @discardableResult
    public static func save(_ source: URL, suggestedName: String?, in inbox: URL) throws -> URL {
        var status = stat()
        guard lstat(inbox.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw FilaFailure(errno: EINVAL)
        }
        var name = (suggestedName ?? source.lastPathComponent) as NSString
        guard name.lastPathComponent == name as String, name.length > 0,
              name as String != ".", name as String != "..", !(name as String).utf8.contains(0)
        else {
            throw FilaFailure(errno: EINVAL)
        }
        if name.pathExtension.isEmpty, !source.pathExtension.isEmpty {
            name = ((name as String) + "." + source.pathExtension) as NSString
        }
        let operations = FileOperations(bootstrapRoot: inbox.path)
        for index in 0 ..< 1000 {
            let suffix = name.pathExtension.isEmpty ? "" : "." + name.pathExtension
            let candidate = index == 0 ? name as String : "\(name.deletingPathExtension) (\(index))\(suffix)"
            let destination = inbox.appendingPathComponent(candidate)
            if lstat(destination.path, &status) == 0 {
                continue
            }
            guard errno == ENOENT else { throw FilaFailure(errno: errno) }
            do {
                try operations.copyRegularFile(at: source.path, to: destination.path)
                return destination
            } catch let error as FilaFailure where error.systemError == EEXIST { continue }
        }
        throw FilaFailure(errno: EEXIST)
    }
}
