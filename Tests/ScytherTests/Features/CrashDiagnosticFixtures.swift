//
//  CrashDiagnosticFixtures.swift
//  ScytherTests
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
@testable import Scyther
import Foundation

/// `MXCrashDiagnostic.jsonRepresentation()` fixtures, shaped like the diagnostics MetricKit
/// delivers. MetricKit's types cannot be built in a test, so these stand in for them.
enum CrashDiagnosticFixtures {
    /// The UUID of the app binary in the fixtures.
    static let appUUID = UUID(uuidString: "6490A8DD-3A0A-3168-9C49-FC1B8357CCEB")!

    /// A Swift force unwrap of `nil`: `EXC_BREAKPOINT` / `SIGTRAP`, with no Objective-C exception.
    ///
    /// The crashed thread is the second one, so the mapper has to find it by `threadAttributed`.
    /// Its first frame stores the binary's load address in `offsetIntoBinaryTextSegment`, as
    /// MetricKit has been seen to do, and its second a real offset.
    static let swiftTrap = """
    {
      "version": "1.0.0",
      "callStackTree": {
        "callStackPerThread": true,
        "callStacks": [
          {
            "threadAttributed": false,
            "callStackRootFrames": [
              { "binaryUUID": "8AC40BE9-1E3B-300A-9C30-4115C6F28734", "binaryName": "libsystem_kernel.dylib",
                "offsetIntoBinaryTextSegment": 4000, "address": 8038412192, "sampleCount": 1 }
            ]
          },
          {
            "threadAttributed": true,
            "callStackRootFrames": [
              {
                "binaryUUID": "6490A8DD-3A0A-3168-9C49-FC1B8357CCEB", "binaryName": "ExampleApp",
                "offsetIntoBinaryTextSegment": 4340776960, "address": 4340801536, "sampleCount": 1,
                "subFrames": [
                  {
                    "binaryUUID": "6490A8DD-3A0A-3168-9C49-FC1B8357CCEB", "binaryName": "ExampleApp",
                    "offsetIntoBinaryTextSegment": 12000, "address": 4340788960, "sampleCount": 1,
                    "subFrames": [
                      { "binaryUUID": "31A51429-8511-3926-B44B-755BE73CF4EA", "binaryName": "dyld",
                        "offsetIntoBinaryTextSegment": 4361617408, "address": 4361716432, "sampleCount": 1 }
                    ]
                  }
                ]
              }
            ]
          }
        ]
      },
      "diagnosticMetaData": {
        "appBuildVersion": "42",
        "appVersion": "2.1.0",
        "regionFormat": "AU",
        "exceptionType": 6,
        "osVersion": "iPhone OS 18.0 (22A3354)",
        "deviceType": "iPhone17,1",
        "exceptionCode": 1,
        "signal": 5,
        "terminationReason": "Namespace SIGNAL, Code 5 Trace/BPT trap: 5",
        "platformArchitecture": "arm64"
      }
    }
    """

    /// An uncaught `NSException` as MetricKit reports it from iOS 17: `EXC_CRASH` / `SIGABRT`, with
    /// the exception's name and message.
    static let objectiveCException = """
    {
      "version": "1.0.0",
      "callStackTree": { "callStackPerThread": true, "callStacks": [] },
      "diagnosticMetaData": {
        "appBuildVersion": "42",
        "appVersion": "2.1.0",
        "exceptionType": 10,
        "osVersion": "iPhone OS 18.0 (22A3354)",
        "deviceType": "iPhone17,1",
        "exceptionCode": 0,
        "signal": 6,
        "objectiveCexceptionReason": {
          "composedMessage": "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
          "formatString": "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
          "arguments": [],
          "exceptionType": "NSException",
          "className": "NSException",
          "exceptionName": "NSInvalidArgumentException"
        }
      }
    }
    """

    /// An uncaught `NSException` as MetricKit reports it before iOS 17: a bare `SIGABRT`.
    static let abort = """
    {
      "version": "1.0.0",
      "callStackTree": { "callStackPerThread": true, "callStacks": [] },
      "diagnosticMetaData": {
        "appBuildVersion": "41",
        "appVersion": "2.0.0",
        "exceptionType": 10,
        "osVersion": "iPhone OS 16.4 (20E247)",
        "deviceType": "iPhone14,2",
        "exceptionCode": 0,
        "signal": 6
      }
    }
    """

    /// A call stack tree with one thread `depth` frames deep.
    static func chain(depth: Int) -> String {
        let frame = #"{"binaryName": "Deep", "offsetIntoBinaryTextSegment": 1, "subFrames": ["#
        return #"{"callStacks": [{"threadAttributed": true, "callStackRootFrames": ["#
            + String(repeating: frame, count: depth - 1)
            + #"{"binaryName": "Deep", "offsetIntoBinaryTextSegment": 1}"#
            + String(repeating: "]}", count: depth - 1)
            + "]}]}"
    }

    /// The start of the fixtures' payload window.
    static let windowBegin = Date(timeIntervalSince1970: 1_800_000_000)

    /// The end of the fixtures' payload window.
    static let windowEnd = windowBegin.addingTimeInterval(3_600)

    /// A record parsed from one of the fixtures, in the fixtures' payload window.
    static func record(_ json: String,
                       begin: Date = windowBegin,
                       end: Date = windowEnd) -> CrashDiagnosticRecord {
        CrashDiagnosticRecord(diagnosticJSON: Data(json.utf8), timeStampBegin: begin, timeStampEnd: end)!
    }

    /// An entry as the exception handler would have stored it.
    static func handlerEntry(name: String, at timestamp: Date) -> CrashLogEntry {
        CrashLogEntry(timestamp: timestamp, name: name, reason: "reason", stackTrace: [],
                      appVersion: "2.1.0", buildNumber: "42", osVersion: "18.0", deviceModel: "iPhone")
    }
}

/// A symbolicator that names nothing.
struct NoSymbolicator: CrashFrameSymbolicating {
    func symbol(binaryUUID: UUID, offset: UInt64) -> CrashSymbol? { nil }
}

/// A symbolicator that names every frame of one binary.
struct FixedSymbolicator: CrashFrameSymbolicating {
    let uuid: UUID

    func symbol(binaryUUID: UUID, offset: UInt64) -> CrashSymbol? {
        binaryUUID == uuid ? CrashSymbol(name: "frame@\(offset)", distance: 4) : nil
    }
}

/// An in-memory crash store.
final class InMemoryCrashLogRepository: CrashLogRepository, @unchecked Sendable {
    var allCrashes: [CrashLogEntry]
    private(set) var recorded: [[CrashLogEntry]] = []
    private(set) var artifacts: [CrashArtifacts] = []

    init(_ crashes: [CrashLogEntry] = []) {
        allCrashes = crashes
    }

    func record(_ entries: [CrashLogEntry], artifacts: [CrashArtifacts]) {
        recorded.append(entries)
        self.artifacts += artifacts
        allCrashes = (allCrashes + entries).sorted { $0.timestamp > $1.timestamp }
    }
}

/// An in-memory fingerprint store.
final class InMemoryFingerprintStore: CrashDiagnosticFingerprintStoring, @unchecked Sendable {
    var fingerprints: Set<String> = []

    func insert(_ fingerprints: [String]) {
        self.fingerprints.formUnion(fingerprints)
    }
}
#endif
