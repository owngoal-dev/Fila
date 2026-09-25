@testable import FilaProtocol
import Foundation
import Testing
#if canImport(XPC)
    import XPC
#endif

struct FailureWireTests {
    @Test(arguments: FilaFailureReason.allCases)
    func `Detailed transfer refusals survive helper JSON`(_ reason: FilaFailureReason) throws {
        let failure = FilaFailure(code: .invalidRequest, systemError: EINVAL, path: "/source", reason: reason)
        #expect(try JSONDecoder().decode(FilaFailure.self, from: JSONEncoder().encode(failure)) == failure)
    }

    @Test
    func `Failures from an older helper have no detailed reason`() throws {
        let failure = FilaFailure(code: .invalidRequest, systemError: EINVAL)
        let encoded = try JSONEncoder().encode(failure)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["reason"] == nil)
        #expect(try JSONDecoder().decode(FilaFailure.self, from: encoded) == failure)
    }

    #if canImport(XPC)
        @Test(arguments: FilaFailureReason.allCases)
        func `Detailed transfer refusals survive replies and job events`(_ reason: FilaFailureReason) throws {
            let failure = FilaFailure(code: .invalidRequest, systemError: EINVAL, path: "/source", reason: reason)
            let reply = xpc_dictionary_create(nil, nil, 0)
            failure.encode(into: reply)
            #expect(FilaFailure.decode(reply) == failure)
            let event = JobEvent.completed(failure).encoded(jobIdentifier: 42)
            let decoded = try #require(JobEvent.decode(event))
            guard case let .completed(result) = decoded.event else { Issue.record("Expected a completed job"); return }
            #expect(result == failure)
            #expect(decoded.jobIdentifier == 42)
        }
    #endif
}
