//
//  CrashReportFormatter.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation

/// Writes a crash as text, in the layout of Apple's own crash reports, so it reads the way a
/// developer expects and pastes cleanly into a bug tracker.
///
/// Every frame gets an absolute address — the image's load address plus the frame's offset, in
/// hex — wherever the load address is known, followed by its symbol or `binary + offset`. A
/// Binary Images section lists each image's address, architecture and UUID, and a closing section
/// gives the `atos` command that symbolicates the app's own frames against its dSYM.
///
/// The report is in English, like the system's: it is a technical artefact, not menu text.
enum CrashReportFormatter {
    /// Formats a crash.
    ///
    /// - Parameters:
    ///   - entry: The crash.
    ///   - details: Its details. Without them — a crash stored before details were captured — the
    ///     report falls back to the entry's own stack trace.
    ///   - session: The session it happened in, if known.
    /// - Returns: The report.
    static func report(entry: CrashLogEntry, details: CrashDetails?, session: SessionJournal.Session? = nil) -> String {
        var lines: [String] = []
        let process = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? "App"
        let pid = details?.processID.map { " [\($0)]" } ?? ""

        lines.append(field("Incident Identifier", entry.id.uuidString))
        lines.append(field("Hardware Model", details?.hardwareModel ?? entry.deviceModel))
        lines.append(field("Process", process + pid))
        lines.append(field("Identifier", details?.bundleIdentifier ?? Bundle.main.bundleIdentifier ?? "Unknown"))
        lines.append(field("Version", "\(entry.appVersion) (\(entry.buildNumber))"))
        lines.append(field("Code Type", details?.architecture ?? "Unknown"))
        lines.append(field("OS Version", details?.operatingSystem ?? entry.osVersion))
        lines.append(field("Date/Time", CrashIPSBuilder.timestamp(entry.timestamp)
                           + (entry.source == .metricKit ? " (end of MetricKit's reporting window)" : "")))
        if let session {
            lines.append(field("Launch Time", CrashIPSBuilder.timestamp(session.startedAt)))
        }
        lines.append(field("Captured By", entry.source.reportName))
        if let match = details?.sessionMatch {
            lines.append(field("Session Match", sessionMatchDescription(match)))
        }
        lines.append("")

        lines.append(field("Exception Type", exceptionDescription(entry: entry, details: details)))
        if let codes = details?.exceptionCodes, !codes.isEmpty {
            lines.append(field("Exception Codes", codes.map(hex).joined(separator: ", ")))
        }
        /// For a crash with no exception, MetricKit's termination reason is the entry's reason too,
        /// and is labelled as what it is.
        let termination = details?.terminationReason
        if let reason = entry.reason, reason != termination {
            lines.append(field("Exception Reason", reason))
        }
        if let termination {
            lines.append(field("Termination Reason", termination))
        }
        if let region = details?.virtualMemoryRegionInfo {
            lines.append("")
            lines.append("VM Region Info: \(region)")
        }
        lines.append("")

        guard let details, !details.threads.isEmpty || details.exceptionBacktrace?.isEmpty == false else {
            lines.append("Stack Trace:")
            lines += entry.stackTrace.enumerated().map { "\($0.offset)  \($0.element)" }
            return lines.joined(separator: "\n") + "\n"
        }

        if let backtrace = details.exceptionBacktrace, !backtrace.isEmpty {
            lines.append("Last Exception Backtrace:")
            lines += frameLines(backtrace, in: details)
            lines.append("")
        }
        for (index, thread) in details.threads.enumerated() {
            lines.append("Thread \(index)\(thread.crashed ? " Crashed" : ""):")
            lines += frameLines(thread.frames, in: details)
            lines.append("")
        }

        lines.append("Binary Images:")
        for image in details.images {
            let base = image.loadAddress.map(hex) ?? String(repeating: " ", count: 15) + "???"
            let uuid = image.uuid.map { "<\($0.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))>" } ?? "<unknown>"
            lines.append("\(base) - ??? \(image.name) \(image.architecture ?? "arm64") \(uuid) \(image.path ?? "")"
                .trimmingCharacters(in: .whitespaces))
        }
        lines.append("")

        if let command = atosCommand(for: details) {
            lines.append("Symbolicate the app's frames with its dSYM:")
            lines.append(command)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The frames of one stack, one per line.
    static func frameLines(_ frames: [CrashDetails.Frame], in details: CrashDetails) -> [String] {
        frames.enumerated().map { index, frame in
            let image = frame.imageIndex.flatMap { details.images.indices.contains($0) ? details.images[$0] : nil }
            let name = image?.name ?? "???"
            let address: String
            if let base = image?.loadAddress, let offset = frame.offset {
                address = hex(base &+ offset)
            } else {
                address = String(repeating: " ", count: 18)
            }
            let location: String
            if let symbol = frame.symbol {
                location = "\(symbol) + \(frame.symbolOffset ?? 0)"
            } else {
                location = "\(name) + \(frame.offset.map(String.init) ?? "?")"
            }
            return "\(String(index).padding(toLength: 4, withPad: " ", startingAt: 0))\(name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(address) \(location)"
        }
    }

    /// The `atos` command for every frame in the app's own binary, or `nil` if there are none.
    static func atosCommand(for details: CrashDetails) -> String? {
        guard let image = CrashIPSBuilder.mainImage(in: details),
              let index = details.images.firstIndex(of: image) else { return nil }
        let frames = details.threads.flatMap(\.frames) + (details.exceptionBacktrace ?? [])
        /// A missing load address is stood in for by the conventional one, which `atos` only uses
        /// to turn the addresses back into offsets.
        let base = image.loadAddress ?? 0x1_0000_0000
        let addresses = frames.filter { $0.imageIndex == index }.compactMap(\.offset)
        guard !addresses.isEmpty else { return nil }
        var unique: [UInt64] = []
        for offset in addresses where !unique.contains(offset) { unique.append(offset) }
        return "atos -arch \(image.architecture ?? "arm64") -o \(image.name).app.dSYM/Contents/Resources/DWARF/\(image.name) -l \(hex(base)) "
            + unique.map { hex(base &+ $0) }.joined(separator: " ")
    }

    private static func exceptionDescription(entry: CrashLogEntry, details: CrashDetails?) -> String {
        switch (details?.exceptionType, details?.signal) {
        case let (type?, signal?): return "\(type) (\(signal))"
        case let (type?, nil): return type
        case let (nil, signal?): return signal
        case (nil, nil): return entry.name
        }
    }

    private static func sessionMatchDescription(_ match: String) -> String {
        switch SessionJournal.Match(rawValue: match) {
        case .currentSession: return "the session that crashed"
        case .processIdentifier: return "matched by process identifier"
        case .timeWindow: return "matched by time window (best guess)"
        case nil: return match
        }
    }

    private static func field(_ name: String, _ value: String) -> String {
        (name + ":").padding(toLength: 21, withPad: " ", startingAt: 0) + value
    }

    private static func hex(_ value: UInt64) -> String {
        String(format: "0x%016llx", value)
    }
}
#endif
