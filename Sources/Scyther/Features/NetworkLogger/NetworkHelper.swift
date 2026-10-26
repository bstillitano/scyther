//
//  NetworkHelper.swift
//
//
//  Created by Brandon Stillitano on 24/12/20.
//

import Foundation

/// Manages network request interception and logging for the Scyther debugging framework.
///
/// `NetworkHelper` provides the core functionality for intercepting HTTP/HTTPS requests
/// made by the application. It registers a custom `URLProtocol` to capture all network
/// traffic and maintains configuration for filtering and caching.
///
/// ## Features
/// - Automatic request and response logging
/// - URL filtering to exclude specific endpoints
/// - Support for custom URL session configurations
/// - IP address resolution
/// - Content type filtering
///
/// ## Usage
/// ```swift
/// // Start network logging (typically called once during app startup)
/// NetworkHelper.instance.start()
///
/// // Ignore specific URLs
/// NetworkHelper.instance.ignoredURLs = ["https://analytics.example.com"]
///
/// // Access the device's IP address
/// let ip = await NetworkHelper.instance.ipAddress
/// ```
///
/// - Note: Sessions other than `URLSession.shared` are intercepted through `URLSessionConfiguration`
///   hooks that the `ScytherBootstrap` target installs at image load.
@MainActor
public final class NetworkHelper: Sendable {
    /// Private Init to Stop re-initialisation and allow singleton creation.
    private nonisolated init() {}

    /// An initialised, shared instance of the `NetworkHelper` class.
    /// Note: nonisolated(unsafe) is required because this singleton is read from `URLProtocol`
    /// callbacks, which run in a nonisolated context.
    /// The warning about this being unnecessary is incorrect for @MainActor classes.
    nonisolated(unsafe) static let instance = NetworkHelper()

    /// URLs that will not be logged or intercepted by Scyther.
    ///
    /// Add URL prefixes to this array to exclude them from network logging.
    /// Useful for preventing infinite loops or excluding analytics/telemetry endpoints.
    ///
    /// ## Example
    /// ```swift
    /// NetworkHelper.instance.ignoredURLs = [
    ///     "https://analytics.example.com",
    ///     "https://telemetry.example.com"
    /// ]
    /// ```
    /// - Note: This property is nonisolated as it's accessed from URLProtocol callbacks.
    nonisolated(unsafe) public var ignoredURLs: [String] = []

    /// The cache storage policy for network requests.
    ///
    /// Determines how the network helper should cache requests and responses.
    /// Defaults to `.notAllowed` to prevent caching of intercepted requests.
    /// - Note: This property is nonisolated as it's accessed from URLProtocol callbacks.
    nonisolated(unsafe) var cacheStoragePolicy = URLCache.StoragePolicy.notAllowed

    /// Content type filters for displaying network logs.
    ///
    /// A boolean array representing which content types should be shown in the UI.
    /// Indices correspond to `HTTPModelShortType.allCases`.
    private var filters: [Bool] = []

    /// Returns the cached content type filters.
    ///
    /// If not yet initialized, creates a default array with all content types enabled.
    public var cachedFilters: [Bool] {
        get {
            if filters.isEmpty {
                filters = [Bool](repeating: true, count: HTTPModelShortType.allCases.count)
            }
            return filters
        }
        set {
            filters = newValue
        }
    }

    /// The current IP address of the device.
    ///
    /// This property asynchronously fetches the device's public IP address using the ipify API.
    /// The result is cached after the first **successful** fetch, and every caller that arrives
    /// while a fetch is still in flight shares it. A failure is shared but not cached, so the
    /// next caller tries again.
    ///
    /// Coalescing is not an optimisation. ``hasResolvedIPAddress`` used to be set only *after*
    /// the `await` returned, so the flag was still `false` for the whole round trip and every
    /// caller that arrived in that window started a request of its own. A menu that was re-created
    /// once a second — which is what a modal presented over it does — therefore fired one lookup
    /// per second for as long as the first one was outstanding. The in-flight ``Task`` closes that
    /// window: it is recorded before the first suspension point, so a second caller finds it and
    /// awaits the same result.
    ///
    /// ## Example
    /// ```swift
    /// let ip = await NetworkHelper.instance.ipAddress
    /// print("Device IP: \(ip)")
    /// ```
    ///
    /// - Returns: The IP address as a string, or "0.0.0.0" if unavailable.
    public var ipAddress: String {
        get async {
            if hasResolvedIPAddress { return _ipAddress }

            /// Everything up to the `await` runs without suspending on the main actor, so no
            /// second caller can interleave between the check and the store. That is the whole
            /// mechanism: whoever gets here first publishes the task, everyone else joins it.
            let task = ipAddressTask ?? Task { await Self.fetchIPAddress() }
            ipAddressTask = task

            let resolved = await task.value

            /// A cache reset while this lookup was in flight replaced or cleared the task, and
            /// writing back here would undo it with a value from before the reset.
            guard ipAddressTask == task else { return resolved }

            /// The winner and every joiner write the same value, so the assignments are
            /// idempotent and no ordering between them matters.
            _ipAddress = resolved
            ipAddressTask = nil

            /// A failure is **not** cached. Coalescing means one failed lookup now answers every
            /// caller waiting on it, so caching that failure would take one blip and show
            /// `0.0.0.0` until the app was relaunched — the menu deliberately does not re-run the
            /// lookup on a subsequent appearance. Leaving the flag down costs one more request
            /// the next time somebody asks.
            hasResolvedIPAddress = resolved != Self.unknownIPAddress
            return resolved
        }
    }

    /// What ``fetchIPAddress()`` returns when it could not find out.
    ///
    /// Named rather than repeated, because ``ipAddress`` has to recognise it in order not to cache
    /// it.
    private static let unknownIPAddress = "0.0.0.0"

    /// Internal storage for the cached IP address.
    private var _ipAddress: String = ""

    /// Flag indicating whether the IP address has been resolved **successfully**. A failed lookup
    /// leaves it down, so the next caller tries again rather than reading `0.0.0.0` back until the
    /// app is relaunched.
    private var hasResolvedIPAddress: Bool = false

    /// The lookup every caller that arrives before the first one finishes joins, or `nil` when
    /// none is outstanding.
    ///
    /// Main-actor isolated, like the rest of this type's mutable state, which is what makes the
    /// check-then-store in ``ipAddress`` atomic without a lock.
    private var ipAddressTask: Task<String, Never>?

    /// Forgets the cached address and any lookup in flight.
    ///
    /// - Note: Internal so a test can start from a clean cache. Nothing in production calls it.
    internal func resetIPAddressCacheForTesting() {
        ipAddressTask?.cancel()
        ipAddressTask = nil
        hasResolvedIPAddress = false
        _ipAddress = ""
    }
}

// MARK: - Lifecycle
extension NetworkHelper {
    /// Starts network logging by registering the HTTP interceptor protocol.
    ///
    /// Registering covers `URLSession.shared`. Every other session is covered by the
    /// `ScytherBootstrap` target, which hooks `URLSessionConfiguration` when the image loads and
    /// puts `HTTPInterceptorURLProtocol` into each configuration as it is created — including the
    /// ones a host app creates before ``Scyther/start(allowProductionBuilds:)``, which a hook
    /// installed here could never reach, because a session copies its configuration when it is
    /// created.
    ///
    /// Call this method once during application startup to enable network logging. Calling it
    /// again is harmless.
    func start() {
        enable(true)
    }
}

// MARK: - Enablers
extension NetworkHelper {
    /// Enables or disables network logging globally.
    ///
    /// - Parameter enable: `true` to enable logging, `false` to disable.
    /// - Note: This method is nonisolated as URLProtocol registration is thread-safe.
    nonisolated func enable(_ enable: Bool) {
        if enable {
            URLProtocol.registerClass(HTTPInterceptorURLProtocol.self)
        } else {
            URLProtocol.unregisterClass(HTTPInterceptorURLProtocol.self)
        }
    }
}

// MARK: - IP Address
extension NetworkHelper {
    /// Retrieves the current IP Address of the device asynchronously.
    ///
    /// Makes a request to the ipify API to determine the device's public IP address.
    ///
    /// The request is marked as Scyther's own — see ``ScytherOriginatedRequest`` — so it is
    /// logged like any other request but can never be held at a breakpoint, answered by a mock,
    /// rewritten or conditioned. It is the menu's own lookup: a developer who breakpoints
    /// `api.ipify.org` would otherwise stall the screen they need in order to switch that
    /// breakpoint off.
    ///
    /// Static because the in-flight ``Task`` in ``ipAddress`` calls it, and a static call keeps
    /// the singleton out of the task's captures.
    ///
    /// - Returns: The IP address as a string, or "0.0.0.0" if the request fails.
    private static func fetchIPAddress() async -> String {
        // Construct API URL
        guard let url = URL(string: "https://api.ipify.org/?format=json") else {
            return unknownIPAddress
        }

        // Setup network request, marked so Scyther never intercepts its own lookup.
        let urlRequest = ScytherOriginatedRequest.marked(URLRequest(url: url))

        // Attempt network request
        do {
            // Perform network request
            let (data, _) = try await URLSession.shared.data(for: urlRequest)

            // Parse JSON response
            if let json = try JSONSerialization.jsonObject(with: data, options: [.allowFragments]) as? [String: Any],
               let ipAddress = json["ip"] as? String
            {
                return ipAddress
            } else {
                return unknownIPAddress
            }
        } catch {
            return unknownIPAddress
        }
    }
}
