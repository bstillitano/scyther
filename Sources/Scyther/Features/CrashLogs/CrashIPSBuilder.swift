//
//  CrashIPSBuilder.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation

/// Writes a crash as an `.ips` file: the JSON crash report format iOS itself writes, which Xcode's
/// Devices window, Console and `CrashSymbolicator.py` all open and symbolicate.
///
/// An `.ips` file is two JSON documents, one per line and then the rest: a one-line header naming
/// the app and the report type (`bug_type` 309, a crash), then the report. The report's frames
/// name an image by index into `usedImages` and give an offset into it, and each image gives its
/// UUID and where it was loaded. That is everything a symbolicator needs: it finds the dSYM by
/// UUID and looks the offset up in it.
///
/// Fields the system writes that Scyther cannot know — the kernel's view of the process, code
/// signing, memory summaries — are left out. Symbolicators do not need them.
enum CrashIPSBuilder {
    /// Builds the `.ips` file for a crash.
    ///
    /// - Parameters:
    ///   - entry: The crash.
    ///   - details: Its details. Without them the report has no frames, only the crash's summary.
    ///   - isSimulator: Whether to mark the report as a Simulator one. The current process's by
    ///     default, since a crash is always exported from the device it happened on.
    /// - Returns: The file's contents.
    static func build(entry: CrashLogEntry, details: CrashDetails?, isSimulator: Bool = AppEnvironment.isSimulator) -> Data {
        let details = details ?? CrashDetails()
        let incident = entry.id.uuidString
        let timestamp = Self.timestamp(entry.timestamp)
        let processName = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? mainImage(in: details)?.name ?? "App"
        let (train, build) = splitOperatingSystem(details.operatingSystem ?? entry.osVersion)

        var header: [String: Any] = [
            "app_name": processName,
            "name": processName,
            "timestamp": timestamp,
            "app_version": entry.appVersion,
            "build_version": entry.buildNumber,
            "bug_type": "309",
            "os_version": details.operatingSystem ?? entry.osVersion,
            "incident_id": incident,
            "platform": isSimulator ? 7 : 2,
            "share_with_app_devs": 0,
            "is_first_party": 0,
        ]
        if let bundleIdentifier = details.bundleIdentifier { header["bundleID"] = bundleIdentifier }
        if let uuid = mainImage(in: details)?.uuid { header["slice_uuid"] = uuid.uuidString.lowercased() }

        var images = details.images.map(imageJSON)
        /// Frames whose binary is unknown still need an image to point at. The system uses an
        /// absolute image at base zero for the same purpose.
        let absoluteIndex = images.count
        images.append(["source": "A", "base": 0, "size": 0])

        /// Every thread needs an `id`: `CrashSymbolicator.py` reads it for each one. The system's
        /// is the kernel's thread identifier, which Scyther does not have; the index stands in.
        let threads: [[String: Any]] = details.threads.enumerated().map { index, thread in
            var json: [String: Any] = [
                "id": index,
                "frames": thread.frames.map { frameJSON($0, absoluteIndex: absoluteIndex) },
            ]
            if thread.crashed { json["triggered"] = true }
            return json
        }

        var report: [String: Any] = [
            "version": 2,
            "procName": processName,
            "incident": incident,
            "captureTime": timestamp,
            "cpuType": details.architecture?.hasPrefix("x86") == true ? "X86-64" : "ARM-64",
            "modelCode": details.hardwareModel ?? entry.deviceModel,
            "osVersion": ["train": train, "build": build, "releaseType": "User"],
            "bundleInfo": [
                "CFBundleShortVersionString": entry.appVersion,
                "CFBundleVersion": entry.buildNumber,
                "CFBundleIdentifier": details.bundleIdentifier ?? "",
            ],
            "exception": exceptionJSON(entry: entry, details: details),
            "termination": ["indicator": details.terminationReason ?? entry.reason ?? entry.name],
            "faultingThread": details.threads.firstIndex(where: \.crashed) ?? 0,
            "threads": threads,
            "usedImages": images,
        ]
        if let pid = details.processID { report["pid"] = pid }
        if let region = details.virtualMemoryRegionInfo { report["vmRegionInfo"] = region }
        if let backtrace = details.exceptionBacktrace, !backtrace.isEmpty {
            report["lastExceptionBacktrace"] = backtrace.map { frameJSON($0, absoluteIndex: absoluteIndex) }
        }
        if let reason = entry.reason {
            report["asi"] = ["Scyther": ["\(entry.name): \(reason)"]]
        }

        var data = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        data.append((try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data())
        return data
    }

    /// The app's own binary: the first image named after the process's executable, or the first
    /// image of all.
    static func mainImage(in details: CrashDetails) -> CrashDetails.BinaryImage? {
        let executable = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
        return details.images.first { $0.name == executable } ?? details.images.first
    }

    /// Splits `iPhone OS 18.0 (22A3354)` into its train and build.
    static func splitOperatingSystem(_ value: String) -> (train: String, build: String) {
        guard let open = value.lastIndex(of: "("), let close = value.lastIndex(of: ")"), open < close else {
            return (value, "")
        }
        let train = value[..<open].trimmingCharacters(in: .whitespaces)
        return (train, String(value[value.index(after: open)..<close]))
    }

    private static func imageJSON(_ image: CrashDetails.BinaryImage) -> [String: Any] {
        var json: [String: Any] = [
            "source": "P",
            "name": image.name,
            "base": image.loadAddress ?? 0,
            "size": 0,
            "arch": image.architecture ?? "arm64",
        ]
        if let uuid = image.uuid { json["uuid"] = uuid.uuidString.lowercased() }
        if let path = image.path { json["path"] = path }
        return json
    }

    private static func frameJSON(_ frame: CrashDetails.Frame, absoluteIndex: Int) -> [String: Any] {
        var json: [String: Any] = [
            "imageIndex": frame.imageIndex ?? absoluteIndex,
            "imageOffset": frame.offset ?? 0,
        ]
        if let symbol = frame.symbol {
            json["symbol"] = symbol
            json["symbolLocation"] = frame.symbolOffset ?? 0
        }
        return json
    }

    private static func exceptionJSON(entry: CrashLogEntry, details: CrashDetails) -> [String: Any] {
        let codes = details.exceptionCodes.isEmpty ? [0, 0] : details.exceptionCodes
        var json: [String: Any] = [
            "type": details.exceptionType ?? "EXC_CRASH",
            "codes": codes.map { String(format: "0x%016llx", $0) }.joined(separator: ", "),
            "rawCodes": codes,
        ]
        if let signal = details.signal { json["signal"] = signal }
        return json
    }

    /// The format `.ips` files stamp themselves with, such as `2026-10-26 16:53:56.00 +1100`.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return formatter.string(from: date)
    }
}
#endif
