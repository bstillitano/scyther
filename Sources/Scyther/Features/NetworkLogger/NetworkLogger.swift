//
//  NetworkLogger.swift
//
//
//  Created by Brandon Stillitano on 24/12/20.
//

import Foundation

/// An actor that manages the collection of HTTP request/response logs.
///
/// `NetworkLogger` provides thread-safe storage and access to captured network requests.
/// It uses Swift's actor model to ensure safe concurrent access and provides an async stream
/// for real-time updates when new requests are logged.
///
/// ## Features
/// - Thread-safe request storage using Swift actors
/// - Real-time updates via `AsyncStream`
/// - Automatic notification of changes
/// - FIFO ordering (newest requests first)
///
/// ## Usage
/// ```swift
/// // Add a request
/// await NetworkLogger.instance.add(httpRequest)
///
/// // Listen for updates
/// for await requests in await NetworkLogger.instance.updates {
///     print("Received \(requests.count) requests")
/// }
///
/// // Clear all requests
/// await NetworkLogger.instance.clear()
/// ```
actor NetworkLogger {
    /// Shared instance of the network logger.
    static let instance = NetworkLogger()

    /// Array of captured HTTP requests, ordered with newest first.
    var items = [HTTPRequest]()

    /// Continuation for the async stream that broadcasts updates.
    private var continuation: AsyncStream<[HTTPRequest]>.Continuation?

    /// An async stream that emits the current request list whenever it changes.
    ///
    /// Subscribe to this stream to receive real-time updates as new requests
    /// are logged or when the log is cleared.
    ///
    /// ## Example
    /// ```swift
    /// Task {
    ///     for await requests in await NetworkLogger.instance.updates {
    ///         updateUI(with: requests)
    ///     }
    /// }
    /// ```
    var updates: AsyncStream<[HTTPRequest]> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(self.items) // push initial value
        }
    }

    /// Private initializer to enforce singleton pattern.
    private init() { }

    /// Adds a new HTTP request to the log.
    ///
    /// The request is inserted at the beginning of the array (newest first)
    /// and an update is broadcast to all stream subscribers.
    ///
    /// - Parameter obj: The `HTTPRequest` to add to the log.
    func add(_ obj: HTTPRequest) {
        items.insert(obj, at: 0)
        continuation?.yield(items)

        // Also written to disk, so a crash can be exported with the traffic that led to it.
        SessionJournal.shared.recordRequest(obj)
    }

    /// Removes all HTTP requests from the log and deletes associated files from disk.
    ///
    /// Clears the entire in-memory log, broadcasts an update with an empty array
    /// to all stream subscribers, and deletes all network log files from disk
    /// including request bodies, response bodies, the session log, and the session journal's
    /// copy of every session's traffic.
    func clear() {
        items.removeAll()
        continuation?.yield(items)

        // Delete all log files from disk
        Task { @MainActor in
            NetworkLogCleaner.shared.deleteAllLogFiles()
        }

        // And the session journal's copy, which would otherwise outlive the log it was cleared
        // from and turn up in a crash export.
        SessionJournal.shared.clearNetworkLogs()
    }
}
