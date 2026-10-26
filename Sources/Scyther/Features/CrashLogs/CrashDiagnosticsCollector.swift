//
//  CrashDiagnosticsCollector.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation
import MetricKit

/// Subscribes to MetricKit and records the crash diagnostics it delivers.
///
/// The uncaught exception handler in ``CrashLogger`` only sees Objective-C exceptions. A Swift
/// trap, an `EXC_BAD_ACCESS` or an abort from another runtime never reaches it. MetricKit gets a
/// diagnostic from the OS for every one of those, and delivers it on the next launch. Signal and
/// Mach exception handlers would see them sooner, but other crash reporters install those too, and
/// chaining a third safely is fragile. MetricKit takes any number of subscribers.
///
/// On ``start()`` the collector ingests `pastDiagnosticPayloads` — what MetricKit delivered before
/// anyone was listening — and then subscribes for the rest. Each diagnostic goes through
/// ``CrashDiagnosticIngestor``, which drops the ones already ingested and the ones the exception
/// handler already recorded.
///
/// - Note: MetricKit delivers diagnostics on a physical device only, never on the Simulator, and
///   produces none for a crash that happens with the debugger attached.
final class CrashDiagnosticsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    /// Shared instance.
    static let shared = CrashDiagnosticsCollector()

    /// Decides what is stored. Built on first use, because reading the loaded images to symbolicate
    /// with is not free and need not happen during app launch.
    private lazy var ingestor = CrashDiagnosticIngestor(
        crashes: CrashLogger.instance,
        fingerprints: CrashDiagnosticFingerprintStore.shared,
        symbolicator: LoadedImageSymbolicator()
    )

    /// Every payload is ingested here, one at a time, so two deliveries never decide against the
    /// same stored state, and the work stays off the main thread.
    private let queue = DispatchQueue(label: "com.scyther.crash-diagnostics", qos: .utility)

    /// Whether ``start()`` has run. Read and written on the main actor only.
    private var isStarted = false

    private override init() {
        super.init()
    }

    /// Ingests the diagnostics MetricKit already holds, then subscribes for new ones. Only the
    /// first call does anything.
    @MainActor
    func start() {
        guard !isStarted else { return }
        isStarted = true

        let manager = MXMetricManager.shared
        ingest(manager.pastDiagnosticPayloads)
        manager.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        ingest(payloads)
    }

    /// Converts the payloads' crash diagnostics and hands them to the ingestor on ``queue``.
    private func ingest(_ payloads: [MXDiagnosticPayload]) {
        let records = payloads.flatMap { payload in
            (payload.crashDiagnostics ?? []).compactMap {
                CrashDiagnosticRecord(diagnostic: $0,
                                      timeStampBegin: payload.timeStampBegin,
                                      timeStampEnd: payload.timeStampEnd)
            }
        }
        guard !records.isEmpty else { return }
        queue.async {
            self.ingestor.ingest(records)
        }
    }
}
#endif
