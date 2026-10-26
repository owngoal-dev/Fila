import CArchiveLocale
import Darwin

/// libarchive converts UTF-8 names through the native locale even when its
/// UTF-8 entry APIs are used. The helper starts in C with an empty environment;
/// a failed conversion can give PAX a NULL pathname or ZIP a damaged name.
/// Scope the locale to each synchronous C call, preserving other app threads.
///
/// A locale that will not load is not a reason to lose the archive. `UTF-8` is
/// the name an iOS root actually carries — `/usr/lib/locale/UTF-8` is the only
/// entry there is — so it is tried first, and the spelled-out names are for the
/// systems where it is not. If none loads, the job runs in the locale the
/// process already has, which is what it had before this wrapper existed: an
/// archive that lists the user's files with a wrong conversion is worth more
/// than one that does not exist, and a failure here used to take the whole job
/// down with an errno that named nothing.
func withArchiveLocale<T>(_ body: () throws -> T) throws -> T {
    guard let locale = archiveLocale() else { return try body() }
    let previous = uselocale(locale)
    defer { uselocale(previous); freelocale(locale) }
    return try body()
}

private func archiveLocale() -> locale_t? {
    for name in ["UTF-8", "en_US.UTF-8", "C.UTF-8"] {
        if let locale = newlocale(LC_CTYPE_MASK, name, nil) {
            return locale
        }
    }
    return nil
}
