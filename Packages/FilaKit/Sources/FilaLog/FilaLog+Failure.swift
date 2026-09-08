import FilaProtocol

public extension FilaLog {
    /// How a refusal reads in a line: the code's own word, then the `errno`.
    ///
    /// **The number is the answer to "it wouldn't delete."** As root, `EPERM`
    /// is almost always an immutable BSD flag and nothing but the errno says
    /// so, which is why every line that carries a failure carries the number
    /// with it.
    ///
    /// One copy, because the daemon's reply line, the job's outcome line and
    /// the app's operation line all say the same thing about the same failure.
    /// Two spellings of one refusal means a log nobody can grep.
    static func describe(_ failure: FilaFailure) -> String {
        var line = failure.code.name
        if failure.systemError != 0 {
            line += " errno \(failure.systemError) \(failure.systemErrorDescription ?? "")"
        }
        // The recovery a caller cannot infer from the errno — "same location",
        // "inside source" — is the whole reason `FilaFailureReason` exists, so
        // a line that omits it hides the only part that explains the refusal.
        if let reason = failure.reason {
            line += " \(reason.rawValue)"
        }
        return line
    }

    /// A refusal is not automatically trouble. `notFound` is what a `stat` of a
    /// path the user just deleted answers, and `cancelled` is the user's own
    /// doing; logging either as an error would bury the ones that matter.
    static func level(for code: FilaReplyCode) -> Level {
        switch code {
        case .success: .info
        case .notFound, .cancelled: .verbose
        case .protectedPath, .notPermitted, .invalidRequest, .wrongPassword: .warning
        case .operationFailed: .error
        }
    }
}
