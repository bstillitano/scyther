//
//  CrashDiagnosticTests.swift
//  ScytherTests
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
@testable import Scyther
import Foundation
import MachO
import Testing

// MARK: - Record

@Suite struct CrashDiagnosticRecordTests {

    @Test func parsesTheMetadata() {
        let record = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)

        #expect(record.exceptionType == 6)
        #expect(record.signal == 5)
        #expect(record.terminationReason == "Namespace SIGNAL, Code 5 Trace/BPT trap: 5")
        #expect(record.exceptionName == nil)
        #expect(record.appVersion == "2.1.0")
        #expect(record.buildNumber == "42")
        #expect(record.osVersion == "iPhone OS 18.0 (22A3354)")
        #expect(record.deviceModel == "iPhone17,1")
        #expect(record.timeStampEnd == CrashDiagnosticFixtures.windowEnd)
        #expect(record.threads.count == 2)
    }

    @Test func parsesTheObjectiveCExceptionReason() {
        let record = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.objectiveCException)

        #expect(record.exceptionName == "NSInvalidArgumentException")
        #expect(record.composedMessage == "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil")
    }

    @Test func rejectsDataThatIsNotAJSONObject() {
        #expect(CrashDiagnosticRecord(diagnosticJSON: Data("[]".utf8), timeStampBegin: .now, timeStampEnd: .now) == nil)
        #expect(CrashDiagnosticRecord(diagnosticJSON: Data("nope".utf8), timeStampBegin: .now, timeStampEnd: .now) == nil)
    }

    /// The fingerprint is what stops a diagnostic being ingested again on a later launch, so it must
    /// not depend on key order.
    @Test func theFingerprintIgnoresKeyOrder() {
        let one = CrashDiagnosticFixtures.record(#"{"diagnosticMetaData": {"signal": 5, "exceptionType": 6}}"#)
        let other = CrashDiagnosticFixtures.record(#"{"diagnosticMetaData": {"exceptionType": 6, "signal": 5}}"#)

        #expect(one.fingerprint == other.fingerprint)
    }

    @Test func theFingerprintCoversTheFrames() {
        let one = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)
        let other = CrashDiagnosticFixtures.record(
            CrashDiagnosticFixtures.swiftTrap.replacingOccurrences(of: "\"offsetIntoBinaryTextSegment\": 12000",
                                                                    with: "\"offsetIntoBinaryTextSegment\": 12004")
        )

        #expect(one.fingerprint != other.fingerprint)
    }

    /// A stack overflow's tree is deeper than `JSONSerialization` will read. The diagnostic must
    /// survive it, metadata and frames both.
    @Test func readsADiagnosticDeeperThanJSONSerializationAllows() throws {
        let depth = 1_000
        let json = #"{"diagnosticMetaData": {"signal": 11, "exceptionType": 1}, "callStackTree": "#
            + CrashDiagnosticFixtures.chain(depth: depth) + "}"
        #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) == nil, "the fixture must be too deep for Foundation")

        let record = try #require(CrashDiagnosticRecord(diagnosticJSON: Data(json.utf8), timeStampBegin: .now, timeStampEnd: .now))

        #expect(record.signal == 11)
        #expect(record.exceptionType == 1)
        #expect(record.threads.first?.frames.count == depth)
    }

    @Test func differentDiagnosticsHaveDifferentFingerprints() {
        let trap = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)
        let abort = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.abort)

        #expect(trap.fingerprint != abort.fingerprint)
    }
}

// MARK: - Mapper

@Suite struct CrashDiagnosticMapperTests {

    @Test func namesASwiftTrapByItsExceptionAndSignal() {
        let entry = CrashDiagnosticMapper.entry(for: CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap),
                                                symbolicator: NoSymbolicator())

        #expect(entry.name == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(entry.reason == "Namespace SIGNAL, Code 5 Trace/BPT trap: 5")
    }

    @Test func namesAnObjectiveCExceptionByItsName() {
        let entry = CrashDiagnosticMapper.entry(for: CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.objectiveCException),
                                                symbolicator: NoSymbolicator())

        #expect(entry.name == "NSInvalidArgumentException")
        #expect(entry.reason == "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil")
    }

    @Test(arguments: [
        (1, 11, "EXC_BAD_ACCESS (SIGSEGV)"),
        (10, 6, "EXC_CRASH (SIGABRT)"),
        (99, 6, "EXC_99 (SIGABRT)"),
        (6, 77, "EXC_BREAKPOINT (SIG77)"),
    ])
    func namesExceptionsAndSignals(exceptionType: Int, signal: Int, expected: String) {
        var record = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.abort)
        record.exceptionType = exceptionType
        record.signal = signal

        #expect(CrashDiagnosticMapper.name(for: record) == expected)
    }

    @Test func namesADiagnosticWithNeitherExceptionNorSignal() {
        var record = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.abort)
        record.exceptionType = nil
        record.signal = nil

        #expect(CrashDiagnosticMapper.name(for: record) == "Crash")
    }

    @Test func carriesTheMetadataAndStampsTheEndOfTheWindow() {
        let entry = CrashDiagnosticMapper.entry(for: CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap),
                                                symbolicator: NoSymbolicator())

        #expect(entry.source == .metricKit)
        #expect(entry.timestamp == CrashDiagnosticFixtures.windowEnd)
        #expect(entry.appVersion == "2.1.0")
        #expect(entry.buildNumber == "42")
        #expect(entry.osVersion == "iPhone OS 18.0 (22A3354)")
        #expect(entry.deviceModel == "iPhone17,1")
    }

    /// The crashed thread is picked by `threadAttributed`, flattened top of the stack first, and a
    /// load address stored as the offset is turned back into an offset.
    @Test func flattensTheCrashedThread() {
        let entry = CrashDiagnosticMapper.entry(for: CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap),
                                                symbolicator: NoSymbolicator())

        #expect(entry.stackTrace == [
            "ExampleApp + 24576",
            "ExampleApp + 12000",
            "dyld + 99024",
        ])
    }

    @Test func appendsTheSymbolWhenOneIsFound() {
        let entry = CrashDiagnosticMapper.entry(for: CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap),
                                                symbolicator: FixedSymbolicator(uuid: CrashDiagnosticFixtures.appUUID))

        #expect(entry.stackTrace == [
            "ExampleApp + 24576 (frame@24576)",
            "ExampleApp + 12000 (frame@12000)",
            "dyld + 99024",
        ])
    }

    @Test func fallsBackToTheFirstThreadWhenNoneIsAttributed() throws {
        let tree = #"{"callStacks": [{"callStackRootFrames": [{"binaryName": "Only", "offsetIntoBinaryTextSegment": 7}]}]}"#
        let threads = try #require(CrashDiagnosticJSONReader.read(Data(tree.utf8))).threads

        #expect(CrashDiagnosticMapper.stackTrace(from: threads, symbolicator: NoSymbolicator()) == ["Only + 7"])
    }

    @Test func noThreadsGiveNoFrames() {
        #expect(CrashDiagnosticMapper.stackTrace(from: [], symbolicator: NoSymbolicator()).isEmpty)
    }
}

// MARK: - Reader

@Suite struct CrashDiagnosticJSONReaderTests {

    /// MetricKit writes `subFrames` before a frame's other fields as often as after them.
    @Test func fillsFieldsThatComeAfterTheSubFrames() throws {
        let tree = #"""
        {"callStacks": [{"callStackRootFrames": [
          {"subFrames": [{"binaryName": "Caller", "offsetIntoBinaryTextSegment": 2}],
           "binaryName": "Top", "binaryUUID": "AB", "offsetIntoBinaryTextSegment": 1, "address": 9}
        ], "threadAttributed": true}]}
        """#

        let thread = try #require(CrashDiagnosticJSONReader.read(Data(tree.utf8))?.threads.first)

        #expect(thread.isAttributed)
        #expect(thread.frames == [
            .init(binaryUUID: "AB", binaryName: "Top", offsetIntoBinaryTextSegment: 1, address: 9),
            .init(binaryUUID: nil, binaryName: "Caller", offsetIntoBinaryTextSegment: 2, address: nil),
        ])
    }

    @Test func collectsValuesByKeyPath() throws {
        let json = #"{"a": {"b": "x\"yé", "c": 1.5, "d": false, "e": null, "f": [{"g": 1}]}}"#

        let values = try #require(CrashDiagnosticJSONReader.read(Data(json.utf8))).values

        #expect(values == ["a.b": "x\"yé", "a.c": "1.5", "a.d": "false"])
    }

    @Test(arguments: ["", "[]", "nope", #"{"a": 1"#, #"{"a": }}"#, #"{"a": "unterminated}"#])
    func rejectsMalformedJSON(_ json: String) {
        #expect(CrashDiagnosticJSONReader.read(Data(json.utf8)) == nil)
    }

    @Test func resolvesALoadAddressStoredAsTheOffset() {
        let quirk = CrashDiagnosticJSONReader.Frame(offsetIntoBinaryTextSegment: 4_361_617_408, address: 4_361_716_432)
        let real = CrashDiagnosticJSONReader.Frame(offsetIntoBinaryTextSegment: 12_000, address: 4_340_788_960)

        #expect(quirk.resolvedOffset == 99_024)
        #expect(real.resolvedOffset == 12_000)
    }
}

// MARK: - Ingestor

@Suite struct CrashDiagnosticIngestorTests {

    private let inWindow = CrashDiagnosticFixtures.windowBegin.addingTimeInterval(600)

    private func newEntries(_ records: [CrashDiagnosticRecord],
                            stored: [CrashLogEntry] = [],
                            seen: Set<String> = []) -> (entries: [CrashLogEntry], fingerprints: [String]) {
        CrashDiagnosticIngestor.newEntries(from: records, stored: stored, seen: seen, symbolicator: NoSymbolicator())
    }

    @Test func storesANewDiagnostic() {
        let trap = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)

        let result = newEntries([trap])

        #expect(result.entries.map(\.name) == ["EXC_BREAKPOINT (SIGTRAP)"])
        #expect(result.fingerprints == [trap.fingerprint])
    }

    @Test func skipsADiagnosticAlreadyIngested() {
        let trap = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)

        let result = newEntries([trap], seen: [trap.fingerprint])

        #expect(result.entries.isEmpty)
        #expect(result.fingerprints.isEmpty)
    }

    @Test func skipsTheSameDiagnosticDeliveredTwiceAtOnce() {
        let trap = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)

        #expect(newEntries([trap, trap]).entries.count == 1)
    }

    @Test func dropsAnExceptionTheHandlerAlreadyRecorded() {
        let exception = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.objectiveCException)
        let handler = CrashDiagnosticFixtures.handlerEntry(name: "NSInvalidArgumentException", at: inWindow)

        let result = newEntries([exception], stored: [handler])

        #expect(result.entries.isEmpty)
        #expect(result.fingerprints == [exception.fingerprint], "a dropped diagnostic must still be remembered")
    }

    @Test func keepsAnExceptionWhoseNameDiffers() {
        let exception = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.objectiveCException)
        let handler = CrashDiagnosticFixtures.handlerEntry(name: "NSRangeException", at: inWindow)

        #expect(newEntries([exception], stored: [handler]).entries.count == 1)
    }

    @Test func keepsAnExceptionWhenTheHandlerEntryIsOutsideTheWindow() {
        let exception = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.objectiveCException)
        let late = CrashDiagnosticFixtures.windowEnd.addingTimeInterval(CrashDiagnosticIngestor.windowTolerance + 1)
        let handler = CrashDiagnosticFixtures.handlerEntry(name: "NSInvalidArgumentException", at: late)

        #expect(newEntries([exception], stored: [handler]).entries.count == 1)
    }

    @Test func matchesAHandlerEntryJustOutsideTheWindow() {
        let exception = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.objectiveCException)
        let edge = CrashDiagnosticFixtures.windowEnd.addingTimeInterval(CrashDiagnosticIngestor.windowTolerance / 2)
        let handler = CrashDiagnosticFixtures.handlerEntry(name: "NSInvalidArgumentException", at: edge)

        #expect(newEntries([exception], stored: [handler]).entries.isEmpty)
    }

    @Test func toleratesAWindowWithItsBoundsReversed() {
        let exception = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.objectiveCException,
                                                       begin: CrashDiagnosticFixtures.windowEnd,
                                                       end: CrashDiagnosticFixtures.windowBegin)
        let handler = CrashDiagnosticFixtures.handlerEntry(name: "NSInvalidArgumentException", at: inWindow)

        #expect(newEntries([exception], stored: [handler]).entries.isEmpty)
    }

    /// Before iOS 17 MetricKit names no exception, so a `SIGABRT` in the window is taken as the
    /// handler's crash.
    @Test func dropsAnUnnamedAbortTheHandlerAlreadyRecorded() {
        let abort = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.abort)
        let handler = CrashDiagnosticFixtures.handlerEntry(name: "NSGenericException", at: inWindow)

        #expect(newEntries([abort], stored: [handler]).entries.isEmpty)
    }

    @Test func keepsATrapEvenWithAHandlerEntryInTheWindow() {
        let trap = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)
        let handler = CrashDiagnosticFixtures.handlerEntry(name: "NSGenericException", at: inWindow)

        #expect(newEntries([trap], stored: [handler]).entries.count == 1)
    }

    @Test func aMetricKitEntryNeverAccountsForADiagnostic() {
        let abort = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.abort)
        let earlier = CrashLogEntry(timestamp: inWindow, name: "EXC_CRASH (SIGABRT)", reason: nil, stackTrace: [],
                                    appVersion: "", buildNumber: "", osVersion: "", deviceModel: "", source: .metricKit)

        #expect(newEntries([abort], stored: [earlier]).entries.count == 1)
    }

    /// One handler entry is one crash. A second abort in the same window is a second crash.
    @Test func eachHandlerEntryAccountsForOneDiagnostic() {
        let abort = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.abort)
        var secondAbort = abort
        secondAbort.fingerprint = "second"
        let handler = CrashDiagnosticFixtures.handlerEntry(name: "NSGenericException", at: inWindow)

        #expect(newEntries([abort, secondAbort], stored: [handler]).entries.count == 1)
    }

    /// A named diagnostic claims its handler entry first, even when an unnamed abort comes before
    /// it, so the abort — a different crash — is kept.
    @Test func aNamedDiagnosticClaimsItsHandlerEntryFirst() {
        let abort = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.abort)
        let exception = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.objectiveCException)
        let handler = CrashDiagnosticFixtures.handlerEntry(name: "NSInvalidArgumentException", at: inWindow)

        let result = newEntries([abort, exception], stored: [handler])

        #expect(result.entries.map(\.name) == ["EXC_CRASH (SIGABRT)"])
    }

    @Test func ingestStoresEntriesAndRemembersFingerprints() {
        let crashes = InMemoryCrashLogRepository()
        let fingerprints = InMemoryFingerprintStore()
        let ingestor = CrashDiagnosticIngestor(crashes: crashes, fingerprints: fingerprints, symbolicator: NoSymbolicator())
        let trap = CrashDiagnosticFixtures.record(CrashDiagnosticFixtures.swiftTrap)

        ingestor.ingest([trap])
        ingestor.ingest([trap])

        #expect(crashes.recorded.count == 1, "the second delivery must be recognised and skipped")
        #expect(crashes.allCrashes.map(\.source) == [.metricKit])
        #expect(fingerprints.fingerprints == [trap.fingerprint])
    }
}

// MARK: - Fingerprint store

@Suite struct CrashDiagnosticFingerprintStoreTests {

    private func makeStore() -> (CrashDiagnosticFingerprintStore, UserDefaults) {
        let name = "CrashDiagnosticFingerprintStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (CrashDiagnosticFingerprintStore(defaults: defaults), defaults)
    }

    @Test func persistsFingerprints() {
        let (store, defaults) = makeStore()

        store.insert(["a", "b"])
        store.insert(["b", "c"])

        #expect(store.fingerprints == ["a", "b", "c"])
        #expect(CrashDiagnosticFingerprintStore(defaults: defaults).fingerprints == ["a", "b", "c"])
    }

    @Test func keepsTheNewestFingerprints() {
        let (store, _) = makeStore()
        let all = (0..<(CrashDiagnosticFingerprintStore.maxFingerprints + 10)).map(String.init)

        store.insert(all)

        #expect(store.fingerprints.count == CrashDiagnosticFingerprintStore.maxFingerprints)
        #expect(!store.fingerprints.contains("0"))
        #expect(store.fingerprints.contains(all.last!))
    }
}

// MARK: - Symbolicator

@Suite struct LoadedImageSymbolicatorTests {

    /// Symbolicates a function in Scyther's own image, found the way a MetricKit frame describes
    /// it: the image's UUID and an offset from its header.
    @Test func namesAFunctionInALoadedImage() throws {
        let function = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ScytherBootstrapIsInstalled"))
        var info = Dl_info()
        try #require(dladdr(function, &info) != 0)
        let header = try #require(info.dli_fbase).assumingMemoryBound(to: mach_header.self)
        let uuid = try #require(LoadedImageSymbolicator.uuid(of: header))
        let offset = UInt64(UInt(bitPattern: function) - UInt(bitPattern: info.dli_fbase)) + 4

        let symbol = LoadedImageSymbolicator().symbol(binaryUUID: uuid, offset: offset)

        #expect(symbol == "ScytherBootstrapIsInstalled + 4")
    }

    @Test func namesNothingInAnImageThatIsNotLoaded() {
        #expect(LoadedImageSymbolicator().symbol(binaryUUID: UUID(), offset: 0) == nil)
    }
}

// MARK: - Entry

@Suite struct CrashLogEntrySourceTests {

    /// Crashes stored before `source` existed must still load.
    @Test func anEntryStoredBeforeSourceExistedDecodesAsTheExceptionHandler() throws {
        let legacy = """
        {"id": "\(UUID().uuidString)", "timestamp": 0, "name": "NSGenericException", "reason": "old",
         "stackTrace": ["0 frame"], "appVersion": "1.0", "buildNumber": "1", "osVersion": "17.0", "deviceModel": "iPhone"}
        """

        let entry = try JSONDecoder().decode(CrashLogEntry.self, from: Data(legacy.utf8))

        #expect(entry.source == .exceptionHandler)
        #expect(entry.name == "NSGenericException")
    }

    @Test func aMetricKitEntryRoundTrips() throws {
        let entry = CrashLogEntry(name: "EXC_BAD_ACCESS (SIGSEGV)", reason: nil, stackTrace: [],
                                  appVersion: "1", buildNumber: "1", osVersion: "18", deviceModel: "iPhone",
                                  source: .metricKit)

        let decoded = try JSONDecoder().decode(CrashLogEntry.self, from: JSONEncoder().encode(entry))

        #expect(decoded == entry)
    }

    @Test func theReportNamesTheSource() {
        let entry = CrashLogEntry(name: "EXC_BAD_ACCESS (SIGSEGV)", reason: nil, stackTrace: [],
                                  appVersion: "1", buildNumber: "1", osVersion: "18", deviceModel: "iPhone",
                                  source: .metricKit)

        #expect(entry.fullReport.contains("Source: metricKit"))
    }
}

// MARK: - Store

/// `CrashLogger` writes to Scyther's own suite, which `CrashLoggerTests` clears as well, so this
/// suite is serialized and leaves the store empty.
@Suite(.serialized) struct CrashLoggerRecordTests {

    @Test func recordsNewestFirstWithinTheCap() async {
        CrashLogger.instance.clear()
        defer { CrashLogger.instance.clear() }

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = (0..<55).map {
            CrashDiagnosticFixtures.handlerEntry(name: "crash \($0)", at: base.addingTimeInterval(TimeInterval($0)))
        }

        CrashLogger.instance.record(Array(entries.prefix(30)))
        CrashLogger.instance.record(Array(entries.suffix(25)))

        let stored = CrashLogger.instance.allCrashes
        #expect(stored.count == 50)
        #expect(stored.first?.name == "crash 54")
        #expect(stored.last?.name == "crash 5")
    }

    @Test func postsTheRecordedNotification() async {
        CrashLogger.instance.clear()
        defer { CrashLogger.instance.clear() }

        await confirmation(expectedCount: 1...) { posted in
            let observer = NotificationCenter.default.addObserver(
                forName: CrashLogger.didRecordCrashNotification, object: nil, queue: nil
            ) { _ in posted() }
            defer { NotificationCenter.default.removeObserver(observer) }

            CrashLogger.instance.record([CrashDiagnosticFixtures.handlerEntry(name: "posted", at: .now)])
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
#endif
