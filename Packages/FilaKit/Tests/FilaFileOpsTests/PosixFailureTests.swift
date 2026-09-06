import Darwin
import Foundation
import Testing

@testable import FilaFileOps
@testable import FilaProtocol

@Suite("errno to reply code")
struct PosixFailureTests {
    @Test("Only the codes a client behaves differently for are distinct")
    func mapping() {
        #expect(FilaFailure(errno: ENOENT).code == .notFound)
        #expect(FilaFailure(errno: EACCES).code == .notPermitted)
        #expect(FilaFailure(errno: EPERM).code == .notPermitted)
        #expect(FilaFailure(errno: ECANCELED).code == .cancelled)
        #expect(FilaFailure(errno: EEXIST).code == .operationFailed)
        #expect(FilaFailure(errno: EEXIST).systemError == EEXIST)
    }

    @Test("The system message survives for the user to read")
    func message() {
        #expect(FilaFailure(errno: EEXIST).systemErrorDescription == String(cString: strerror(EEXIST)))
        #expect(FilaFailure(code: .protectedPath).systemErrorDescription == nil)
    }
}
