//
//  CrashDiagnosticIngestor.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation

/// The crash log store, as the MetricKit path sees it.
protocol CrashLogRepository: Sendable {
    /// Every stored crash, newest first.
    var allCrashes: [CrashLogEntry] { get }

    /// Stores entries alongside the existing ones, keeping the store's cap.
    func record(_ entries: [CrashLogEntry])
}

/// Remembers which MetricKit diagnostics have already been ingested.
protocol CrashDiagnosticFingerprintStoring: Sendable {
    /// The fingerprints of every diagnostic ingested so far.
    var fingerprints: Set<String> { get }

    /// Adds fingerprints.
    func insert(_ fingerprints: [String])
}

/// Decides which MetricKit crash diagnostics become crash log entries, and stores them.
///
/// Two rules keep the log free of duplicates:
///
/// - **Never twice.** MetricKit hands the same diagnostics back through `pastDiagnosticPayloads` on
///   later launches. Every diagnostic is fingerprinted when it is first seen — stored or dropped —
///   and a fingerprint already seen is skipped.
/// - **Not when the exception handler already has it.** An `NSException` crash is reported both by
///   ``CrashLogger``'s handler, as it happens, and by MetricKit, on the next launch. A diagnostic is
///   dropped when an ``CrashLogSource/exceptionHandler`` entry falls inside its payload's window
///   and either has the diagnostic's exception name (iOS 17 and later, where MetricKit reports
///   one) or, where MetricKit reports no name, the diagnostic is a `SIGABRT` — which is how an
///   uncaught exception ends. Each handler entry accounts for one diagnostic at most, so a second
///   abort in the same window is still kept. The claim is remembered alongside the fingerprints,
///   so it holds across launches too: an entry claimed by one launch's diagnostic cannot be
///   claimed again by a later one.
struct CrashDiagnosticIngestor: Sendable {
    /// Where crash entries are stored.
    let crashes: CrashLogRepository

    /// Where fingerprints are remembered.
    let fingerprints: CrashDiagnosticFingerprintStoring

    /// Names frames for the stack traces.
    let symbolicator: CrashFrameSymbolicating

    /// How far outside a payload's window a handler entry may fall and still match.
    ///
    /// The handler stamps its entry a moment before the process dies, and MetricKit's window is
    /// built from its own clock, so an entry right at the edge of the window may land just
    /// outside it.
    static let windowTolerance: TimeInterval = 60

    /// `SIGABRT`, the signal an uncaught exception ends the process with.
    private static let abortSignal = 6

    /// Stores every diagnostic that is new and not a duplicate.
    ///
    /// - Parameter records: The diagnostics MetricKit delivered.
    /// - Returns: The entries that were stored.
    @discardableResult
    func ingest(_ records: [CrashDiagnosticRecord]) -> [CrashLogEntry] {
        let result = Self.newEntries(
            from: records,
            stored: crashes.allCrashes,
            seen: fingerprints.fingerprints,
            symbolicator: symbolicator
        )
        if !result.entries.isEmpty {
            crashes.record(result.entries)
        }
        if !result.fingerprints.isEmpty {
            fingerprints.insert(result.fingerprints)
        }
        return result.entries
    }

    /// The decision itself, apart from any storage.
    ///
    /// - Parameters:
    ///   - records: The diagnostics MetricKit delivered.
    ///   - stored: The crash entries already stored.
    ///   - seen: The fingerprints of diagnostics already ingested.
    ///   - symbolicator: Names frames for the stack traces.
    /// - Returns: The entries to store, and what to remember: the fingerprint of every diagnostic
    ///   looked at, and a ``claimKey(for:)`` for every handler entry a diagnostic matched.
    static func newEntries(
        from records: [CrashDiagnosticRecord],
        stored: [CrashLogEntry],
        seen: Set<String>,
        symbolicator: CrashFrameSymbolicating
    ) -> (entries: [CrashLogEntry], fingerprints: [String]) {
        var seen = seen
        var unmatched = stored.filter { $0.source == .exceptionHandler && !seen.contains(claimKey(for: $0)) }
        var entries: [CrashLogEntry] = []
        var fingerprints: [String] = []

        /// Named diagnostics first, so a handler entry is claimed by the diagnostic that names it
        /// before an unnamed abort can claim it by signal alone.
        let ordered = records.filter { $0.exceptionName != nil } + records.filter { $0.exceptionName == nil }

        for record in ordered {
            guard seen.insert(record.fingerprint).inserted else { continue }
            fingerprints.append(record.fingerprint)

            if let index = unmatched.firstIndex(where: { matches($0, record) }) {
                fingerprints.append(claimKey(for: unmatched.remove(at: index)))
                continue
            }
            entries.append(CrashDiagnosticMapper.entry(for: record, symbolicator: symbolicator))
        }
        return (entries, fingerprints)
    }

    /// What is remembered once a diagnostic has matched a handler entry. Kept in the fingerprint
    /// store, whose values never collide with it: a fingerprint is a hex digest.
    static func claimKey(for entry: CrashLogEntry) -> String {
        "claimed:\(entry.id.uuidString)"
    }

    /// Whether a handler entry is the same crash as a diagnostic.
    private static func matches(_ entry: CrashLogEntry, _ record: CrashDiagnosticRecord) -> Bool {
        /// Ordered explicitly, because a closed range traps if its bounds are reversed and this one
        /// is built from someone else's data.
        let start = min(record.timeStampBegin, record.timeStampEnd).addingTimeInterval(-windowTolerance)
        let end = max(record.timeStampBegin, record.timeStampEnd).addingTimeInterval(windowTolerance)
        guard (start...end).contains(entry.timestamp) else { return false }

        if let exceptionName = record.exceptionName {
            return entry.name == exceptionName
        }
        return record.signal == abortSignal
    }
}
#endif
