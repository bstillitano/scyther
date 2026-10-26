//
//  CrashLogger.swift
//  Scyther
//
//  Created by Brandon Stillitano on 22/12/2024.
//

#if !os(macOS)
import Foundation
import UIKit

/// A singleton that captures crashes and stores them for viewing.
///
/// `CrashLogger` captures crashes two ways:
///
/// - `NSSetUncaughtExceptionHandler` intercepts Objective-C exceptions before the app terminates.
/// - `CrashDiagnosticsCollector` ingests MetricKit's crash diagnostics on the next launch, which
///   covers every other kind of crash: Swift traps such as a force unwrap of `nil`,
///   `EXC_BAD_ACCESS`, and aborts from other runtimes.
///
/// Both are persisted to `UserDefaults.scyther`, Scyther's private preferences suite, and can be
/// viewed on subsequent app launches. ``CrashLogEntry/source`` records which path captured each.
///
/// ## Features
/// - Automatic exception interception
/// - Handler chaining for compatibility with other crash reporters
/// - Persistent storage of up to 50 crash logs
/// - Device and app metadata capture
///
/// ## Handler Chaining
///
/// CrashLogger chains to any previously installed handler (e.g., Firebase Crashlytics,
/// Sentry) so multiple crash reporters can coexist. When a crash occurs:
///
/// 1. CrashLogger captures and stores the crash locally
/// 2. The crash is forwarded to any previously registered handler
///
/// - Important: Call `Scyther.start()` **after** initializing other crash reporters
///   (like Firebase) to ensure proper handler chaining. If Scyther is started first,
///   subsequent crash reporters may overwrite Scyther's handler.
///
/// ## Usage
/// ```swift
/// // In your app initialization
/// FirebaseApp.configure()  // Other crash reporters first
/// Scyther.start()          // Scyther last
///
/// // Access crash logs
/// let crashes = CrashLogger.instance.allCrashes
/// print("Found \(crashes.count) crashes")
///
/// // Clear crash logs
/// CrashLogger.instance.clear()
/// ```
///
/// ## Limitations
/// - The exception handler only sees `NSException`-based crashes. Everything else — a Swift
///   `fatalError()`, a force unwrap, `EXC_BAD_ACCESS` — arrives through MetricKit instead, and
///   only on the **next launch**, when the system delivers the diagnostic.
/// - MetricKit delivers diagnostics on a **physical device** only. The Simulator never does, so on
///   the Simulator only `NSException` crashes are captured.
/// - A crash that happens with the **debugger attached** produces no MetricKit diagnostic: the
///   debugger stops the process before the system can record one.
/// - MetricKit stack traces are best-effort symbolicated against the images loaded now. Frames in
///   a stripped binary, or from a build other than the one running, show a binary and offset only.
/// - A MetricKit entry is stamped with the end of its payload's window, not the moment of the
///   crash, which MetricKit does not report.
///
/// ## Topics
///
/// ### Accessing Crashes
/// - ``instance``
/// - ``allCrashes``
/// - ``crashCount``
///
/// ### Managing Crash Logs
/// - ``start()``
/// - ``clear()``
///
/// ### Notifications
/// - ``didRecordCrashNotification``
public final class CrashLogger: CrashLogRepository, @unchecked Sendable {
    /// Shared instance.
    public static let instance = CrashLogger()

    /// UserDefaults key for storing crash logs.
    private static let storageKey = "Scyther_CrashLogs"

    /// Maximum number of crashes to store.
    private static let maxCrashes = 50

    /// Previously installed exception handler (e.g., Crashlytics).
    /// We forward crashes to this handler after logging.
    nonisolated(unsafe) private static var previousHandler: (@convention(c) (NSException) -> Void)?

    /// Cached device info captured at startup (safe to access from exception handler).
    nonisolated(unsafe) private static var cachedOSVersion: String = "Unknown"
    nonisolated(unsafe) private static var cachedDeviceModel: String = "Unknown"
    nonisolated(unsafe) private static var cachedAppVersion: String = "Unknown"
    nonisolated(unsafe) private static var cachedBuildNumber: String = "Unknown"

    /// Whether the crash handler has been installed.
    private var isStarted = false

    /// Notification posted when a new crash is recorded.
    public static let didRecordCrashNotification = Notification.Name("CrashLoggerDidRecordCrash")

    /// Serialises every read-modify-write of the stored crashes.
    ///
    /// The exception handler records on whichever thread is crashing, MetricKit entries arrive on
    /// the collector's queue, and `clear()` runs on the main thread. Without the lock, one writer
    /// saving a list it loaded before another's write would lose that write — a crash recorded as
    /// the app died, or a clear that undoes itself. Recursive, because an exception raised on a
    /// thread that already holds it must still be able to record.
    private let storeLock = NSRecursiveLock()

    private init() {}

    /// All stored crash logs, newest first.
    public var allCrashes: [CrashLogEntry] {
        load()
    }

    /// Number of stored crashes.
    public var crashCount: Int {
        allCrashes.count
    }

    /// Starts the crash logger by installing the exception handler.
    ///
    /// This should be called during app initialization, after any other
    /// crash reporters (like Firebase Crashlytics) have been configured.
    @MainActor
    public func start() {
        guard !isStarted else { return }
        isStarted = true

        // Cache device info now (on main thread) so it's available during crashes
        CrashLogger.cachedOSVersion = UIDevice.current.systemVersion
        // The hardware identifier, such as `iPhone17,1`, rather than `UIDevice.model`'s "iPhone".
        CrashLogger.cachedDeviceModel = CrashDetails.currentHardwareModel
        CrashLogger.cachedAppVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        CrashLogger.cachedBuildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"

        // Save any existing handler so we can chain to it
        CrashLogger.previousHandler = NSGetUncaughtExceptionHandler()

        // Install our handler
        NSSetUncaughtExceptionHandler { exception in
            // Record the crash
            CrashLogger.recordCrash(exception)

            // Forward to previous handler (e.g., Crashlytics)
            CrashLogger.previousHandler?(exception)
        }
    }

    /// Records a crash from an exception.
    /// Called from the exception handler - keep this fast and safe.
    private static func recordCrash(_ exception: NSException) {
        let journal = SessionJournal.shared
        var details = CrashDetails.capture(exception: exception)
        let sessionID = journal.currentSessionID
        if sessionID != nil {
            details.sessionMatch = SessionJournal.Match.currentSession.rawValue
        }
        let entry = CrashLogEntry(
            name: exception.name.rawValue,
            reason: exception.reason,
            stackTrace: exception.callStackSymbols,
            appVersion: cachedAppVersion,
            buildNumber: cachedBuildNumber,
            osVersion: cachedOSVersion,
            deviceModel: cachedDeviceModel,
            sessionID: sessionID
        )

        // Whatever console output and traffic are still queued, written before the process dies.
        journal.flush()

        CrashLogger.instance.storeLock.lock()
        defer { CrashLogger.instance.storeLock.unlock() }

        // The threads and images, under the lock, so a save on another thread — which prunes the
        // files of crashes not in the list — cannot remove them before this crash is listed.
        CrashArtifactStore.shared.writeDetails(details, for: entry.id)

        // Load existing crashes
        var crashes = CrashLogger.instance.load()

        // Add new crash at the beginning
        crashes.insert(entry, at: 0)

        // Trim to max size
        if crashes.count > maxCrashes {
            crashes = Array(crashes.prefix(maxCrashes))
        }

        // Save immediately - we're about to crash
        CrashLogger.instance.save(crashes)
    }

    /// Stores entries from another source — MetricKit — alongside the existing crashes.
    ///
    /// Entries are kept newest first and the store keeps its cap of 50. A MetricKit entry for a
    /// crash from a few launches ago may be older than crashes already stored, so the list is
    /// sorted rather than prepended to. Posts ``didRecordCrashNotification`` on the main queue.
    ///
    /// - Parameters:
    ///   - entries: The entries to add.
    ///   - artifacts: Their files, written in the same step.
    func record(_ entries: [CrashLogEntry], artifacts: [CrashArtifacts] = []) {
        guard !entries.isEmpty else { return }
        storeLock.lock()
        // Written under the lock for the same reason as in `recordCrash(_:)`: a save prunes the
        // files of every crash not in the list it saves.
        for artifact in artifacts {
            CrashArtifactStore.shared.writeDetails(artifact.details, for: artifact.id)
            if let diagnostic = artifact.diagnosticJSON {
                CrashArtifactStore.shared.writeDiagnostic(diagnostic, for: artifact.id)
            }
        }
        let crashes = (load() + entries).sorted { $0.timestamp > $1.timestamp }
        save(Array(crashes.prefix(CrashLogger.maxCrashes)))
        storeLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: CrashLogger.didRecordCrashNotification, object: nil)
        }
    }

    /// Clears all stored crash logs.
    public func clear() {
        storeLock.lock()
        UserDefaults.scyther.removeObject(forKey: CrashLogger.storageKey)
        CrashArtifactStore.shared.prune(keeping: [])
        storeLock.unlock()
        NotificationCenter.default.post(name: CrashLogger.didRecordCrashNotification, object: nil)
    }

    /// Loads crash logs from `UserDefaults.scyther`.
    private func load() -> [CrashLogEntry] {
        guard let data = UserDefaults.scyther.data(forKey: CrashLogger.storageKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([CrashLogEntry].self, from: data)
        } catch {
            return []
        }
    }

    /// Saves crash logs to `UserDefaults.scyther`.
    private func save(_ crashes: [CrashLogEntry]) {
        do {
            let data = try JSONEncoder().encode(crashes)
            UserDefaults.scyther.set(data, forKey: CrashLogger.storageKey)
            // A crash trimmed off the end of the list takes its files with it.
            CrashArtifactStore.shared.prune(keeping: Set(crashes.map(\.id)))
            UserDefaults.scyther.synchronize() // Force immediate write - we're crashing
        } catch {
            // Can't do much if encoding fails during a crash
        }
    }

    // MARK: - Testing Support

    /// Triggers a test crash. Only available in debug builds.
    ///
    /// - Warning: This will crash the app!
    #if DEBUG
    public func triggerTestCrash() {
        let exception = NSException(
            name: NSExceptionName("ScytherTestCrash"),
            reason: "This is a test crash triggered from Scyther",
            userInfo: nil
        )
        exception.raise()
    }
    #endif
}
#endif
