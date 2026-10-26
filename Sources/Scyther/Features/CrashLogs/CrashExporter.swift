//
//  CrashExporter.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation

/// Packages crashes into a zip archive with everything needed to debug them.
///
/// The archive is laid out as:
///
/// ```
/// <App-Name>-Crash-Report-<timestamp>/
/// ├── README.txt                       what each file is, and how to symbolicate
/// └── 01-EXC_BREAKPOINT-2026-10-26-091500/
///     ├── report.txt                   the crash in Apple's text layout, with an atos command
///     ├── crash.ips                    the crash as an .ips file, for Xcode, Console and CrashSymbolicator.py
///     ├── diagnostic.json              the raw MetricKit diagnostic, for a MetricKit crash
///     ├── console.log                  the console output of the session that crashed
///     └── network-log.har              the requests that session completed, as HAR 1.2
/// ```
///
/// The console log and network log come from ``SessionJournal``, and are there only when the
/// crash could be tied to its session. Redaction passes them through ``NetworkLogRedactor``, as
/// the network log export does; the reports themselves hold no request data and are left alone.
enum CrashExporter {
    /// Failures raised by ``export(_:redact:in:now:artifacts:journal:)``.
    enum ExportError: Error, Equatable {
        /// No crashes were supplied.
        case nothingToExport
    }

    /// Builds the zip archive for `crashes`.
    ///
    /// - Parameters:
    ///   - crashes: The crashes to include. Must not be empty.
    ///   - redact: Whether to pass the console and network logs through ``NetworkLogRedactor``.
    ///   - parent: The directory to write into. Defaults to the temporary directory.
    ///   - now: The timestamp used in the archive name.
    ///   - artifacts: Where the crashes' details are read from.
    ///   - journal: Where their sessions' logs are read from.
    /// - Returns: The URL of the finished `.zip` file. The staging directory is removed.
    static func export(
        _ crashes: [CrashLogEntry],
        redact: Bool,
        in parent: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
        artifacts: CrashArtifactStore = .shared,
        journal: SessionJournal = .shared
    ) throws -> URL {
        guard !crashes.isEmpty else { throw ExportError.nothingToExport }
        let name = NetworkLogExporter.archiveName(now: now, kind: "Crash-Report")
        let staging = try writeArchiveDirectory(for: crashes, in: parent, name: name, redact: redact,
                                                artifacts: artifacts, journal: journal)
        defer { try? FileManager.default.removeItem(at: staging) }
        return try NetworkLogExporter.zip(directory: staging)
    }

    /// Writes the un-zipped archive layout.
    ///
    /// - Returns: The URL of the created folder.
    static func writeArchiveDirectory(
        for crashes: [CrashLogEntry],
        in parent: URL,
        name: String,
        redact: Bool,
        artifacts: CrashArtifactStore = .shared,
        journal: SessionJournal = .shared
    ) throws -> URL {
        let fileManager = FileManager.default
        let root = parent.appendingPathComponent(name, isDirectory: true)
        try? fileManager.removeItem(at: root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(readme.utf8).write(to: root.appendingPathComponent("README.txt"))

        let sessions = Dictionary(journal.sessions().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, crash) in crashes.enumerated() {
            let folder = root.appendingPathComponent(folderName(index: index + 1, crash: crash), isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

            let details = artifacts.details(for: crash.id)
            let session = crash.sessionID.flatMap { sessions[$0] }
            try Data(CrashReportFormatter.report(entry: crash, details: details, session: session).utf8)
                .write(to: folder.appendingPathComponent("report.txt"))
            try CrashIPSBuilder.build(entry: crash, details: details)
                .write(to: folder.appendingPathComponent("crash.ips"))
            if let diagnostic = artifacts.diagnostic(for: crash.id) {
                try diagnostic.write(to: folder.appendingPathComponent("diagnostic.json"))
            }

            guard let sessionID = crash.sessionID else { continue }
            if let console = journal.consoleLog(for: sessionID) {
                let text = redact ? NetworkLogRedactor.redactText(console) : console
                try Data(text.utf8).write(to: folder.appendingPathComponent("console.log"))
            }
            if var har = journal.networkLog(for: sessionID) {
                if redact { har = NetworkLogRedactor.redact(har) }
                try NetworkLogHARBuilder.encode(har).write(to: folder.appendingPathComponent("network-log.har"))
            }
        }
        return root
    }

    /// A crash's folder name, such as `01-EXC_BREAKPOINT-2026-10-26-091500`.
    static func folderName(index: Int, crash: CrashLogEntry, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let kind = crash.name.components(separatedBy: " ").first ?? crash.name
        return String(format: "%02d-%@-%@", index, NetworkLogExporter.sanitised(kind), formatter.string(from: crash.timestamp))
    }

    /// The archive's README.
    static let readme = """
    Crash report exported by Scyther
    ================================

    One folder per crash. In each:

    report.txt         The crash in the layout of Apple's text crash reports. Frames show the
                       binary and offset, and a symbol where the device could name one. The
                       last section is an atos command that symbolicates the app's own frames.

    crash.ips          The crash as an .ips file, the format iOS writes. Open it in Xcode
                       (Window > Devices and Simulators > View Device Logs, or drag it in), in
                       Console, or symbolicate it from the command line:

                         xcrun python3 \\
                           "$(xcode-select -p)/../SharedFrameworks/CoreSymbolicationDT.framework/Versions/A/Resources/CrashSymbolicator.py" \\
                           -d MyApp.app.dSYM -p crash.ips

                       Symbolication needs the dSYM of the exact build that crashed. Its UUID
                       is in the Binary Images section of report.txt; check it with
                       `dwarfdump --uuid MyApp.app.dSYM`.

    diagnostic.json    For a crash MetricKit reported: the diagnostic exactly as MetricKit
                       delivered it, every thread included.

    console.log        The console output of the session that crashed, newest last.
    network-log.har    The requests that session completed, as HAR 1.2. Opens in Charles,
                       Proxyman, or Chrome DevTools.

    The console and network logs are present only when the crash could be tied to its session.
    For a MetricKit crash before iOS 17, that means it was the only launch of the build active
    in MetricKit's reporting window; report.txt says how each crash was matched.

    Crashes MetricKit reports carry no Swift error message. A force unwrap of nil, for example,
    is reported as EXC_BREAKPOINT (SIGTRAP); the stack says where, and console.log may say why.
    """
}
#endif
