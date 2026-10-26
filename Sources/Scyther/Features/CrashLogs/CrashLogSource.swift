//
//  CrashLogSource.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation

/// Where a ``CrashLogEntry`` came from.
///
/// Scyther captures crashes two ways, and they see different things:
///
/// - ``exceptionHandler``: the uncaught `NSException` handler. It records the crash in the dying
///   process, with a symbolicated stack, but only for Objective-C exceptions.
/// - ``metricKit``: a crash diagnostic MetricKit delivers on a later launch. It covers every crash
///   type — Swift traps, `EXC_BAD_ACCESS`, aborts — but only on a device, and only for crashes that
///   happened without the debugger attached.
public enum CrashLogSource: String, Codable, Sendable, CaseIterable {
    /// Captured by the uncaught `NSException` handler as the app crashed.
    case exceptionHandler

    /// Delivered by MetricKit on a later launch.
    case metricKit

    /// The name written into ``CrashLogEntry/fullReport``. English, like the rest of the report,
    /// which is meant to be pasted into a bug tracker rather than read in the menu.
    var reportName: String {
        switch self {
        case .exceptionHandler: return "Exception Handler"
        case .metricKit: return "MetricKit"
        }
    }

    /// The name shown in the crash details.
    var displayName: String {
        switch self {
        case .exceptionHandler: return localized("Exception Handler")
        case .metricKit: return localized("MetricKit")
        }
    }
}
#endif
