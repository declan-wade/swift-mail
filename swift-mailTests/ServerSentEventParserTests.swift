import Foundation
import Testing
@testable import swift_mail

struct ServerSentEventParserTests {
    /// Feeds a raw SSE payload the way the byte framing in `JMAPEventSource`
    /// does — splitting on newlines and *keeping* the blank delimiters, which
    /// is exactly what `AsyncLineSequence` throws away.
    private func frames(_ payload: String) -> [ServerSentEventParser.Frame] {
        var parser = ServerSentEventParser()

        return payload.components(separatedBy: "\n").compactMap { parser.consume(line: $0) }
    }

    @Test("Every frame on a connection is delivered, not just the first")
    func consecutiveFramesEachEmit() {
        let parsed = frames("""
        event: state
        data: {"a":1}

        event: state
        data: {"a":2}

        event: state
        data: {"a":3}


        """)

        #expect(parsed.count == 3)
        #expect(parsed.map(\.data) == ["{\"a\":1}", "{\"a\":2}", "{\"a\":3}"])
        #expect(parsed.allSatisfy { $0.event == "state" })
    }

    @Test("A frame's event name doesn't leak into the frame after it")
    func eventNameResetsPerFrame() {
        let parsed = frames("""
        event: ping
        data: {"interval":300}

        data: {"a":1}


        """)

        #expect(parsed.count == 2)
        #expect(parsed[0].event == "ping")
        #expect(parsed[1].event == "")
    }

    @Test("Multi-line data rejoins, comments and blank runs are ignored")
    func multiLineDataAndComments() {
        let parsed = frames("""
        : keepalive
        event: state
        data: {"a":
        data: 1}



        """)

        #expect(parsed.count == 1)
        #expect(parsed[0].data == "{\"a\":\n1}")
    }

    @Test("A blank line with nothing buffered yields no frame")
    func emptyDelimiterYieldsNothing() {
        #expect(frames("\n\n\n").isEmpty)
    }

    @Test("A real StateChange payload decodes off the parsed frame")
    func frameDecodesToStateChange() {
        let parsed = frames("""
        event: state
        data: {"@type":"StateChange","changed":{"acc1":{"Email":"s2","Mailbox":"m9"}}}


        """)

        let change = try! JSONDecoder().decode(JMAPStateChange.self, from: Data(parsed[0].data.utf8))

        #expect(change.state(for: "Email", accountID: "acc1") == "s2")
        #expect(change.state(for: "Mailbox", accountID: "acc1") == "m9")
        #expect(change.state(for: "Email", accountID: "other") == nil)
    }
}
