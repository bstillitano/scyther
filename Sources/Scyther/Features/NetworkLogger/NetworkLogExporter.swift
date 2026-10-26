//
//  NetworkLogExporter.swift
//  Scyther
//
//  Created by Brandon Stillitano on 4/9/2026.
//

import Foundation

/// Packages captured ``HTTPRequest`` values into a shareable zip archive.
///
/// The archive is laid out as:
///
/// ```
/// <App-Name>-Network-Log-<timestamp>/
/// ├── network-log.har                 HAR 1.2 document (see ``NetworkLogHARBuilder``)
/// └── requests/
///     └── 001-GET-api.example.com/
///         ├── request.curl            cURL command to replay the request
///         ├── request-body.json       raw request body, when one was sent
///         └── response-body.json      raw response body, when one was received
/// ```
///
/// Zipping uses `NSFileCoordinator`'s `forUploading` option, which produces a zip of a directory
/// without any third-party dependency.
///
/// ## Usage
///
/// ```swift
/// let zipURL = try NetworkLogExporter.export(requests)
/// ```
enum NetworkLogExporter {
    /// Failures raised by ``export(_:in:now:)``.
    enum ExportError: Error, Equatable {
        /// No requests were supplied.
        case nothingToExport
        /// The file coordinator could not produce a zip.
        case zipFailed(String)
    }

    /// Builds the zip archive for `requests`.
    ///
    /// - Parameters:
    ///   - requests: The requests to include. Must not be empty.
    ///   - parent: The directory to write into. Defaults to the temporary directory.
    ///   - now: The timestamp used in the archive name.
    ///   - redact: Whether to pass every file through ``NetworkLogRedactor`` first.
    /// - Returns: The URL of the finished `.zip` file. The staging directory is removed.
    static func export(
        _ requests: [HTTPRequest],
        in parent: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
        redact: Bool = false
    ) throws -> URL {
        guard !requests.isEmpty else { throw ExportError.nothingToExport }
        let name = archiveName(now: now)
        let staging = try writeArchiveDirectory(for: requests, in: parent, name: name, redact: redact)
        defer { try? FileManager.default.removeItem(at: staging) }
        return try zip(directory: staging)
    }

    /// The host app's display name, falling back to its bundle name, then `App`.
    static var hostAppName: String {
        let bundle = Bundle.main
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "App"
    }

    /// The archive base name for a timestamp, e.g. `My-App-Network-Log-2026-09-04-091500`.
    ///
    /// Whitespace in the app name becomes `-`; any other character outside letters, digits,
    /// `.`, `-`, and `_` becomes `_`. An empty name falls back to `App`.
    ///
    /// - Parameters:
    ///   - now: The timestamp.
    ///   - timeZone: The zone used to format it. Defaults to the current zone.
    ///   - appName: The name to prefix. Defaults to ``hostAppName``.
    ///   - kind: What the archive holds, between the app name and the timestamp.
    static func archiveName(now: Date, timeZone: TimeZone = .current, appName: String = hostAppName,
                            kind: String = "Network-Log") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmed.isEmpty ? "App" : sanitised(trimmed.replacingOccurrences(of: " ", with: "-"))
        return "\(prefix)-\(kind)-\(formatter.string(from: now))"
    }

    /// The per-request folder name, e.g. `003-DELETE-api.example.com`.
    ///
    /// - Parameters:
    ///   - index: The 1-based position of the request in the export.
    ///   - request: The request.
    static func folderName(index: Int, request: HTTPRequest) -> String {
        let method = sanitised(request.requestMethod?.uppercased() ?? "UNKNOWN")
        let host = sanitised(request.host ?? "unknown-host")
        return String(format: "%03d-%@-%@", index, method, host)
    }

    /// Writes the un-zipped archive layout for `requests`.
    ///
    /// - Parameters:
    ///   - requests: The requests to include.
    ///   - parent: The directory to create the archive folder in.
    ///   - name: The archive folder name.
    ///   - redact: Whether to pass the HAR, bodies, and cURL commands through ``NetworkLogRedactor``.
    /// - Returns: The URL of the created folder.
    static func writeArchiveDirectory(
        for requests: [HTTPRequest],
        in parent: URL,
        name: String,
        redact: Bool = false
    ) throws -> URL {
        let fileManager = FileManager.default
        let root = parent.appendingPathComponent(name, isDirectory: true)
        try? fileManager.removeItem(at: root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        var har = NetworkLogHARBuilder.build(from: requests)
        if redact { har = NetworkLogRedactor.redact(har) }
        try NetworkLogHARBuilder.encode(har).write(to: root.appendingPathComponent("network-log.har"))

        let ordered = requests.sorted { ($0.requestDate ?? .distantPast) < ($1.requestDate ?? .distantPast) }
        for (offset, request) in ordered.enumerated() {
            let folder = root
                .appendingPathComponent("requests", isDirectory: true)
                .appendingPathComponent(folderName(index: offset + 1, request: request), isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

            var curl = request.requestCurl ?? ""
            if redact { curl = NetworkLogRedactor.redactCurl(curl) }
            try Data(curl.utf8).write(to: folder.appendingPathComponent("request.curl"))

            if let body = request.readRawData(request.getRequestBodyFilepath()), !body.isEmpty {
                let filename = "request-body.\(fileExtension(for: request.requestType, shortType: nil))"
                try scrubbed(body, redact: redact, isBase64: false).write(to: folder.appendingPathComponent(filename))
            }
            if let body = request.readRawData(request.getResponseBodyFilepath()), !body.isEmpty {
                let isImage = request.shortType == HTTPModelShortType.IMAGE.rawValue
                let filename = "response-body.\(fileExtension(for: request.responseType, shortType: request.shortType))"
                try scrubbed(body, redact: redact, isBase64: isImage).write(to: folder.appendingPathComponent(filename))
            }
        }
        return root
    }

    /// Zips a directory into a sibling `.zip` file using the file coordinator.
    ///
    /// - Parameter directory: The directory to zip.
    /// - Returns: The URL of the zip file, named after the directory.
    static func zip(directory: URL) throws -> URL {
        let destination = directory.deletingPathExtension().appendingPathExtension("zip")
        try? FileManager.default.removeItem(at: destination)

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: .forUploading,
            error: &coordinationError
        ) { zippedURL in
            do {
                try FileManager.default.copyItem(at: zippedURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinationError {
            throw ExportError.zipFailed(coordinationError.localizedDescription)
        }
        if let copyError {
            throw ExportError.zipFailed(copyError.localizedDescription)
        }
        return destination
    }

    // MARK: - Helpers

    /// Passes a stored body through the redactor when requested. Base64 bodies are never altered.
    private static func scrubbed(_ body: Data, redact: Bool, isBase64: Bool) -> Data {
        guard redact, !isBase64 else { return body }
        return Data(NetworkLogRedactor.redactText(String(decoding: body, as: UTF8.self)).utf8)
    }

    static func sanitised(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private static func fileExtension(for contentType: String?, shortType: String?) -> String {
        if shortType == HTTPModelShortType.IMAGE.rawValue {
            return "base64.txt"
        }
        let type = (contentType ?? "").lowercased()
        if type.contains("json") { return "json" }
        if type.contains("xml") { return "xml" }
        if type.contains("html") { return "html" }
        if type.hasPrefix("text/") { return "txt" }
        return "txt"
    }
}
