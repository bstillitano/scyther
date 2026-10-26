//
//  CrashExportViewModel.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation

/// View model backing ``CrashExportSheet``.
///
/// Builds the crash archive with ``CrashExporter``, rebuilding it when redaction is toggled. The
/// building, redaction and cleanup are ``ArchiveExportViewModel``'s, shared with the network log
/// export.
final class CrashExportViewModel: ArchiveExportViewModel {
    /// The crashes being exported.
    let crashes: [CrashLogEntry]

    /// Whether any crash carries a session's console output or network traffic, which is what
    /// makes the archive sensitive and redaction worth offering.
    let includesSessionLogs: Bool

    /// Creates an export view model.
    ///
    /// - Parameters:
    ///   - crashes: The crashes to export.
    ///   - minimumRebuildDuration: Floor on how long a rebuild appears to take. Pass `.zero` in tests.
    ///   - exporter: Builds the archive. Defaults to ``CrashExporter/export(_:redact:in:now:artifacts:journal:)``.
    init(
        crashes: [CrashLogEntry],
        minimumRebuildDuration: Duration = ArchiveExportViewModel.defaultMinimumRebuildDuration,
        exporter: @escaping @Sendable ([CrashLogEntry], Bool) throws -> URL = { crashes, redact in
            try CrashExporter.export(crashes, redact: redact)
        }
    ) {
        self.crashes = crashes
        self.includesSessionLogs = crashes.contains { $0.sessionID != nil }
        super.init(minimumRebuildDuration: minimumRebuildDuration) { redact in
            try exporter(crashes, redact)
        }
    }

    /// The number of crashes in the archive.
    var crashCount: Int { crashes.count }

    /// Whether any crash came from MetricKit, and so has a raw diagnostic in the archive.
    var includesDiagnostics: Bool {
        crashes.contains { $0.source == .metricKit }
    }
}
#endif
