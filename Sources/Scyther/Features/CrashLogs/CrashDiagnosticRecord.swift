//
//  CrashDiagnosticRecord.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import CryptoKit
import Foundation
import MetricKit

/// The parts of a MetricKit crash diagnostic that Scyther turns into a ``CrashLogEntry``.
///
/// MetricKit's types cannot be built outside MetricKit, so the mapping and de-duplication work on
/// this value instead. It is made from a real `MXCrashDiagnostic` by
/// ``init(diagnostic:timeStampBegin:timeStampEnd:)``, and from a diagnostic's JSON — which is how
/// the tests feed it fixtures — by ``init(diagnosticJSON:timeStampBegin:timeStampEnd:)``. The first
/// is built on the second, so both go through the same parsing, by ``CrashDiagnosticJSONReader``.
struct CrashDiagnosticRecord: Equatable, Sendable {
    /// The Mach exception type, such as `6` for `EXC_BREAKPOINT`.
    var exceptionType: Int?

    /// The signal that terminated the process, such as `5` for `SIGTRAP`.
    var signal: Int?

    /// The name of the Objective-C exception that caused the crash, such as
    /// `NSInvalidArgumentException`. MetricKit reports it from iOS 17.
    var exceptionName: String?

    /// The Objective-C exception's message. MetricKit reports it from iOS 17.
    var composedMessage: String?

    /// The system's description of why the process was terminated.
    var terminationReason: String?

    /// The Mach exception code. For `EXC_BAD_ACCESS`, the kind of fault.
    var exceptionCode: Int?

    /// The virtual memory region around a faulting address, as MetricKit describes it.
    var virtualMemoryRegionInfo: String?

    /// The crashed process's identifier. MetricKit reports it from iOS 17.
    var processID: Int?

    /// The app's bundle identifier, from the JSON, or the typed property from iOS 26.
    var bundleIdentifier: String?

    /// The CPU architecture, such as `arm64e`.
    var architecture: String?

    /// The diagnostic exactly as MetricKit delivered it, for the export.
    var diagnosticJSON: Data

    /// The threads in the diagnostic's call stack tree.
    var threads: [CrashDiagnosticJSONReader.Thread]

    /// The app's version string when it crashed.
    var appVersion: String

    /// The app's build number when it crashed.
    var buildNumber: String

    /// The OS version when it crashed, as MetricKit formats it, such as `iPhone OS 17.0 (21A329)`.
    var osVersion: String

    /// The hardware model, such as `iPhone15,2`.
    var deviceModel: String

    /// The start of the window the diagnostic's payload covers.
    var timeStampBegin: Date

    /// The end of the window the diagnostic's payload covers.
    var timeStampEnd: Date

    /// A stable hash of the diagnostic, so the same diagnostic is never ingested twice.
    ///
    /// Built from the parsed fields and frames, not from the JSON text, so it does not depend on
    /// the order MetricKit happens to serialise keys in.
    var fingerprint: String

    /// Parses a crash diagnostic's JSON, as `MXCrashDiagnostic.jsonRepresentation()` produces it.
    ///
    /// - Parameters:
    ///   - diagnosticJSON: The diagnostic's JSON.
    ///   - timeStampBegin: The start of the window its payload covers.
    ///   - timeStampEnd: The end of that window.
    /// - Returns: `nil` if the data is not a JSON object.
    init?(diagnosticJSON: Data, timeStampBegin: Date, timeStampEnd: Date) {
        guard let document = CrashDiagnosticJSONReader.read(diagnosticJSON) else {
            return nil
        }
        let metaData = { (key: String) in document.values["diagnosticMetaData.\(key)"] }

        exceptionType = metaData("exceptionType").flatMap { Int($0) }
        signal = metaData("signal").flatMap { Int($0) }
        exceptionName = metaData("objectiveCexceptionReason.exceptionName")
        composedMessage = metaData("objectiveCexceptionReason.composedMessage")
        terminationReason = metaData("terminationReason")
        exceptionCode = metaData("exceptionCode").flatMap { Int($0) }
        virtualMemoryRegionInfo = metaData("virtualMemoryRegionInfo")
        processID = metaData("pid").flatMap { Int($0) }
        bundleIdentifier = metaData("bundleIdentifier")
        architecture = metaData("platformArchitecture")
        self.diagnosticJSON = diagnosticJSON
        threads = document.threads
        appVersion = metaData("appVersion") ?? "Unknown"
        buildNumber = metaData("appBuildVersion") ?? "Unknown"
        osVersion = metaData("osVersion") ?? "Unknown"
        deviceModel = metaData("deviceType") ?? "Unknown"
        self.timeStampBegin = timeStampBegin
        self.timeStampEnd = timeStampEnd
        fingerprint = ""
        fingerprint = computedFingerprint
    }

    /// Converts a real MetricKit diagnostic.
    ///
    /// The JSON is parsed first, then every field MetricKit also exposes as a typed property is taken
    /// from that property, so the result does not depend on the JSON's key names where it need not.
    /// The app's version string has no typed form, and comes from the JSON alone.
    ///
    /// - Parameters:
    ///   - diagnostic: The diagnostic MetricKit delivered.
    ///   - timeStampBegin: The start of the window its payload covers.
    ///   - timeStampEnd: The end of that window.
    init?(diagnostic: MXCrashDiagnostic, timeStampBegin: Date, timeStampEnd: Date) {
        self.init(diagnosticJSON: diagnostic.jsonRepresentation(),
                  timeStampBegin: timeStampBegin,
                  timeStampEnd: timeStampEnd)

        exceptionType = diagnostic.exceptionType?.intValue
        signal = diagnostic.signal?.intValue
        terminationReason = diagnostic.terminationReason
        exceptionCode = diagnostic.exceptionCode?.intValue
        virtualMemoryRegionInfo = diagnostic.virtualMemoryRegionInfo ?? virtualMemoryRegionInfo
        architecture = diagnostic.metaData.platformArchitecture
        buildNumber = diagnostic.metaData.applicationBuildVersion
        osVersion = diagnostic.metaData.osVersion
        deviceModel = diagnostic.metaData.deviceType
        if #available(iOS 17.0, *) {
            processID = Int(diagnostic.metaData.pid)
            if let reason = diagnostic.exceptionReason {
                exceptionName = reason.exceptionName
                composedMessage = reason.composedMessage
            }
        }
        if #available(iOS 26.0, *) {
            bundleIdentifier = diagnostic.metaData.bundleIdentifier
        }
        fingerprint = computedFingerprint
    }

    /// Hashes every field and frame, one per line, in a fixed order.
    private var computedFingerprint: String {
        var lines = [
            "\(timeStampBegin.timeIntervalSince1970)",
            "\(timeStampEnd.timeIntervalSince1970)",
            exceptionType.map(String.init) ?? "-",
            signal.map(String.init) ?? "-",
            exceptionName ?? "-",
            composedMessage ?? "-",
            terminationReason ?? "-",
            appVersion,
            buildNumber,
            osVersion,
            deviceModel,
        ]
        for thread in threads {
            lines.append(thread.isAttributed ? "thread*" : "thread")
            lines += thread.frames.map { "\($0.binaryUUID ?? "-") \($0.resolvedOffset.map(String.init) ?? "-")" }
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
