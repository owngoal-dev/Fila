import Foundation
import LibArchive

/// libarchive's own message, carried through rather than flattened into
/// something this module made up. *Truncated ZIP file data* and *Unsupported ZIP
/// compression method (Deflate64)* are different problems and only one of them
/// means the file is broken, which is the whole of the sorting done here.
///
/// `.notRecognised` is deliberately not produced here. libarchive decides which
/// format an archive is inside `archive_read_next_header`, not at open, and with
/// `support_format_raw` enabled *something* always bids — so "this is not an
/// archive" has exactly one owner, `refuseABareRawMember`, and it is not this.
func archiveFailure(_ handle: OpaquePointer) -> FormatFailure {
    let code = archive_errno(handle)
    if code == ENOSPC {
        return .system(errno: code)
    }
    guard let raw = archive_error_string(handle), let message = String(validatingUTF8: raw) else {
        return .system(errno: code == 0 ? EIO : code)
    }
    // The only signal the library gives for "the file is fine, I just cannot do
    // this one" is that those messages start *Unsupported* or *Unrecognized*. If
    // the wording ever changes the user gets the damaged sentence with the true
    // reason still attached, which is a soft landing.
    if message.hasPrefix("Unsupported") || message.hasPrefix("Unrecogni") {
        return .unsupported(message)
    }
    // "Passphrase required for this entry" and "Incorrect passphrase" are the
    // two ways the zip reader says it, and both have the same way out.
    if message.localizedCaseInsensitiveContains("passphrase") {
        return .wrongPassword
    }
    return .damaged(message)
}
