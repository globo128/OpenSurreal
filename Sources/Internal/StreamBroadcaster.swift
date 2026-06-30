import Foundation

/// Fans one value out to every active subscriber. Each ``stream()`` is an
/// independent `AsyncStream` that buffers only the newest values, so a slow consumer
/// drops stale samples rather than blocking the producer.
@MainActor
final class StreamBroadcaster<Element: Sendable> {
    private var observers: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let bufferSize: Int

    init(bufferSize: Int) {
        self.bufferSize = bufferSize
    }

    /// An independent subscription. Pass `initial` to replay a current value to *this*
    /// subscriber the moment it attaches — used for state streams whose latest value is
    /// meaningful on subscribe, so a late subscriber isn't stuck until the next change.
    func stream(initial: Element? = nil) -> AsyncStream<Element> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { continuation in
            if let initial { continuation.yield(initial) }
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.observers.removeValue(forKey: id) }
            }
        }
    }

    func yield(_ element: Element) {
        for continuation in observers.values { continuation.yield(element) }
    }
}
