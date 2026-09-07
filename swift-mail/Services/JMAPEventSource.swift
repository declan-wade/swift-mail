import Foundation

struct JMAPEventSource {
    let url: URL
    let bearerToken: String
    var urlSession: URLSession = .shared

    func events() -> AsyncThrowingStream<Void, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 310

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
                            emitIfNeeded(eventName: eventName, dataLines: dataLines, continuation: continuation)
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

                    emitIfNeeded(eventName: eventName, dataLines: dataLines, continuation: continuation)
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

    private func emitIfNeeded(
        eventName: String,
        dataLines: [String],
        continuation: AsyncThrowingStream<Void, Error>.Continuation
    ) {
        guard eventName != "ping", !dataLines.isEmpty else {
            return
        }

        continuation.yield(())
    }
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
