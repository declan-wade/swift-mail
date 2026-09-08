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
/// The server closes the connection after `closeafter` seconds (see
/// `JMAPSession.eventSourceURL(types:closeAfter:)`); the stream simply finishes
/// then and the caller reconnects. Transport errors are surfaced so the caller
/// can back off.
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

                    var eventName = ""
                    var dataLines: [String] = []

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        if line.isEmpty {
                            emit(eventName: eventName, dataLines: dataLines, continuation: continuation)
                            eventName = ""
                            dataLines = []
                            continue
                        }

                        if line.hasPrefix(":") {
                            continue
                        }

                        if line.hasPrefix("event:") {
                            eventName = line.droppingServerSentEventPrefix("event:")
                        } else if line.hasPrefix("data:") {
                            dataLines.append(line.droppingServerSentEventPrefix("data:"))
                        }
                    }

                    emit(eventName: eventName, dataLines: dataLines, continuation: continuation)
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

    private func emit(
        eventName: String,
        dataLines: [String],
        continuation: AsyncThrowingStream<JMAPStateChange, Error>.Continuation
    ) {
        guard eventName != "ping", !dataLines.isEmpty else {
            return
        }

        let payload = dataLines.joined(separator: "\n")
        guard let data = payload.data(using: .utf8),
              let change = try? JSONDecoder().decode(JMAPStateChange.self, from: data) else {
            return
        }

        continuation.yield(change)
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

private extension String {
    func droppingServerSentEventPrefix(_ prefix: String) -> String {
        var value = String(dropFirst(prefix.count))
        if value.hasPrefix(" ") {
            value.removeFirst()
        }
        return value
    }
}
