//
//  SessionJournal.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation
import os

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

        /// The session was the only one of the crashed build active during the window MetricKit's
        /// payload covers. A strong guess, but a guess.
        case timeWindow
    }

    /// Shared instance.
    static let shared = SessionJournal()

    /// The directory every session's directory sits in.
    let root: URL

    /// How many sessions are kept, not counting those a crash refers to.
    static let maxSessions = 10

    /// How many of the sessions stored crashes refer to are kept. The rest are removed, and their
    /// crashes export without session logs. Each session can hold ten megabytes, and fifty crashes
    /// could otherwise keep fifty sessions.
    static let maxPinnedSessions = 10

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

    /// Whether a session has started. Read on every console line and request, from any thread, so
    /// that nothing is formatted or queued before ``start(pinned:now:)`` — or ever, when Scyther
    /// is not started.
    private let isRecording = OSAllocatedUnfairLock(initialState: false)

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
        /// Only what capture needs happens before returning. Pruning reads every session's files,
        /// and runs on the queue after.
        queue.sync {
            closeHandles()
            current = session
            let directory = directory(for: session.id)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(session) {
                try? data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
            }
        }
        isRecording.withLock { $0 = true }
        queue.async {
            self.prune(current: session.id, pinned: pinned)
        }
        return session.id
    }

    /// The running session's identifier, or `nil` before ``start(pinned:now:)``.
    var currentSessionID: UUID? {
        onQueue { current?.id }
    }

    /// Appends console lines.
    func recordConsole(_ lines: [String], source: String, at date: Date = Date()) {
        guard !lines.isEmpty, isRecording.withLock({ $0 }) else { return }
        queue.async {
            let stamp = Self.timestamp(date)
            let text = lines.map { "\(stamp) [\(source)] \($0)\n" }.joined()
            self.append(Data(text.utf8), to: "console.log", cap: Self.consoleCap)
        }
    }

    /// Appends a completed request as a HAR entry. The entry is built on the journal's queue,
    /// because building it reads the request's bodies from disk.
    func recordRequest(_ request: HTTPRequest) {
        guard isRecording.withLock({ $0 }) else { return }
        queue.async {
            guard self.current != nil,
                  let entry = NetworkLogHARBuilder.build(from: [request]).log.entries.first,
                  var line = try? JSONEncoder().encode(entry) else { return }
            line.append(0x0A)
            self.append(line, to: "network.jsonl", cap: Self.networkCap)
        }
    }

    /// Removes the network traffic of every session, as clearing the network log does. The
    /// journal's copy must not outlive the log the developer chose to clear.
    func clearNetworkLogs() {
        clear("network.jsonl")
    }

    /// Removes the console output of every session, as clearing the console does.
    func clearConsoleLogs() {
        clear("console.log")
    }

    private func clear(_ name: String) {
        queue.async {
            try? self.handles[name]?.close()
            self.handles[name] = nil
            let contents = (try? FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil)) ?? []
            for directory in contents {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
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
    /// The process identifier settles it when MetricKit reports one (iOS 17 and later), as long as
    /// the session with that identifier was also active during the payload's window: identifiers
    /// are reused, and the journal keeps several sessions. Without one, a session is chosen only
    /// when it is the *only* earlier session of the crashed build that was active during the
    /// window. A wide window covers several launches, and attaching the wrong launch's logs to a
    /// crash is worse than attaching none.
    ///
    /// - Parameters:
    ///   - start: The start of the payload's window.
    ///   - end: The end of the payload's window.
    ///   - processID: The crashed process's identifier, if MetricKit reported it.
    ///   - buildNumber: The crashed build's number.
    ///   - sessions: The sessions to choose from, newest first.
    ///   - current: The running session, which cannot be the one that crashed.
    /// - Returns: The session and how it was matched, or `nil` if none fits, or several do.
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
        let active = sessions.filter { session in
            session.id != current
                && session.startedAt <= upper
                && (session.lastActivity ?? session.startedAt) >= lower
        }

        if let processID, let session = active.first(where: { $0.processID == processID }) {
            return (session, .processIdentifier)
        }
        let candidates = active.filter { buildNumber == nil || $0.buildNumber == buildNumber }
        guard candidates.count == 1, let session = candidates.first else { return nil }
        return (session, .timeWindow)
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
    ///
    /// The newest line always survives, however long it is. Cutting at the first line break after
    /// the midpoint alone would empty the file whenever the newest line is longer than everything
    /// before it — one large response body would wipe the whole network log.
    static func dropOldestHalf(of url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let middle = data.index(data.startIndex, offsetBy: data.count / 2)
        var cut = data[middle...].firstIndex(of: 0x0A).map { data.index(after: $0) } ?? data.endIndex
        if cut == data.endIndex {
            /// The start of the last line: just past the line break before the file's final one.
            let body = data.last == 0x0A ? data[..<data.index(before: data.endIndex)] : data[...]
            cut = body.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
        }
        try? Data(data[cut...]).write(to: url, options: .atomic)
    }

    private func closeHandles() {
        for handle in handles.values {
            try? handle.close()
        }
        handles.removeAll()
    }

    /// Keeps the running session, the newest ``maxSessions`` others, and the newest
    /// ``maxPinnedSessions`` that stored crashes refer to. Removes everything else, including any
    /// directory without a readable `session.json` — a launch killed while it started — which
    /// would otherwise never be listed, and so never be removed.
    private func prune(current: UUID, pinned: Set<UUID>) {
        let sessions = self.sessions().filter { $0.id != current }
        let keptPinned = Set(sessions.filter { pinned.contains($0.id) }.prefix(Self.maxPinnedSessions).map(\.id))
        let keptOthers = Set(sessions.filter { !pinned.contains($0.id) }.prefix(Self.maxSessions).map(\.id))
        let kept = keptPinned.union(keptOthers).union([current])

        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for directory in contents {
            guard let id = UUID(uuidString: directory.lastPathComponent), kept.contains(id) else {
                try? FileManager.default.removeItem(at: directory)
                continue
            }
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
