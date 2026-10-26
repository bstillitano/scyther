//
//  CrashArtifactStore.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation

/// Stores the files that belong to one crash, in a directory named after its ``CrashLogEntry/id``.
///
/// ```
/// Application Support/Scyther/Crashes/<entry id>/
/// ├── details.json      CrashDetails: threads, binary images, exception codes
/// └── diagnostic.json   the raw MetricKit diagnostic, for a MetricKit crash
/// ```
///
/// Kept out of `UserDefaults`, where the crash list lives, because a crash's threads and images
/// run to hundreds of kilobytes. ``CrashLogger`` removes a crash's directory when the crash leaves
/// the list.
final class CrashArtifactStore: @unchecked Sendable {
    /// Shared instance.
    static let shared = CrashArtifactStore()

    /// The directory every crash's directory sits in.
    let root: URL

    /// Creates a store.
    ///
    /// - Parameter root: The directory to store in. Scyther's own by default.
    init(root: URL = CrashArtifactStore.defaultRoot) {
        self.root = root
    }

    /// `Application Support/Scyther/Crashes`.
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scyther", isDirectory: true)
            .appendingPathComponent("Crashes", isDirectory: true)
    }

    /// The directory for one crash.
    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Writes a crash's details. Safe to call from the exception handler: it is plain file I/O.
    func writeDetails(_ details: CrashDetails, for id: UUID) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(details) else { return }
        write(data, named: "details.json", for: id)
    }

    /// Reads a crash's details, or `nil` if none were written.
    func details(for id: UUID) -> CrashDetails? {
        guard let data = try? Data(contentsOf: directory(for: id).appendingPathComponent("details.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(CrashDetails.self, from: data)
    }

    /// Writes the raw MetricKit diagnostic for a crash.
    func writeDiagnostic(_ json: Data, for id: UUID) {
        write(json, named: "diagnostic.json", for: id)
    }

    /// Reads the raw MetricKit diagnostic for a crash, or `nil` if there is none.
    func diagnostic(for id: UUID) -> Data? {
        try? Data(contentsOf: directory(for: id).appendingPathComponent("diagnostic.json"))
    }

    /// Removes every crash directory that is not in `ids`.
    func prune(keeping ids: Set<UUID>) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            guard let id = UUID(uuidString: url.lastPathComponent), !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func write(_ data: Data, named name: String, for id: UUID) {
        let directory = directory(for: id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
#endif
