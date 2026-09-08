import Foundation
import Testing
@testable import swift_mail

/// Serves a canned SSE body to the real `URLSession.bytes(for:)` path, so these
/// exercise `JMAPEventSource.events()` itself — the byte framing included —
/// rather than a stand-in for it.
private final class StubSSEProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serialized: the stub's canned body is shared static state, and Swift Testing
/// runs cases in parallel by default. `@MainActor` because the app target
/// defaults to main-actor isolation, which `JMAPEventSource` inherits.
@Suite(.serialized)
@MainActor
struct JMAPEventSourceTests {
    private func changes(from payload: String, statusCode: Int = 200) async throws -> [JMAPStateChange] {
        StubSSEProtocol.body = Data(payload.utf8)
        StubSSEProtocol.statusCode = statusCode

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSSEProtocol.self]

        let source = JMAPEventSource(
            url: URL(string: "https://example.com/events")!,
            bearerToken: "token",
            urlSession: URLSession(configuration: configuration)
        )

        var received: [JMAPStateChange] = []
        for try await change in source.events() {
            received.append(change)
        }

        return received
    }

    /// The regression: `AsyncLineSequence` drops blank lines, so the frame
    /// delimiter was never seen and every event but a lone one was lost.
    @Test("Three pushes on one connection arrive as three state changes")
    func everyPushOnAConnectionArrives() async throws {
        let received = try await changes(from: """
        event: state
        data: {"@type":"StateChange","changed":{"acc":{"Email":"s1"}}}

        event: state
        data: {"@type":"StateChange","changed":{"acc":{"Email":"s2"}}}

        event: state
        data: {"@type":"StateChange","changed":{"acc":{"Mailbox":"m3"}}}


        """)

        #expect(received.count == 3)
        #expect(received.map { $0.state(for: "Email", accountID: "acc") } == ["s1", "s2", nil])
        #expect(received[2].state(for: "Mailbox", accountID: "acc") == "m3")
    }

    @Test("CRLF framing works and ping keepalives are not state changes")
    func crlfAndPings() async throws {
        let received = try await changes(
            from: "event: ping\r\ndata: {\"interval\":300}\r\n\r\n"
                + "event: state\r\ndata: {\"changed\":{\"acc\":{\"Email\":\"s9\"}}}\r\n\r\n"
        )

        #expect(received.count == 1)
        #expect(received[0].state(for: "Email", accountID: "acc") == "s9")
    }

    @Test("A rejected stream throws instead of finishing silently")
    func rejectedStreamThrows() async {
        await #expect(throws: (any Error).self) {
            try await changes(from: "", statusCode: 400)
        }
    }
}
