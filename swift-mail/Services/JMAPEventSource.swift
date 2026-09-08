import Foundation

/// A JMAP `StateChange` object (RFC 8620 §7.1), delivered over the event source
/// as an SSE `state` event. `changed` maps an account id to the new state
/// string for each object type that changed on it.
nonisolated struct JMAPStateChange: Decodable {
    let changed: [String: [String: String]]

    /// The new state for `type` on `accountID`, if this change touched it.
    func state(for type: String, accountID: String) -> String? {
        changed[accountID]?[type]
    }
}

/// Streams JMAP `StateChange` objects from the account's `eventSourceUrl`.
///
/// The stream finishes when the server closes the connection; the caller
/// reconnects and reconciles. Transport errors are surfaced so the caller can
/// back off.
struct JMAPEventSource {
    let url: URL
    let bearerToken: String
    var urlSession: URLSession = .eventSource

    func events() -> AsyncThrowingStream<JMAPStateChange, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 330

                    let (bytes, response) = try await urlSession.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200..<300).contains(httpResponse.statusCode) else {
                        throw JMAPError.invalidEventSourceResponse
                    }

                    var parser = ServerSentEventParser()
                    var line: [UInt8] = []

                    // Framed byte by byte rather than with `bytes.lines`:
                    // Foundation's `AsyncLineSequence` silently drops empty
                    // lines, and an empty line is precisely what terminates an
                    // SSE frame. Consuming it that way never sees a frame
                    // boundary, so every event on a connection accumulates into
                    // one buffer and is only "delivered" — as unparseable
                    // concatenated JSON — once the connection closes.
                    for try await byte in bytes {
                        try Task.checkCancellation()

                        guard byte == UInt8(ascii: "\n") else {
                            line.append(byte)
                            continue
                        }

                        if let frame = parser.consume(line: Self.take(&line)) {
                            emit(frame, continuation: continuation)
                        }
                    }

                    if !line.isEmpty, let frame = parser.consume(line: Self.take(&line)) {
                        emit(frame, continuation: continuation)
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Consumes the buffered bytes as one line, dropping the CR of a CRLF.
    private static func take(_ line: inout [UInt8]) -> String {
        if line.last == UInt8(ascii: "\r") {
            line.removeLast()
        }

        defer { line.removeAll(keepingCapacity: true) }

        return String(decoding: line, as: UTF8.self)
    }

    private func emit(
        _ frame: ServerSentEventParser.Frame,
        continuation: AsyncThrowingStream<JMAPStateChange, Error>.Continuation
    ) {
        // `ping` is the RFC 8620 7.3 keepalive; it carries an interval, not a
        // state, and only needs to have kept the connection warm.
        guard frame.event != "ping" else {
            return
        }

        guard let data = frame.data.data(using: .utf8),
              let change = try? JSONDecoder().decode(JMAPStateChange.self, from: data) else {
            return
        }

        continuation.yield(change)
    }
}

/// Reassembles server-sent-event frames from lines, per the SSE grammar: fields
/// accumulate until a blank line completes the frame.
nonisolated struct ServerSentEventParser {
    struct Frame: Equatable {
        let event: String
        let data: String
    }

    private var event = ""
    private var dataLines: [String] = []

    /// Feeds one line. Returns a frame when the blank delimiter completes one.
    mutating func consume(line: String) -> Frame? {
        guard !line.isEmpty else {
            defer {
                event = ""
                dataLines = []
            }

            return dataLines.isEmpty ? nil : Frame(event: event, data: dataLines.joined(separator: "\n"))
        }

        // A leading colon is a comment, which some servers use as a keepalive.
        guard !line.hasPrefix(":") else {
            return nil
        }

        if line.hasPrefix("event:") {
            event = line.droppingServerSentEventPrefix("event:")
        } else if line.hasPrefix("data:") {
            dataLines.append(line.droppingServerSentEventPrefix("data:"))
        }

        return nil
    }
}

private extension URLSession {
    /// A dedicated session for the long-lived event-source connection so it
    /// doesn't share the shared session's connection pool or cache, and never
    /// times out on the (intentionally) idle stream between pushes.
    static let eventSource: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 330
        configuration.timeoutIntervalForResource = .infinity
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }()
}

fileprivate extension String {
    func droppingServerSentEventPrefix(_ prefix: String) -> String {
        var value = String(dropFirst(prefix.count))
        if value.hasPrefix(" ") {
            value.removeFirst()
        }
        return value
    }
}
