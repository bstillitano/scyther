//
//  NetworkLogExportViewModel.swift
//  Scyther
//
//  Created by Brandon Stillitano on 4/9/2026.
//

import Foundation

/// View model backing ``NetworkLogExportSheet``.
///
/// Builds the zip archive for the supplied requests, rebuilding it when redaction is toggled. The
/// building, redaction and cleanup are ``ArchiveExportViewModel``'s, shared with the crash export.
///
/// ## Usage
///
/// ```swift
/// let viewModel = NetworkLogExportViewModel(requests: listViewModel.requests)
/// ```
final class NetworkLogExportViewModel: ArchiveExportViewModel {
    /// The requests being exported.
    let requests: [HTTPRequest]

    /// Creates an export view model.
    ///
    /// - Parameters:
    ///   - requests: The requests to export.
    ///   - minimumRebuildDuration: Floor on how long a rebuild appears to take. Defaults to
    ///     ``ArchiveExportViewModel/defaultMinimumRebuildDuration``; pass `.zero` in tests.
    ///   - exporter: Builds the archive. Defaults to ``NetworkLogExporter/export(_:in:now:redact:)``.
    init(
        requests: [HTTPRequest],
        minimumRebuildDuration: Duration = ArchiveExportViewModel.defaultMinimumRebuildDuration,
        exporter: @escaping @Sendable ([HTTPRequest], Bool) throws -> URL = { requests, redact in
            try NetworkLogExporter.export(requests, redact: redact)
        }
    ) {
        self.requests = requests
        super.init(minimumRebuildDuration: minimumRebuildDuration) { redact in
            try exporter(requests, redact)
        }
    }

    /// The number of requests in the archive.
    var requestCount: Int { requests.count }
}
