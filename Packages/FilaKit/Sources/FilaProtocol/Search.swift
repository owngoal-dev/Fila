import Foundation

/// What a search job is looking for.
///
/// Names only. Searching *inside* files is a different operation with a
/// different cost model — it has to read every candidate — and the daemon is
/// forbidden from reading file bytes at all, so when it arrives it will run in
/// the app over descriptors this walk's results were opened with.
public struct SearchQuery: Sendable, Hashable, Codable {
    /// A substring by default, an `fnmatch(3)` pattern when `isGlob` is set.
    public var text: String

    /// Off by default: someone typing `info` means to find `Info.plist`.
    ///
    /// The insensitive comparison is `strcasestr(3)`/`FNM_CASEFOLD`, which fold
    /// ASCII and nothing else. Folding Unicode properly would mean building a
    /// Swift `String` for every entry on the device, which is the allocation
    /// the walk exists to avoid — so `Ä` matches `Ä` and not `ä`, and a user
    /// who needs that turns the switch on and types it exactly.
    public var isCaseSensitive: Bool

    /// Whether dot-prefixed entries are searched.
    ///
    /// When false they are skipped as matches *and* as branches: a search that
    /// excluded hidden files but still walked into the trash would not be what
    /// the switch says. Hidden here means the dot prefix alone, not the BSD
    /// `UF_HIDDEN` flag `FileNode.isHidden` also honours — reading that would
    /// cost an `fstatat` on every entry.
    public var includesHidden: Bool

    /// Match `text` as a shell glob against the whole name (`*.plist`) instead
    /// of as a substring anywhere inside it.
    public var isGlob: Bool

    public init(text: String, isCaseSensitive: Bool = false, includesHidden: Bool = false, isGlob: Bool = false) {
        self.text = text
        self.isCaseSensitive = isCaseSensitive
        self.includesHidden = includesHidden
        self.isGlob = isGlob
    }
}

/// One entry a search found.
///
/// A `FileNode` deliberately carries no path — a directory page repeats the
/// directory 512 times otherwise — so a match has to say where it was found.
public struct SearchMatch: Sendable, Hashable {
    /// The canonical directory the entry lives in.
    public var directory: String
    public var node: FileNode

    public init(directory: String, node: FileNode) {
        self.directory = directory
        self.node = node
    }

    public var path: String { directory == "/" ? "/" + node.name : directory + "/" + node.name }
}

/// The ways a search can stop short of walking everything it was given.
///
/// A set rather than one reason, because a walk of `/` can hit all three. Its
/// whole purpose is that a truncated result list never looks like a complete
/// one: every limit here is a case where the honest answer is "there may be
/// more", and silence would be a lie the user cannot detect.
public struct SearchLimits: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// `FilaProtocol.searchResultLimit` matches were reported and the walk
    /// stopped there. There are more.
    public static let resultCount = SearchLimits(rawValue: 1 << 0)

    /// A branch was deeper than `FilaProtocol.searchDepthLimit` and was not
    /// descended into. Everything shallower was searched.
    public static let depth = SearchLimits(rawValue: 1 << 1)

    /// At least one directory could not be opened or read through — mode 000,
    /// a bad block, or something that went away mid-walk — and was skipped. The
    /// rest of the tree was searched.
    public static let unreadable = SearchLimits(rawValue: 1 << 2)
}

/// One `searchResult` message: matches found since the last one, and whatever
/// the walk has run into so far.
public struct SearchBatch: Sendable, Hashable {
    /// At most `FilaProtocol.searchBatchMatchCount`, and empty in the last
    /// batch of a search that ended on a round number.
    public var matches: [SearchMatch]

    /// Sticky: once the walk reports a limit it repeats it on every later
    /// batch, and a final batch always goes out, so a client that reads the
    /// limits off the last message it received is never wrong about them.
    public var limits: SearchLimits

    public init(matches: [SearchMatch], limits: SearchLimits = []) {
        self.matches = matches
        self.limits = limits
    }
}
