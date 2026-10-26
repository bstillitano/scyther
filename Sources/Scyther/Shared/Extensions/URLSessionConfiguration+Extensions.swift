//
//  URLSessionConfiguration+Extensions.swift
//
//
//  Created by Brandon Stillitano on 1/1/21.
//

import Foundation

// MARK: - Non-Swizzling Constants

/// String extension providing constants for URLSessionConfiguration swizzling control.
public extension String {
    /// Constant string value used to exclude URLSessionConfiguration from network interception.
    ///
    /// When a URLSessionConfiguration's identifier contains this string, Scyther will skip
    /// swizzling that configuration's network requests. This is useful for scenarios where
    /// network interception would interfere with functionality, such as webhooks or third-party
    /// SDKs that require unmodified network behavior.
    ///
    /// ## Usage
    /// Include this string anywhere in the configuration identifier to prevent swizzling:
    /// - `"do_not_swizzle_ABC123"` - Will NOT be swizzled
    /// - `"ABC123_do_not_swizzle"` - Will NOT be swizzled
    /// - `"webhook_do_not_swizzle"` - Will NOT be swizzled
    ///
    /// ## Example
    /// ```swift
    /// // Create a configuration that won't be intercepted
    /// let config = URLSessionConfiguration.default(
    ///     withIdentifier: "webhook_\(String.noSwizzle)"
    /// )
    ///
    /// // Use for third-party SDKs that need unmodified networking
    /// let analyticsConfig = URLSessionConfiguration.default(
    ///     withIdentifier: "analytics_\(String.noSwizzle)_session"
    /// )
    /// ```
    ///
    /// - Important: This only affects URLSessionConfiguration objects with custom identifiers.
    ///              Use the `default(withIdentifier:)` initializer to set an identifier.
    ///
    /// - Note: This is particularly useful for:
    ///   - Webhook endpoints that validate request signatures
    ///   - Third-party analytics SDKs
    ///   - Payment processing SDKs
    ///   - Any networking that requires unmodified headers/behavior
    static var noSwizzle: String {
        return "do_not_swizzle"
    }
}

// MARK: - Custom Init

/// Public extensions for URLSessionConfiguration providing custom initializers.
public extension URLSessionConfiguration {
    /// Creates a default URLSessionConfiguration with a custom identifier.
    ///
    /// This convenience method creates a standard default configuration and assigns
    /// a custom identifier to it. The identifier can be used to control network interception
    /// behavior (e.g., by including `String.noSwizzle` to prevent swizzling).
    ///
    /// - Parameter identifier: A string identifier for the configuration
    ///
    /// - Returns: A default URLSessionConfiguration with the specified identifier
    ///
    /// ## Example
    /// ```swift
    /// // Create a configuration with custom identifier
    /// let config = URLSessionConfiguration.default(withIdentifier: "api_client")
    ///
    /// // Create a configuration that won't be intercepted
    /// let webhookConfig = URLSessionConfiguration.default(
    ///     withIdentifier: "webhook_\(String.noSwizzle)"
    /// )
    /// ```
    ///
    /// - Note: `.default` already carries `HTTPInterceptorURLProtocol`, because the bootstrap hooks
    ///   every configuration as it is created. An opted-out identifier takes it back out here.
    @objc class func `default`(withIdentifier identifier: String) -> URLSessionConfiguration {
        let configuration: URLSessionConfiguration = .default
        configuration.sharedContainerIdentifier = identifier
        if identifier.contains(String.noSwizzle) {
            configuration.protocolClasses?.removeAll { $0 == HTTPInterceptorURLProtocol.self }
        }
        return configuration
    }
}
