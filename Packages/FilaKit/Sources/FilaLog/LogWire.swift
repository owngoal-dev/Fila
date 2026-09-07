#if canImport(XPC)
import FilaProtocol
import XPC

/// How the daemon's lines reach the app.
///
/// **Polled, not streamed**, and that is the whole design decision here.
/// Streaming would mean one Mach message per line, sent whether or not anyone
/// is looking — and at verbose every XPC round trip writes a line, so a paste
/// of a large tree would push thousands of messages a second out of a process
/// launchd sizes at 6 MB, to be dropped on the floor by an app with no log
/// screen open. Polling costs the daemon exactly nothing until the screen
/// exists, which is the same bargain the daemon itself makes with launchd.
///
/// The ring makes polling lossless in the way that matters: it already holds
/// the history, so the first poll gets everything since the daemon started
/// rather than only what arrives from now on — which a stream would have had
/// to send as a backlog anyway. Poll faster than the ring wraps and nothing is
/// missed; when something is, `droppedCount` says so rather than the log
/// quietly having a hole in it.
///
/// One round trip does two jobs: the request carries the level the daemon
/// should capture at, so turning Verbose on in the app is live and immediate
/// and needs no second operation, no relaunch and no launch argument.
///
/// The whole ring is 128 KiB of frames, which encodes to a few hundred KB —
/// comfortably inside `FilaProtocol.maximumMessageByteCount`, so a reply is
/// never paged.
public extension FilaLog {
    /// The path a request or reply names, for a log line and nothing else.
    /// Both keys, because a rename and a replace carry the interesting one in
    /// `destination`.
    ///
    /// **Privacy: a path, and only a path.** The same dictionary carries an
    /// extended attribute's bytes on a `setAttributes`, and nothing here goes
    /// looking for them. One copy for both sides, so the rule cannot drift
    /// apart between the app's line and the daemon's.
    static func requestPath(_ message: xpc_object_t) -> String {
        let source = xpc_dictionary_get_string(message, FilaWireKey.path).map { String(cString: $0) }
        let destination = xpc_dictionary_get_string(message, FilaWireKey.destination).map { String(cString: $0) }
        switch (source, destination) {
        case let (path?, nil): return path
        case let (nil, path?): return path
        case let (from?, to?): return "\(from) → \(to)"
        case (nil, nil): return "-"
        }
    }
}

public extension FilaLog.Record {
    /// One-character keys: a reply carries a thousand of these.
    private enum Key {
        static let sequence = "q"
        static let time = "t"
        static let level = "v"
        static let source = "s"
        static let message = "m"
    }

    /// Fills a `fetchLog` request. `sequence` is the newest the caller already
    /// has; `level` is what the daemon should capture at from now on.
    static func encodeRequest(since sequence: UInt64, level: FilaLog.Level, into request: xpc_object_t) {
        xpc_dictionary_set_uint64(request, FilaWireKey.logCursor, sequence)
        xpc_dictionary_set_uint64(request, FilaWireKey.logLevel, UInt64(level.rawValue))
    }

    static func decodeRequest(_ request: xpc_object_t) -> (sequence: UInt64, level: FilaLog.Level?) {
        let level = xpc_dictionary_get_value(request, FilaWireKey.logLevel).flatMap { _ in
            FilaLog.Level(rawValue: UInt8(truncatingIfNeeded: xpc_dictionary_get_uint64(request, FilaWireKey.logLevel)))
        }
        return (xpc_dictionary_get_uint64(request, FilaWireKey.logCursor), level)
    }

    static func encodeReply(_ records: [FilaLog.Record], dropped: UInt64, into reply: xpc_object_t) {
        let array = xpc_array_create(nil, 0)
        for record in records {
            let entry = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(entry, Key.sequence, record.sequence)
            xpc_dictionary_set_double(entry, Key.time, record.time)
            xpc_dictionary_set_uint64(entry, Key.level, UInt64(record.level.rawValue))
            xpc_dictionary_set_uint64(entry, Key.source, UInt64(record.source.rawValue))
            xpc_dictionary_set_string(entry, Key.message, record.message)
            xpc_array_set_value(array, FilaXPC.arrayAppend, entry)
        }
        xpc_dictionary_set_value(reply, FilaWireKey.logRecords, array)
        xpc_dictionary_set_uint64(reply, FilaWireKey.logDropped, dropped)
    }

    static func decodeReply(_ reply: xpc_object_t) -> (records: [FilaLog.Record], dropped: UInt64) {
        var records: [FilaLog.Record] = []
        if let array = xpc_dictionary_get_array(reply, FilaWireKey.logRecords) {
            records.reserveCapacity(xpc_array_get_count(array))
            for index in 0 ..< xpc_array_get_count(array) {
                let entry = xpc_array_get_value(array, index)
                guard let message = xpc_dictionary_get_string(entry, Key.message) else { continue }
                records.append(FilaLog.Record(
                    sequence: xpc_dictionary_get_uint64(entry, Key.sequence),
                    time: xpc_dictionary_get_double(entry, Key.time),
                    level: FilaLog.Level(
                        rawValue: UInt8(truncatingIfNeeded: xpc_dictionary_get_uint64(entry, Key.level))
                    ) ?? .info,
                    // Whatever the daemon says it is. The viewer merges two
                    // processes onto one timeline and the tag is how a reader
                    // tells whose line they are looking at.
                    source: FilaLog.Source(
                        rawValue: UInt8(truncatingIfNeeded: xpc_dictionary_get_uint64(entry, Key.source))
                    ) ?? .daemon,
                    message: String(cString: message)
                ))
            }
        }
        return (records, xpc_dictionary_get_uint64(reply, FilaWireKey.logDropped))
    }
}
#endif
