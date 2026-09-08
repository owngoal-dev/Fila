import CArchiveLocale
import Darwin

/// libarchive converts UTF-8 names through the native locale even when its
/// UTF-8 entry APIs are used. The helper starts in C with an empty environment;
/// a failed conversion can give PAX a NULL pathname or ZIP a damaged name.
/// Scope the locale to each synchronous C call, preserving other app threads.
func withArchiveLocale<T>(_ body: () throws -> T) throws -> T {
    guard let locale = newlocale(LC_CTYPE_MASK, "UTF-8", nil) else {
        throw FormatFailure.system(errno: errno)
    }
    let previous = uselocale(locale)
    defer { uselocale(previous); freelocale(locale) }
    return try body()
}
