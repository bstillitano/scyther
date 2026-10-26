//
//  CrashExportTests.swift
//  ScytherTests
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
@testable import Scyther
import Foundation
import Testing

/// A fresh directory under the temporary directory, removed by the caller.
private func temporaryDirectory(_ name: String = #function) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CrashExportTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Splits an `.ips` file into its header and report.
private func parseIPS(_ data: Data) throws -> (header: [String: Any], report: [String: Any]) {
    let newline = try #require(data.firstIndex(of: 0x0A))
    let header = try #require(try JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any])
    let report = try #require(try JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any])
    return (header, report)
}

// MARK: - Capture

@Suite struct CrashDetailsCaptureTests {

    /// Frames of this very process resolve to a binary with a UUID and a load address, and an
    /// offset that lands back on the same address.
    @Test func resolvesFramesOfThisProcess() throws {
        var resolver = ProcessImageResolver()
        let addresses = Foundation.Thread.callStackReturnAddresses.map(\.uintValue)

        let frames = addresses.map { resolver.frame(for: $0) }

        let first = try #require(frames.first)
        let image = try #require(first.imageIndex.map { resolver.images[$0] })
        #expect(image.uuid != nil)
        #expect(image.loadAddress.map { $0 + (first.offset ?? 0) } == UInt64(addresses[0]))
        #expect(resolver.images.count < frames.count, "each image is listed once, however many frames point into it")
    }

    @Test func resolvesAnUnmappedAddressToAnEmptyFrame() {
        var resolver = ProcessImageResolver()

        #expect(resolver.frame(for: 0) == CrashDetails.Frame())
        #expect(resolver.images.isEmpty)
    }

    @Test func capturesAnExceptionAsAnAbort() {
        let exception = NSException(name: NSExceptionName("ScytherTestException"), reason: "testing", userInfo: nil)
        let stack = Foundation.Thread.callStackReturnAddresses.map(\.uintValue)

        let details = CrashDetails.capture(exception: exception, crashingStack: stack)

        #expect(details.exceptionType == "EXC_CRASH")
        #expect(details.signal == "SIGABRT")
        #expect(details.terminationReason == "*** Terminating app due to uncaught exception 'ScytherTestException', reason: 'testing'")
        #expect(details.processID == Int(getpid()))
        #expect(details.threads.count == 1)
        #expect(details.crashedThread?.frames.count == stack.count)
        #expect(details.exceptionBacktrace == [], "an exception that was never raised has no backtrace")
        #expect(details.operatingSystem?.hasPrefix("iPhone OS ") == true)
        #expect(details.hardwareModel?.isEmpty == false)
    }
}

// MARK: - MetricKit details

@Suite struct CrashDiagnosticDetailsTests {

    @Test func keepsEveryThreadAndMarksTheCrashedOne() {
        let details = CrashDiagnosticMapper.details(for: CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap),
                                                    symbolicator: NoSymbolicator())

        #expect(details.threads.count == 2)
        #expect(details.threads.map(\.crashed) == [false, true])
        #expect(details.crashedThread?.frames.map(\.offset) == [24_576, 12_000, 99_024])
        #expect(details.exceptionType == "EXC_BREAKPOINT")
        #expect(details.signal == "SIGTRAP")
        #expect(details.exceptionCodes == [1])
        #expect(details.hardwareModel == "iPhone17,1")
        #expect(details.architecture == "arm64")
    }

    /// One image per binary, with the load address recovered from a frame's address and offset.
    @Test func derivesEachImageAndItsLoadAddress() throws {
        let details = CrashDiagnosticMapper.details(for: CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap),
                                                    symbolicator: NoSymbolicator())

        #expect(details.images.map(\.name) == ["libsystem_kernel.dylib", "ExampleApp", "dyld"])
        let app = try #require(details.images.first { $0.name == "ExampleApp" })
        #expect(app.uuid == CrashDiagnosticFixtures.appUUID)
        #expect(app.loadAddress == 4_340_776_960)
        let frames = try #require(details.crashedThread?.frames)
        #expect(frames.map(\.imageIndex) == [1, 1, 2])
    }

    @Test func symbolicatesWhereItCan() {
        let details = CrashDiagnosticMapper.details(for: CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap),
                                                    symbolicator: FixedSymbolicator(uuid: CrashDiagnosticFixtures.appUUID))

        #expect(details.crashedThread?.frames.map(\.symbol) == ["frame@24576", "frame@12000", nil])
    }

    @Test func keepsTheExceptionCodeAndRegion() {
        let json = #"{"diagnosticMetaData": {"exceptionType": 1, "signal": 11, "exceptionCode": 2, "virtualMemoryRegionInfo": "0 is not in any region.", "pid": 812, "bundleIdentifier": "com.example.app", "platformArchitecture": "arm64e"}}"#

        let details = CrashDiagnosticMapper.details(for: CrashDiagnosticFixtures.record(json), symbolicator: NoSymbolicator())

        #expect(details.exceptionCodes == [2])
        #expect(details.virtualMemoryRegionInfo == "0 is not in any region.")
        #expect(details.processID == 812)
        #expect(details.bundleIdentifier == "com.example.app")
        #expect(details.architecture == "arm64e")
    }
}

// MARK: - IPS

@Suite struct CrashIPSBuilderTests {

    private var trap: (CrashLogEntry, CrashDetails) {
        let record = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)
        return (CrashDiagnosticMapper.entry(for: record, symbolicator: NoSymbolicator()),
                CrashDiagnosticMapper.details(for: record, symbolicator: NoSymbolicator()))
    }

    @Test func writesAHeaderLineAndAReport() throws {
        let (entry, details) = trap

        let (header, report) = try parseIPS(CrashIPSBuilder.build(entry: entry, details: details, isSimulator: false))

        #expect(header["bug_type"] as? String == "309")
        #expect(header["incident_id"] as? String == entry.id.uuidString)
        #expect(header["os_version"] as? String == "iPhone OS 18.0 (22A3354)")
        #expect(header["platform"] as? Int == 2)
        #expect(report["version"] as? Int == 2)
        #expect(report["modelCode"] as? String == "iPhone17,1")
        #expect((report["osVersion"] as? [String: String]) == ["train": "iPhone OS 18.0", "build": "22A3354", "releaseType": "User"])
        #expect(report["faultingThread"] as? Int == 1)
    }

    @Test func recordsTheException() throws {
        let (entry, details) = trap

        let report = try parseIPS(CrashIPSBuilder.build(entry: entry, details: details)).report
        let exception = try #require(report["exception"] as? [String: Any])

        #expect(exception["type"] as? String == "EXC_BREAKPOINT")
        #expect(exception["signal"] as? String == "SIGTRAP")
        #expect(exception["codes"] as? String == "0x0000000000000001")
        #expect(exception["rawCodes"] as? [Int] == [1])
    }

    /// Frames point at images by index, and every image a symbolicator needs has its UUID and
    /// base. A frame with no known binary points at an absolute image at base zero.
    @Test func linksFramesToImages() throws {
        var (entry, details) = trap
        details.threads[0].frames.append(CrashDetails.Frame(imageIndex: nil, offset: 77))

        let report = try parseIPS(CrashIPSBuilder.build(entry: entry, details: details)).report
        let images = try #require(report["usedImages"] as? [[String: Any]])
        let threads = try #require(report["threads"] as? [[String: Any]])
        let crashed = try #require(threads[1]["frames"] as? [[String: Any]])
        let orphan = try #require((threads[0]["frames"] as? [[String: Any]])?.last)

        #expect(threads[1]["triggered"] as? Bool == true)
        #expect(crashed.first?["imageIndex"] as? Int == 1)
        #expect(crashed.first?["imageOffset"] as? Int == 24_576)
        #expect(images[1]["uuid"] as? String == CrashDiagnosticFixtures.appUUID.uuidString.lowercased())
        #expect(images[1]["base"] as? Int == 4_340_776_960)
        #expect(images.last?["source"] as? String == "A")
        #expect(orphan["imageIndex"] as? Int == images.count - 1)
    }

    @Test func includesTheExceptionBacktraceAndReason() throws {
        let entry = CrashLogEntry(name: "NSRangeException", reason: "index 3 beyond bounds", stackTrace: [],
                                  appVersion: "1", buildNumber: "1", osVersion: "18.0", deviceModel: "iPhone")
        var details = CrashDetails()
        details.exceptionBacktrace = [CrashDetails.Frame(imageIndex: 0, offset: 10, symbol: "-[A b]", symbolOffset: 4)]
        details.images = [CrashDetails.BinaryImage(name: "CoreFoundation", uuid: UUID(), loadAddress: 0x1000, path: nil, architecture: "arm64")]

        let report = try parseIPS(CrashIPSBuilder.build(entry: entry, details: details)).report
        let backtrace = try #require(report["lastExceptionBacktrace"] as? [[String: Any]])

        #expect(backtrace.first?["symbol"] as? String == "-[A b]")
        #expect(backtrace.first?["symbolLocation"] as? Int == 4)
        #expect((report["asi"] as? [String: [String]])?["Scyther"] == ["NSRangeException: index 3 beyond bounds"])
    }

    @Test func buildsAReportWithoutDetails() throws {
        let entry = CrashLogEntry(name: "NSGenericException", reason: nil, stackTrace: ["0 frame"],
                                  appVersion: "1", buildNumber: "1", osVersion: "17.0", deviceModel: "iPhone")

        let report = try parseIPS(CrashIPSBuilder.build(entry: entry, details: nil)).report

        #expect((report["threads"] as? [Any])?.isEmpty == true)
        #expect((report["exception"] as? [String: Any])?["type"] as? String == "EXC_CRASH")
    }

    @Test(arguments: [
        ("iPhone OS 18.0 (22A3354)", "iPhone OS 18.0", "22A3354"),
        ("iPhone OS 17.4.1 (21E236)", "iPhone OS 17.4.1", "21E236"),
        ("17.0", "17.0", ""),
    ])
    func splitsTheOperatingSystem(value: String, train: String, build: String) {
        let split = CrashIPSBuilder.splitOperatingSystem(value)

        #expect(split.train == train)
        #expect(split.build == build)
    }
}

// MARK: - Report

@Suite struct CrashReportFormatterTests {

    private var trap: (CrashLogEntry, CrashDetails) {
        let record = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)
        return (CrashDiagnosticMapper.entry(for: record, symbolicator: NoSymbolicator()),
                CrashDiagnosticMapper.details(for: record, symbolicator: NoSymbolicator()))
    }

    @Test func writesTheHeaderAndException() {
        let (entry, details) = trap

        let report = CrashReportFormatter.report(entry: entry, details: details)

        #expect(report.contains("Hardware Model:      iPhone17,1"))
        #expect(report.contains("Exception Type:      EXC_BREAKPOINT (SIGTRAP)"))
        #expect(report.contains("Exception Codes:     0x0000000000000001"))
        #expect(report.contains("Termination Reason:  Namespace SIGNAL, Code 5 Trace/BPT trap: 5"))
        #expect(report.contains("Captured By:         MetricKit"))
    }

    /// Each frame's absolute address is its image's load address plus its offset, in hex.
    @Test func writesEveryThreadWithAbsoluteAddresses() {
        let (entry, details) = trap

        let report = CrashReportFormatter.report(entry: entry, details: details)

        #expect(report.contains("Thread 0:"))
        #expect(report.contains("Thread 1 Crashed:"))
        #expect(report.contains(String(format: "0x%016llx ExampleApp + 24576", 4_340_776_960 + 24_576)))
    }

    @Test func listsTheBinaryImagesWithTheirUUIDs() {
        let (entry, details) = trap

        let report = CrashReportFormatter.report(entry: entry, details: details)
        let uuid = CrashDiagnosticFixtures.appUUID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")

        #expect(report.contains("Binary Images:"))
        #expect(report.contains("0x0000000102bb0000 - ??? ExampleApp arm64 <\(uuid)>"))
    }

    @Test func fallsBackToTheEntrysStackWithoutDetails() {
        let entry = CrashLogEntry(name: "NSGenericException", reason: "old", stackTrace: ["frame zero", "frame one"],
                                  appVersion: "1", buildNumber: "1", osVersion: "17.0", deviceModel: "iPhone")

        let report = CrashReportFormatter.report(entry: entry, details: nil)

        #expect(report.contains("Stack Trace:\n0  frame zero\n1  frame one"))
        #expect(!report.contains("Binary Images:"))
    }

    @Test func notesHowTheSessionWasMatched() {
        var (entry, details) = trap
        details.sessionMatch = SessionJournal.Match.timeWindow.rawValue

        #expect(CrashReportFormatter.report(entry: entry, details: details).contains("the only launch of this build active in the reporting window"))
    }

    /// The `atos` command names the image's own binary and load address, and lists each app frame
    /// once.
    @Test func buildsTheAtosCommandForTheAppsFrames() throws {
        var details = CrashDetails()
        details.images = [CrashDetails.BinaryImage(name: "MyApp", uuid: UUID(), loadAddress: 0x1_0000_0000, path: nil, architecture: "arm64")]
        details.threads = [CrashDetails.Thread(crashed: true, frames: [
            CrashDetails.Frame(imageIndex: 0, offset: 0x6000),
            CrashDetails.Frame(imageIndex: 0, offset: 0x6000),
            CrashDetails.Frame(imageIndex: 0, offset: 0x7000),
        ])]

        let command = try #require(CrashReportFormatter.atosCommand(for: details))

        #expect(command == "atos -arch arm64 -o MyApp.app.dSYM/Contents/Resources/DWARF/MyApp -l 0x0000000100000000 0x0000000100006000 0x0000000100007000")
    }
}

// MARK: - Artifacts

@Suite struct CrashArtifactStoreTests {

    @Test func storesAndPrunesEachCrashsFiles() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CrashArtifactStore(root: root)
        let kept = UUID(), dropped = UUID()
        var details = CrashDetails()
        details.exceptionType = "EXC_BAD_ACCESS"

        store.writeDetails(details, for: kept)
        store.writeDiagnostic(Data("{}".utf8), for: kept)
        store.writeDetails(details, for: dropped)
        store.prune(keeping: [kept])

        #expect(store.details(for: kept) == details)
        #expect(store.diagnostic(for: kept) == Data("{}".utf8))
        #expect(store.details(for: dropped) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: dropped).path))
    }
}

// MARK: - Session journal

@Suite struct SessionJournalTests {

    @Test func recordsConsoleOutputForTheSession() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SessionJournal(root: root)
        let id = journal.start(pinned: [])

        journal.recordConsole(["first", "second"], source: "stdout", at: Date(timeIntervalSince1970: 0))
        journal.recordConsole(["oops"], source: "stderr")

        let log = try #require(journal.consoleLog(for: id))
        #expect(log.contains("[stdout] first\n"))
        #expect(log.contains("[stdout] second\n"))
        #expect(log.contains("[stderr] oops\n"))
        #expect(log.hasPrefix("1970-01-01"))
    }

    @Test func recordsRequestsAsHAREntries() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SessionJournal(root: root)
        let id = journal.start(pinned: [])
        let request = HTTPRequest()
        request.requestURL = "https://journal.invalid/path"
        request.requestMethod = "POST"
        request.requestDate = Date()
        request.responseCode = 201

        journal.recordRequest(request)

        let log = try #require(journal.networkLog(for: id))
        #expect(log.log.entries.count == 1)
        #expect(log.log.entries.first?.request.url == "https://journal.invalid/path")
        #expect(log.log.entries.first?.response.status == 201)
    }

    @Test func recordsNothingBeforeItStarts() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SessionJournal(root: root)

        journal.recordConsole(["lost"], source: "stdout")
        journal.flush()

        #expect(journal.sessions().isEmpty)
        #expect(journal.currentSessionID == nil)
    }

    @Test func keepsTheNewestSessionsAndPinnedOnes() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SessionJournal(root: root)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let oldest = journal.start(pinned: [], now: base)
        let pinned = journal.start(pinned: [], now: base.addingTimeInterval(1))
        for index in 2..<(SessionJournal.maxSessions + 4) {
            journal.start(pinned: [pinned], now: base.addingTimeInterval(TimeInterval(index)))
        }
        journal.flush()

        let ids = Set(journal.sessions().map(\.id))

        /// The running session, the newest ten others, and the pinned one.
        #expect(ids.count == SessionJournal.maxSessions + 2)
        #expect(ids.contains(pinned))
        #expect(!ids.contains(oldest))
    }

    /// Sessions stored crashes refer to are kept, but only the newest of them, so disk use is
    /// bounded however many crashes are stored.
    @Test func keepsOnlyTheNewestPinnedSessions() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SessionJournal(root: root)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let pinned = (0..<(SessionJournal.maxPinnedSessions + 3)).map {
            journal.start(pinned: [], now: base.addingTimeInterval(TimeInterval($0)))
        }
        journal.start(pinned: Set(pinned), now: base.addingTimeInterval(1_000))
        journal.flush()

        let ids = Set(journal.sessions().map(\.id))

        #expect(ids.isSuperset(of: pinned.suffix(SessionJournal.maxPinnedSessions)))
        #expect(ids.isDisjoint(with: pinned.prefix(3)))
    }

    /// A directory with no readable `session.json` is never listed, so it would never be pruned
    /// either, unless pruning looks at directories rather than sessions.
    @Test func removesDirectoriesWithoutASession() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("lost".utf8).write(to: orphan.appendingPathComponent("console.log"))
        let journal = SessionJournal(root: root)

        journal.start(pinned: [])
        journal.flush()

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func clearingRemovesEverySessionsLogs() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SessionJournal(root: root)
        let earlier = journal.start(pinned: [])
        journal.recordConsole(["earlier"], source: "stdout")
        let request = HTTPRequest()
        request.requestURL = "https://clear.invalid/"
        request.requestDate = Date()
        journal.recordRequest(request)
        journal.flush()
        let current = journal.start(pinned: [earlier])
        journal.recordConsole(["current"], source: "stdout")
        journal.recordRequest(request)

        journal.clearNetworkLogs()
        journal.clearConsoleLogs()

        #expect(journal.networkLog(for: earlier) == nil)
        #expect(journal.networkLog(for: current) == nil)
        #expect(journal.consoleLog(for: earlier) == nil)
        #expect(journal.consoleLog(for: current) == nil)

        journal.recordConsole(["after"], source: "stdout")
        #expect(journal.consoleLog(for: current)?.contains("after") == true, "recording carries on after a clear")
    }

    @Test func dropsTheOldestHalfOfAFullFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("log")
        let lines = (0..<100).map { "line \($0)\n" }.joined()
        try Data(lines.utf8).write(to: url)

        SessionJournal.dropOldestHalf(of: url)

        let kept = try String(contentsOf: url, encoding: .utf8)
        #expect(kept.hasPrefix("line 5"))
        #expect(kept.hasSuffix("line 99\n"))
        #expect(!kept.contains("line 0\n"))
    }

    /// The newest line survives even when it alone is more than half the file — one large
    /// response must not empty the network log.
    @Test func keepsTheNewestLineHoweverLong() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("log")
        let newest = String(repeating: "x", count: 10_000)
        try Data("old one\nold two\n\(newest)\n".utf8).write(to: url)

        SessionJournal.dropOldestHalf(of: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "\(newest)\n")
    }

    private func session(_ pid: Int, started: TimeInterval, active: TimeInterval, build: String = "42") -> SessionJournal.Session {
        var session = SessionJournal.Session(id: UUID(), processID: pid, startedAt: Date(timeIntervalSince1970: started),
                                             appVersion: "1", buildNumber: build)
        session.lastActivity = Date(timeIntervalSince1970: active)
        return session
    }

    @Test func matchesACrashByProcessIdentifier() throws {
        let crashed = session(812, started: 100, active: 200)
        let later = session(900, started: 300, active: 400)

        let match = try #require(SessionJournal.session(crashedBetween: Date(timeIntervalSince1970: 0),
                                                        and: Date(timeIntervalSince1970: 1_000),
                                                        processID: 812, buildNumber: "42",
                                                        in: [later, crashed], excluding: nil))

        #expect(match.session == crashed)
        #expect(match.match == .processIdentifier)
    }

    /// Without a process identifier, the newest earlier session of the same build active in the
    /// window — never the running one.
    @Test func matchesACrashByTimeWindow() throws {
        let other = session(1, started: 0, active: 30)
        let crashed = session(2, started: 200, active: 260)
        let otherBuild = session(3, started: 300, active: 350, build: "41")
        let running = session(4, started: 400, active: 450)

        let match = try #require(SessionJournal.session(crashedBetween: Date(timeIntervalSince1970: 120),
                                                        and: Date(timeIntervalSince1970: 500),
                                                        processID: nil, buildNumber: "42",
                                                        in: [running, otherBuild, crashed, other], excluding: running.id))

        #expect(match.session == crashed)
        #expect(match.match == .timeWindow)
    }

    /// Two launches of the build in the window: either could be the one that crashed, and
    /// attaching the wrong one's logs is worse than attaching none.
    @Test func matchesNothingWhenTheWindowHoldsTwoSessions() {
        let first = session(1, started: 100, active: 150)
        let second = session(2, started: 200, active: 260)

        #expect(SessionJournal.session(crashedBetween: Date(timeIntervalSince1970: 120),
                                       and: Date(timeIntervalSince1970: 500),
                                       processID: nil, buildNumber: "42",
                                       in: [second, first], excluding: nil) == nil)
    }

    /// Process identifiers are reused, so one only counts for a session active in the window.
    @Test func ignoresAReusedProcessIdentifierOutsideTheWindow() {
        let stale = session(812, started: 0, active: 30)

        #expect(SessionJournal.session(crashedBetween: Date(timeIntervalSince1970: 1_000),
                                       and: Date(timeIntervalSince1970: 2_000),
                                       processID: 812, buildNumber: "42",
                                       in: [stale], excluding: nil) == nil)
    }

    @Test func matchesNothingOutsideTheWindow() {
        let earlier = session(1, started: 100, active: 150)

        #expect(SessionJournal.session(crashedBetween: Date(timeIntervalSince1970: 1_000),
                                       and: Date(timeIntervalSince1970: 2_000),
                                       processID: nil, buildNumber: nil,
                                       in: [earlier], excluding: nil) == nil)
    }
}

// MARK: - Ingest

@Suite struct CrashDiagnosticIngestArtifactTests {

    private struct FixedLocator: CrashSessionLocating {
        let id: UUID
        func session(for record: CrashDiagnosticRecord) -> (id: UUID, match: SessionJournal.Match)? {
            (id, .processIdentifier)
        }
    }

    /// An ingested diagnostic is stored with its details, its raw JSON and its session.
    @Test func storesDetailsDiagnosticAndSession() throws {
        let crashes = InMemoryCrashLogRepository()
        let session = UUID()
        let ingestor = CrashDiagnosticIngestor(crashes: crashes, fingerprints: InMemoryFingerprintStore(),
                                               symbolicator: NoSymbolicator(), sessions: FixedLocator(id: session))
        let trap = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)

        let entries = ingestor.ingest([trap])

        let entry = try #require(entries.first)
        let artifact = try #require(crashes.artifacts.first)
        #expect(entry.sessionID == session)
        #expect(artifact.id == entry.id)
        #expect(artifact.diagnosticJSON == trap.diagnosticJSON)
        #expect(artifact.details.sessionMatch == "processIdentifier")
        #expect(artifact.details.threads.count == 2)
    }
}

/// A diagnostic that duplicates a handler crash adds its threads and raw JSON to that crash.
@Suite struct CrashDiagnosticClaimTests {

    @Test func foldsAClaimedDiagnosticIntoTheHandlerCrash() throws {
        let handler = CrashDiagnosticFixtures.handlerEntry(
            name: "NSInvalidArgumentException",
            at: CrashDiagnosticFixtures.windowBegin.addingTimeInterval(600)
        )
        var handlerDetails = CrashDetails()
        handlerDetails.exceptionBacktrace = [CrashDetails.Frame(imageIndex: 0, offset: 10, symbol: "objc_exception_throw", symbolOffset: 72)]
        handlerDetails.images = [CrashDetails.BinaryImage(name: "libobjc.A.dylib", uuid: UUID(), loadAddress: 0x1000, path: nil, architecture: "arm64")]
        handlerDetails.threads = [CrashDetails.Thread(crashed: true, frames: [])]
        let crashes = InMemoryCrashLogRepository([handler])
        crashes.record([], artifacts: [CrashArtifacts(id: handler.id, details: handlerDetails, diagnosticJSON: nil)])
        let ingestor = CrashDiagnosticIngestor(crashes: crashes, fingerprints: InMemoryFingerprintStore(), symbolicator: NoSymbolicator())
        var diagnostic = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)
        diagnostic.exceptionName = "NSInvalidArgumentException"

        let entries = ingestor.ingest([diagnostic])

        #expect(entries.isEmpty, "the duplicate is not stored as a crash of its own")
        let merged = try #require(crashes.details(for: handler.id))
        #expect(merged.exceptionBacktrace == handlerDetails.exceptionBacktrace)
        #expect(merged.threads.count == 2, "MetricKit's threads replace the handler's one")
        #expect(merged.exceptionCodes == [1])
        #expect(crashes.artifacts.last?.diagnosticJSON == diagnostic.diagnosticJSON)
        let app = try #require(merged.images.firstIndex { $0.name == "ExampleApp" })
        #expect(merged.crashedThread?.frames.first?.imageIndex == app, "frames point into the merged image list")
    }

    @Test func mergingReusesImagesWithTheSameUUID() {
        let uuid = UUID()
        var handler = CrashDetails()
        handler.images = [CrashDetails.BinaryImage(name: "Shared", uuid: uuid, loadAddress: 0x1000, path: "/a", architecture: "arm64")]
        var metricKit = CrashDetails()
        metricKit.images = [
            CrashDetails.BinaryImage(name: "Other", uuid: UUID(), loadAddress: 0x2000, path: nil, architecture: "arm64"),
            CrashDetails.BinaryImage(name: "Shared", uuid: uuid, loadAddress: 0x1000, path: nil, architecture: "arm64"),
        ]
        metricKit.threads = [CrashDetails.Thread(crashed: true, frames: [
            CrashDetails.Frame(imageIndex: 1, offset: 4),
            CrashDetails.Frame(imageIndex: 0, offset: 8),
        ])]

        let merged = handler.merging(metricKit: metricKit)

        #expect(merged.images.map(\.name) == ["Shared", "Other"])
        #expect(merged.images[0].path == "/a")
        #expect(merged.threads[0].frames.map(\.imageIndex) == [0, 1])
    }
}

// MARK: - Export

@Suite struct CrashExporterTests {

    private struct Fixture {
        let root: URL
        let artifacts: CrashArtifactStore
        let journal: SessionJournal
        let entry: CrashLogEntry

        init(withSession: Bool = true) {
            root = temporaryDirectory()
            artifacts = CrashArtifactStore(root: root.appendingPathComponent("artifacts"))
            journal = SessionJournal(root: root.appendingPathComponent("sessions"))
            let session = withSession ? journal.start(pinned: []) : nil
            journal.recordConsole(["token=secret-value-123 logged in"], source: "stdout")
            let request = HTTPRequest()
            request.requestURL = "https://export.invalid/login?password=hunter2"
            request.requestMethod = "GET"
            request.requestDate = Date()
            request.responseCode = 200
            journal.recordRequest(request)
            journal.flush()

            let record = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)
            entry = CrashDiagnosticMapper.entry(for: record, symbolicator: NoSymbolicator(), sessionID: session)
            artifacts.writeDetails(CrashDiagnosticMapper.details(for: record, symbolicator: NoSymbolicator()), for: entry.id)
            artifacts.writeDiagnostic(record.diagnosticJSON, for: entry.id)
        }

        func write(redact: Bool) throws -> URL {
            try CrashExporter.writeArchiveDirectory(for: [entry], in: root, name: "Archive", redact: redact,
                                                    artifacts: artifacts, journal: journal)
        }
    }

    @Test func writesAFolderPerCrashWithEveryFile() throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let archive = try fixture.write(redact: false)

        let folders = try FileManager.default.contentsOfDirectory(atPath: archive.path).sorted()
        #expect(folders.count == 2)
        #expect(folders.contains("README.txt"))
        let crash = try #require(folders.first { $0.hasPrefix("01-EXC_BREAKPOINT-") })
        let files = try FileManager.default.contentsOfDirectory(atPath: archive.appendingPathComponent(crash).path).sorted()
        #expect(files == ["console.log", "crash.ips", "diagnostic.json", "network-log.har", "report.txt"])
    }

    @Test func redactsTheSessionLogs() throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let archive = try fixture.write(redact: true)
        let crash = try #require(try FileManager.default.contentsOfDirectory(atPath: archive.path).first { $0.hasPrefix("01-") })
        let folder = archive.appendingPathComponent(crash)
        let console = try String(contentsOf: folder.appendingPathComponent("console.log"), encoding: .utf8)
        let har = try String(contentsOf: folder.appendingPathComponent("network-log.har"), encoding: .utf8)

        #expect(!console.contains("secret-value-123"))
        #expect(!har.contains("hunter2"))
    }

    @Test func leavesOutSessionLogsItHasNot() throws {
        let fixture = Fixture(withSession: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let archive = try fixture.write(redact: false)
        let crash = try #require(try FileManager.default.contentsOfDirectory(atPath: archive.path).first { $0.hasPrefix("01-") })
        let files = try FileManager.default.contentsOfDirectory(atPath: archive.appendingPathComponent(crash).path).sorted()

        #expect(files == ["crash.ips", "diagnostic.json", "report.txt"])
    }

    @Test func zipsTheArchive() throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let zip = try CrashExporter.export([fixture.entry], redact: true, in: fixture.root,
                                           artifacts: fixture.artifacts, journal: fixture.journal)

        #expect(zip.pathExtension == "zip")
        #expect(zip.lastPathComponent.contains("-Crash-Report-"))
        #expect(((try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0) > 0)
    }

    @Test func refusesAnEmptyExport() {
        #expect(throws: CrashExporter.ExportError.nothingToExport) {
            try CrashExporter.export([], redact: false)
        }
    }

    @Test func namesEachCrashFolder() {
        let entry = CrashLogEntry(timestamp: Date(timeIntervalSince1970: 0), name: "EXC_BAD_ACCESS (SIGSEGV)", reason: nil,
                                  stackTrace: [], appVersion: "1", buildNumber: "1", osVersion: "18", deviceModel: "iPhone")

        #expect(CrashExporter.folderName(index: 3, crash: entry, timeZone: TimeZone(identifier: "UTC")!)
                == "03-EXC_BAD_ACCESS-1970-01-01-000000")
    }
}

// MARK: - Export view model

@Suite @MainActor struct CrashExportViewModelTests {

    private func entry(source: CrashLogSource, session: UUID? = nil) -> CrashLogEntry {
        CrashLogEntry(name: "crash", reason: nil, stackTrace: [], appVersion: "1", buildNumber: "1",
                      osVersion: "18", deviceModel: "iPhone", source: source, sessionID: session)
    }

    @Test func describesWhatTheArchiveHolds() {
        let plain = CrashExportViewModel(crashes: [entry(source: .exceptionHandler)], minimumRebuildDuration: .zero) { _, _ in URL(fileURLWithPath: "/") }
        let rich = CrashExportViewModel(crashes: [entry(source: .metricKit, session: UUID())], minimumRebuildDuration: .zero) { _, _ in URL(fileURLWithPath: "/") }

        #expect(plain.crashCount == 1)
        #expect(!plain.includesSessionLogs)
        #expect(!plain.includesDiagnostics)
        #expect(rich.includesSessionLogs)
        #expect(rich.includesDiagnostics)
    }

    /// Toggling twice while a slow build is running must leave the archive of the final setting,
    /// never the earlier one, and remove the superseded archive.
    @Test func theNewestSettingWinsAQuickDoubleToggle() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewModel = CrashExportViewModel(crashes: [entry(source: .metricKit)], minimumRebuildDuration: .zero) { _, redact in
            /// The unredacted build is the slow one, so without ordering it would land last.
            if !redact { Foundation.Thread.sleep(forTimeInterval: 0.3) }
            let url = directory.appendingPathComponent("\(redact ? "redacted" : "raw")-\(UUID().uuidString).zip")
            try Data().write(to: url)
            return url
        }
        await viewModel.onFirstAppear()

        let off = viewModel.setRedaction(false)
        let on = viewModel.setRedaction(true)
        await off?.value
        await on?.value

        let url = try #require(viewModel.archiveURL)
        #expect(viewModel.redactSensitiveValues)
        #expect(url.lastPathComponent.hasPrefix("redacted-"))
        #expect(!viewModel.isRebuilding)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == [url.lastPathComponent], "superseded archives are deleted")
    }

    @Test func buildsAndRebuildsWithTheRedactionSetting() async throws {
        let calls = RedactionCalls()
        let viewModel = CrashExportViewModel(crashes: [entry(source: .metricKit)], minimumRebuildDuration: .zero) { _, redact in
            calls.append(redact)
            return FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        }

        await viewModel.onFirstAppear()
        #expect(viewModel.archiveURL != nil)
        await viewModel.setRedaction(false)?.value

        #expect(calls.values == [true, false])
        #expect(!viewModel.isRebuilding)
    }
}

/// Records the redaction setting each build was asked for.
private final class RedactionCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Bool) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

// MARK: - Entry

@Suite struct CrashLogEntrySessionTests {

    @Test func anEntryWithoutASessionDecodesWithNone() throws {
        let legacy = """
        {"id": "\(UUID().uuidString)", "timestamp": 0, "name": "N", "reason": null, "stackTrace": [],
         "appVersion": "1", "buildNumber": "1", "osVersion": "17", "deviceModel": "iPhone"}
        """

        #expect(try JSONDecoder().decode(CrashLogEntry.self, from: Data(legacy.utf8)).sessionID == nil)
    }

    @Test func aSessionRoundTrips() throws {
        let entry = CrashLogEntry(name: "N", reason: nil, stackTrace: [], appVersion: "1", buildNumber: "1",
                                  osVersion: "17", deviceModel: "iPhone", sessionID: UUID())

        #expect(try JSONDecoder().decode(CrashLogEntry.self, from: JSONEncoder().encode(entry)) == entry)
    }
}

// MARK: - Symbolicator check

/// Builds an `.ips` from this process's own frames: what the export would contain for a crash
/// right here. With `SCYTHER_IPS_CHECK_DIR` set it is also written out, so it can be checked
/// against Xcode's `CrashSymbolicator.py` with the test bundle's binary.
@Suite struct CrashIPSSymbolicationFixtureTests {
    @Test func writesAnIPSFromThisProcess() throws {
        let exception = NSException(name: NSExceptionName("ScytherIPSCheck"), reason: "symbolication check", userInfo: nil)
        let details = CrashDetails.capture(exception: exception)
        let entry = CrashLogEntry(name: "ScytherIPSCheck", reason: "symbolication check", stackTrace: [],
                                  appVersion: "1", buildNumber: "1", osVersion: "18", deviceModel: "iPhone")

        let data = CrashIPSBuilder.build(entry: entry, details: details)
        /// Kept only when asked for, by running the tests with `TEST_RUNNER_SCYTHER_IPS_CHECK_DIR`
        /// set to a directory on the Mac.
        if let directory = ProcessInfo.processInfo.environment["SCYTHER_IPS_CHECK_DIR"] {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("scyther-ips-check.ips"))
            let record = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)
            try CrashIPSBuilder.build(entry: CrashDiagnosticMapper.entry(for: record, symbolicator: NoSymbolicator()),
                                      details: CrashDiagnosticMapper.details(for: record, symbolicator: NoSymbolicator()))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("scyther-ips-metrickit.ips"))
            try Data(CrashReportFormatter.report(entry: entry, details: details).utf8)
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("report.txt"))
        }

        let report = try parseIPS(data).report
        #expect(((report["threads"] as? [[String: Any]])?.first?["frames"] as? [Any])?.isEmpty == false)
    }
}
#endif

// MARK: - Details view model

#if !os(macOS)
@Suite @MainActor struct CrashDetailsViewModelLoadingTests {

    /// The details and full report are read on first appearance, not in the initializer, and
    /// replace the entry's own report once they are.
    @Test func loadsTheDetailsAndFullReportOnAppear() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = CrashArtifactStore(root: root.appendingPathComponent("artifacts"))
        let journal = SessionJournal(root: root.appendingPathComponent("sessions"))
        let record = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)
        let entry = CrashDiagnosticMapper.entry(for: record, symbolicator: NoSymbolicator())
        artifacts.writeDetails(CrashDiagnosticMapper.details(for: record, symbolicator: NoSymbolicator()), for: entry.id)

        let viewModel = CrashDetailsViewModel(crash: entry, artifacts: artifacts, journal: journal)
        #expect(viewModel.details == nil)
        #expect(viewModel.fullReport == entry.fullReport)

        await viewModel.onFirstAppear()

        #expect(viewModel.threadCount == 2)
        #expect(viewModel.exceptionCodes == "0x0000000000000001")
        #expect(viewModel.fullReport.contains("Thread 1 Crashed:"))
    }
}
#endif
