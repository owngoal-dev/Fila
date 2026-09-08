#if canImport(XPC)
    @testable import FilaProtocol
    import Foundation
    import Testing
    import XPC

    @Suite("Archive jobs on the wire")
    struct ArchiveWireTests {
        @Test("Extraction organization survives the app, daemon and helper transports",
              arguments: [nil, false, true] as [Bool?])
        func extractionOrganization(organized: Bool?) throws {
            let request = JobRequest(
                kind: .extract,
                sources: ["/private/var/mobile/歌曲.zip"],
                destination: "/private/var/mobile",
                archive: ArchiveOptions(organizeExtraction: organized)
            )
            let message = xpc_dictionary_create(nil, nil, 0)
            request.encode(into: message)
            let daemonRequest = try #require(JobRequest(decoding: message))
            #expect(daemonRequest == request)
            let helperRequest = try JSONDecoder().decode(
                JobRequest.self, from: JSONEncoder().encode(daemonRequest)
            )
            #expect(helperRequest == request)
        }
    }
#endif
