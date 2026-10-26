//
//  CrashDiagnosticMapper.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation

/// Turns a MetricKit crash diagnostic into a ``CrashLogEntry``.
///
/// - ``CrashLogEntry/name`` is the Objective-C exception's name when MetricKit reports one (iOS 17
///   and later), and otherwise the Mach exception and signal, such as `EXC_BREAKPOINT (SIGTRAP)`.
/// - ``CrashLogEntry/reason`` is the exception's message, or the system's termination reason.
/// - ``CrashLogEntry/stackTrace`` is the crashed thread, top of the stack first, one frame per line
///   as `binary + offset`, followed by the symbol when this process can name it. A frame whose
///   offset cannot be recovered reads `binary + ?`.
/// - ``CrashLogEntry/timestamp`` is the end of the payload's window. MetricKit does not report the
///   moment of the crash itself.
enum CrashDiagnosticMapper {
    /// Maps a diagnostic.
    ///
    /// - Parameters:
    ///   - record: The diagnostic.
    ///   - symbolicator: Names the frames it can.
    /// - Returns: The entry to store.
    static func entry(for record: CrashDiagnosticRecord, symbolicator: CrashFrameSymbolicating) -> CrashLogEntry {
        CrashLogEntry(
            timestamp: record.timeStampEnd,
            name: name(for: record),
            reason: record.composedMessage ?? record.terminationReason,
            stackTrace: stackTrace(from: record.threads, symbolicator: symbolicator),
            appVersion: record.appVersion,
            buildNumber: record.buildNumber,
            osVersion: record.osVersion,
            deviceModel: record.deviceModel,
            source: .metricKit
        )
    }

    /// The exception's name, or the Mach exception and signal.
    static func name(for record: CrashDiagnosticRecord) -> String {
        if let exceptionName = record.exceptionName, !exceptionName.isEmpty {
            return exceptionName
        }
        let exception = record.exceptionType.map { machExceptionNames[$0] ?? "EXC_\($0)" }
        let signal = record.signal.map { signalNames[$0] ?? "SIG\($0)" }
        switch (exception, signal) {
        case let (exception?, signal?): return "\(exception) (\(signal))"
        case let (exception?, nil): return exception
        case let (nil, signal?): return signal
        case (nil, nil): return "Crash"
        }
    }

    /// Flattens the crashed thread of a call stack tree into one line per frame.
    ///
    /// The crashed thread is the one MetricKit marks `threadAttributed`. If none is marked — which
    /// MetricKit has been seen to do — the first thread stands in for it.
    ///
    /// - Returns: The frames, top of the stack first, or an empty array if there are no threads.
    static func stackTrace(from threads: [CrashDiagnosticJSONReader.Thread],
                           symbolicator: CrashFrameSymbolicating) -> [String] {
        guard let thread = threads.first(where: \.isAttributed) ?? threads.first else {
            return []
        }
        return thread.frames.map { line(for: $0, symbolicator: symbolicator) }
    }

    /// Formats one frame.
    private static func line(for frame: CrashDiagnosticJSONReader.Frame, symbolicator: CrashFrameSymbolicating) -> String {
        let binary = frame.binaryName ?? frame.binaryUUID ?? "???"
        guard let offset = frame.resolvedOffset else {
            return "\(binary) + ?"
        }
        let uuid = frame.binaryUUID.flatMap(UUID.init(uuidString:))
        let symbol = uuid.flatMap { symbolicator.symbol(binaryUUID: $0, offset: offset) }
        return symbol.map { "\(binary) + \(offset) (\($0))" } ?? "\(binary) + \(offset)"
    }

    /// Mach exception types, from `<mach/exception_types.h>`.
    private static let machExceptionNames: [Int: String] = [
        1: "EXC_BAD_ACCESS",
        2: "EXC_BAD_INSTRUCTION",
        3: "EXC_ARITHMETIC",
        4: "EXC_EMULATION",
        5: "EXC_SOFTWARE",
        6: "EXC_BREAKPOINT",
        7: "EXC_SYSCALL",
        8: "EXC_MACH_SYSCALL",
        9: "EXC_RPC_ALERT",
        10: "EXC_CRASH",
        11: "EXC_RESOURCE",
        12: "EXC_GUARD",
        13: "EXC_CORPSE_NOTIFY",
    ]

    /// Signals, from `<sys/signal.h>`.
    private static let signalNames: [Int: String] = [
        1: "SIGHUP",
        2: "SIGINT",
        3: "SIGQUIT",
        4: "SIGILL",
        5: "SIGTRAP",
        6: "SIGABRT",
        7: "SIGEMT",
        8: "SIGFPE",
        9: "SIGKILL",
        10: "SIGBUS",
        11: "SIGSEGV",
        12: "SIGSYS",
        13: "SIGPIPE",
        14: "SIGALRM",
        15: "SIGTERM",
    ]
}
#endif
