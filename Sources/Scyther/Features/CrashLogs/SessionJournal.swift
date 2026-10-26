//
//  SessionJournal.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation

/// Writes each launch's console output and network traffic to disk as it happens, so that a crash
/// can be exported with what the app was doing when it died.
///
/// The console log and the network log both live in memory, and a crash takes them with it. A
/// crash MetricKit reports arrives a launch later, by which time nothing of the session it happened
/// in is left — unless it was written down as it went. Each launch gets a directory:
///
/// ```
/// Application Support/Scyther/Sessions/<session id>/
/// ├── session.json     SessionJournal.Session: when it started, its process identifier, the build
/// ├── console.log      one line per console line, timestamped, newest last
/// └── network.jsonl    one HAR entry per completed request, newest last
/// ```
///
/// Each file is capped, and drops its oldest half when it reaches the cap, so the newest activity
/// — the activity nearest a crash — is what survives. The newest ``maxSessions`` sessions are
/// kept, plus any session a stored crash refers to, until that crash is cleared.
///
/// Writes happen on a private serial queue. A crash the exception handler catches flushes the
/// queue first, so nothing is lost; any other crash can lose the writes still queued, which is at
/// most a moment's worth.
final class SessionJournal: @unchecked Sendable {
    /// A recorded session.
    struct Session: Codable, Equatable, Sendable {
        /// The session's identifier, which is also its directory's name.
        var id: UUID

        /// The process identifier the session ran as.
        var processID: Int

        /// When the session started.
        var startedAt: Date

        /// The app's version string.
        var appVersion: String

        /// The app's build number.
        var buildNumber: String

        /// When the session last wrote anything. Not stored: read from the files' dates.
        var lastActivity: Date?

        private enum CodingKeys: String, CodingKey {
            case id, processID, startedAt, appVersion, buildNumber
        }
    }

    /// How a crash was tied to the session it happened in.
    enum Match: String, Codable, Sendable {
        /// The crash happened in the running session, which the exception handler knows.
        case currentSession

        /// MetricKit reported the crashed process's identifier, and a session ran as it.
        case processIdentifier

        /// The session was active during the window MetricKit's payload covers. The best guess
        /// available, but a guess: a wide window can cover more than one session.
        case timeWindow
    }

    /// Shared instance.
    static let shared = SessionJournal()

    /// The directory every session's directory sits in.
    let root: URL

    /// How many sessions are kept, not counting those a crash refers to.
    static let maxSessions = 10

    /// The size at which the console log drops its oldest half.
    static let consoleCap = 2 * 1024 * 1024

    /// The size at which the network log drops its oldest half.
    static let networkCap = 8 * 1024 * 1024

    /// The running session, once ``start(pinned:now:)`` has run. Read and written on ``queue``.
    private var current: Session?

    /// Open handles for the running session's files, by file name. Used on ``queue`` only.
    private var handles: [String: FileHandle] = [:]

    /// Serialises every write.
    private let queue = DispatchQueue(label: "com.scyther.session-journal", qos: .utility)

    /// Marks ``queue``, so ``flush()`` can tell when it is already on it.
    private let queueKey = DispatchSpecificKey<Bool>()

    /// Creates a journal.
    ///
    /// - Parameter root: The directory to write in. Scyther's own by default.
    init(root: URL = SessionJournal.defaultRoot) {
        self.root = root
        queue.setSpecific(key: queueKey, value: true)
    }

    /// `Application Support/Scyther/Sessions`.
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scyther", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    // MARK: - Recording

    /// Starts a session, and prunes old ones.
    ///
    /// - Parameters:
    ///   - pinned: Sessions to keep whatever their age: the ones stored crashes refer to.
    ///   - now: The session's start time.
    /// - Returns: The new session's identifier.
    @discardableResult
    func start(pinned: Set<UUID>, now: Date = Date()) -> UUID {
        let session = Session(
            id: UUID(),
            processID: Int(getpid()),
            startedAt: now,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        )
        queue.sync {
            closeHandles()
            current = session
            let directory = directory(for: session.id)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(session) {
                try? data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
            }
            prune(keeping: pinned.union([session.id]))
        }
        return session.id
    }

    /// The running session's identifier, or `nil` before ``start(pinned:now:)``.
    var currentSessionID: UUID? {
        onQueue { current?.id }
    }

    /// Appends console lines.
    func recordConsole(_ lines: [String], source: String, at date: Date = Date()) {
        guard !lines.isEmpty else { return }
        let stamp = Self.timestamp(date)
        let text = lines.map { "\(stamp) [\(source)] \($0)\n" }.joined()
        queue.async {
            self.append(Data(text.utf8), to: "console.log", cap: Self.consoleCap)
        }
    }

    /// Appends a completed request as a HAR entry. The entry is built on the journal's queue,
    /// because building it reads the request's bodies from disk.
    func recordRequest(_ request: HTTPRequest) {
        queue.async {
            guard self.current != nil,
                  let entry = NetworkLogHARBuilder.build(from: [request]).log.entries.first,
                  var line = try? JSONEncoder().encode(entry) else { return }
            line.append(0x0A)
            self.append(line, to: "network.jsonl", cap: Self.networkCap)
        }
    }

    /// Waits for every queued write to land. Called by the exception handler before the process
    /// dies. Does nothing if called on the journal's own queue, which would deadlock.
    func flush() {
        guard DispatchQueue.getSpecific(key: queueKey) == nil else { return }
        queue.sync {
            for handle in handles.values {
                try? handle.synchronize()
            }
        }
    }

    // MARK: - Reading

    /// Every recorded session, newest first.
    func sessions() -> [Session] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return contents.compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
                  var session = try? JSONDecoder().decode(Session.self, from: data) else { return nil }
            session.lastActivity = lastActivity(in: directory) ?? session.startedAt
            return session
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    /// A session's console log, or `nil` if it wrote none.
    func consoleLog(for id: UUID) -> String? {
        flushIfCurrent(id)
        return (try? Data(contentsOf: directory(for: id).appendingPathComponent("console.log")))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// A session's completed requests, oldest first, as a HAR document — or `nil` if it made none.
    func networkLog(for id: UUID) -> HARLog? {
        flushIfCurrent(id)
        guard let data = try? Data(contentsOf: directory(for: id).appendingPathComponent("network.jsonl")) else {
            return nil
        }
        let decoder = JSONDecoder()
        let entries = data.split(separator: 0x0A).compactMap { try? decoder.decode(HAREntry.self, from: Data($0)) }
        guard !entries.isEmpty else { return nil }
        return HARLog(log: HARLogBody(
            version: "1.2",
            creator: HARCreator(name: "Scyther", version: NetworkLogHARBuilder.defaultCreatorVersion),
            comment: nil,
            entries: entries
        ))
    }

    /// The session a MetricKit crash happened in.
    ///
    /// The process identifier settles it when MetricKit reports one (iOS 17 and later). Without
    /// it, the newest earlier session of the same build that was active during the payload's
    /// window is taken — which is the crashed session whenever, as usual, the diagnostic arrives on
    /// the launch straight after the crash.
    ///
    /// - Parameters:
    ///   - start: The start of the payload's window.
    ///   - end: The end of the payload's window.
    ///   - processID: The crashed process's identifier, if MetricKit reported it.
    ///   - buildNumber: The crashed build's number.
    ///   - sessions: The sessions to choose from, newest first.
    ///   - current: The running session, which cannot be the one that crashed.
    /// - Returns: The session and how it was matched, or `nil` if none fits.
    static func session(
        crashedBetween start: Date,
        and end: Date,
        processID: Int?,
        buildNumber: String?,
        in sessions: [Session],
        excluding current: UUID?
    ) -> (session: Session, match: Match)? {
        let tolerance: TimeInterval = 60
        let lower = min(start, end).addingTimeInterval(-tolerance)
        let upper = max(start, end).addingTimeInterval(tolerance)
        let earlier = sessions.filter { $0.id != current && $0.startedAt <= upper }

        if let processID, let session = earlier.first(where: { $0.processID == processID }) {
            return (session, .processIdentifier)
        }
        let candidate = earlier.first { session in
            (session.lastActivity ?? session.startedAt) >= lower
                && (buildNumber == nil || session.buildNumber == buildNumber)
        }
        return candidate.map { ($0, .timeWindow) }
    }

    // MARK: - Files

    private func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Appends to one of the running session's files. On ``queue`` only.
    private func append(_ data: Data, to name: String, cap: Int) {
        guard let current else { return }
        let url = directory(for: current.id).appendingPathComponent(name)
        if handles[name] == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handles[name] = try? FileHandle(forWritingTo: url)
            _ = try? handles[name]?.seekToEnd()
        }
        guard let handle = handles[name] else { return }
        try? handle.write(contentsOf: data)

        if let size = try? handle.offset(), size > UInt64(cap) {
            try? handle.close()
            handles[name] = nil
            Self.dropOldestHalf(of: url)
        }
    }

    /// Rewrites a file without its oldest half, cut at a line boundary.
    static func dropOldestHalf(of url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let middle = data.index(data.startIndex, offsetBy: data.count / 2)
        let cut = data[middle...].firstIndex(of: 0x0A).map { data.index(after: $0) } ?? data.endIndex
        try? Data(data[cut...]).write(to: url, options: .atomic)
    }

    private func closeHandles() {
        for handle in handles.values {
            try? handle.close()
        }
        handles.removeAll()
    }

    /// Removes every session directory not in `ids`, beyond the newest ``maxSessions``.
    private func prune(keeping ids: Set<UUID>) {
        let excess = sessions().dropFirst(Self.maxSessions).filter { !ids.contains($0.id) }
        for session in excess {
            try? FileManager.default.removeItem(at: directory(for: session.id))
        }
    }

    private func lastActivity(in directory: URL) -> Date? {
        ["console.log", "network.jsonl", "session.json"].compactMap { name in
            try? directory.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
    }

    private func flushIfCurrent(_ id: UUID) {
        if currentSessionID == id { flush() }
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) == nil ? queue.sync(execute: body) : body()
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }
}
#endif
