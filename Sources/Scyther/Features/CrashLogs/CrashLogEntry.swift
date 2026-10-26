//
//  CrashLogEntry.swift
//  Scyther
//
//  Created by Brandon Stillitano on 22/12/2024.
//

#if !os(macOS)
import Foundation

/// A model representing a captured crash or exception.
///
/// `CrashLogEntry` contains all information captured when an uncaught exception
/// occurs, including the exception details, stack trace, and environment metadata.
///
/// ## Properties
///
/// Each crash entry includes:
/// - Exception name and reason
/// - Full stack trace symbols
/// - App version and build number at time of crash
/// - iOS version and device model
/// - Precise timestamp
/// - Where it was captured: the exception handler, or MetricKit on a later launch
///
/// ## Usage
/// ```swift
/// let crashes = CrashLogger.instance.allCrashes
/// for crash in crashes {
///     print("Crash: \(crash.name)")
///     print("Reason: \(crash.reason ?? "Unknown")")
///     print("Date: \(crash.formattedTimestamp)")
/// }
///
/// // Generate a shareable report
/// let report = crashes.first?.fullReport
/// ```
///
/// ## Conformances
/// - `Identifiable`: Each crash has a unique UUID
/// - `Codable`: Crashes can be serialized for persistence
/// - `Equatable`: Crashes can be compared for equality
/// - `Sendable`: Safe to pass across actor boundaries
///
/// ## Topics
///
/// ### Properties
/// - ``id``
/// - ``timestamp``
/// - ``name``
/// - ``reason``
/// - ``stackTrace``
/// - ``appVersion``
/// - ``buildNumber``
/// - ``osVersion``
/// - ``deviceModel``
/// - ``source``
///
/// ### Computed Properties
/// - ``formattedTimestamp``
/// - ``summary``
/// - ``fullReport``
public struct CrashLogEntry: Identifiable, Codable, Equatable, Sendable {
    /// Unique identifier for this crash entry.
    public let id: UUID

    /// Timestamp when the crash occurred.
    public let timestamp: Date

    /// Exception name (e.g., "NSInvalidArgumentException").
    public let name: String

    /// Exception reason/message.
    public let reason: String?

    /// Stack trace symbols at the time of crash.
    public let stackTrace: [String]

    /// App version when crash occurred.
    public let appVersion: String

    /// Build number when crash occurred.
    public let buildNumber: String

    /// OS version when crash occurred.
    public let osVersion: String

    /// Device model when crash occurred.
    public let deviceModel: String

    /// How the crash was captured.
    ///
    /// An entry stored without a source decodes as ``CrashLogSource/exceptionHandler``, the only
    /// path that writes entries without one.
    public let source: CrashLogSource

    /// Creates a new crash log entry.
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        name: String,
        reason: String?,
        stackTrace: [String],
        appVersion: String,
        buildNumber: String,
        osVersion: String,
        deviceModel: String,
        source: CrashLogSource = .exceptionHandler
    ) {
        self.id = id
        self.timestamp = timestamp
        self.name = name
        self.reason = reason
        self.stackTrace = stackTrace
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, name, reason, stackTrace, appVersion, buildNumber, osVersion, deviceModel, source
    }

    /// Decodes an entry, defaulting ``source`` when it is absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        name = try container.decode(String.self, forKey: .name)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        stackTrace = try container.decode([String].self, forKey: .stackTrace)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        osVersion = try container.decode(String.self, forKey: .osVersion)
        deviceModel = try container.decode(String.self, forKey: .deviceModel)
        source = try container.decodeIfPresent(CrashLogSource.self, forKey: .source) ?? .exceptionHandler
    }

    /// Formatted timestamp for display.
    public var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: timestamp)
    }

    /// Short summary for list display.
    public var summary: String {
        reason ?? name
    }

    /// Full crash report as text for sharing/copying.
    public var fullReport: String {
        var report = """
        Crash Report
        ============

        Date: \(formattedTimestamp)
        Exception: \(name)
        Reason: \(reason ?? "Unknown")
        Source: \(source.rawValue)

        Device: \(deviceModel)
        OS Version: \(osVersion)
        App Version: \(appVersion) (\(buildNumber))

        Stack Trace:
        """

        for (index, symbol) in stackTrace.enumerated() {
            report += "\n\(index): \(symbol)"
        }

        return report
    }
}
#endif
