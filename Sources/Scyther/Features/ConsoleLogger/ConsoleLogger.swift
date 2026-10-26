//
//  ConsoleLogger.swift
//  Scyther
//
//  Created by Brandon Stillitano on 20/12/2025.
//

#if !os(macOS)
import Foundation

public extension NSNotification.Name {
    /// Notification posted when a new console log entry is captured.
    ///
    /// Subscribe to this notification to be notified when new stdout or stderr output is logged.
    /// This allows UI components to update in real-time as console output occurs.
    static let ConsoleLoggerDidLog = Notification.Name("ConsoleLoggerDidLog")
}

/// Represents a single console log entry captured from stdout or stderr.
///
/// Each log entry contains the message text, timestamp, and source stream (stdout or stderr).
/// Entries are automatically assigned a unique identifier for use in SwiftUI lists.
///
/// ## Example
/// ```swift
/// let entry = ConsoleLogEntry(
///     timestamp: Date(),
///     message: "Application started successfully",
///     source: .stdout
/// )
/// print(entry.formattedTimestamp) // "10:30:45 AM"
/// ```
public struct ConsoleLogEntry: Identifiable, Equatable {
    /// Unique identifier for this log entry.
    public let id = UUID()

    /// The timestamp when this log entry was captured.
    public let timestamp: Date

    /// The log message text.
    public let message: String

    /// The source stream that produced this log entry.
    public let source: LogSource

    /// The source stream for a console log entry.
    ///
    /// Console output can come from two sources:
    /// - `stdout`: Standard output stream (normal print statements)
    /// - `stderr`: Standard error stream (error messages and warnings)
    public enum LogSource: String, Sendable {
        /// Standard output stream for normal log messages.
        case stdout = "stdout"

        /// Standard error stream for error messages and warnings.
        case stderr = "stderr"
    }

    /// Returns the timestamp formatted as a time string (e.g., "10:30:45 AM").
    ///
    /// This property provides a human-readable time format suitable for display in log viewers.
    public var formattedTimestamp: String {
        timestamp.formatted(date: .omitted, time: .standard)
    }
}

/// A console logger that captures and stores stdout and stderr output.
///
/// `ConsoleLogger` intercepts console output by redirecting the standard output and error streams
/// to pipes. This allows developers to view all console logs within the app's debug interface.
/// The logger maintains a rolling buffer of the most recent log entries and posts notifications
/// when new logs are captured.
///
/// ## Features
/// - Captures both stdout and stderr streams
/// - Maintains a rolling buffer of up to 5000 log entries
/// - Thread-safe log access using concurrent dispatch queues
/// - Preserves original console output (logs still appear in Xcode console)
/// - Posts notifications when new logs are captured
///
/// ## Usage
/// ```swift
/// // Start capturing console logs
/// ConsoleLogger.instance.start()
///
/// // Access captured logs
/// let logs = ConsoleLogger.instance.allLogs
///
/// // Clear all logs
/// ConsoleLogger.instance.clear()
///
/// // Stop capturing
/// ConsoleLogger.instance.stop()
/// ```
///
/// - Note: Only available on iOS, tvOS, and watchOS. Not supported on macOS.
public final class ConsoleLogger: @unchecked Sendable {
    // MARK: - Singleton

    /// Shared instance of the console logger.
    ///
    /// Use this singleton instance to start/stop logging and access captured log entries.
    public static let instance = ConsoleLogger()

    // MARK: - Static Data

    /// Maximum number of log entries to retain in memory.
    ///
    /// When this limit is exceeded, the oldest entries are automatically removed
    /// to prevent unbounded memory growth.
    private static let MaxLogEntries = 5000

    // MARK: - Data

    /// Array of captured log entries.
    private var logs: [ConsoleLogEntry] = []

    /// Concurrent queue for thread-safe access to the logs array.
    private let logsQueue = DispatchQueue(label: "com.scyther.consolelogger", attributes: .concurrent)

    /// Pipe used to intercept stdout.
    private var stdoutPipe: Pipe?

    /// Pipe used to intercept stderr.
    private var stderrPipe: Pipe?

    /// File descriptor for the original stdout stream.
    private var originalStdout: Int32 = -1

    /// File descriptor for the original stderr stream.
    private var originalStderr: Int32 = -1

    /// Indicates whether the logger is currently capturing console output.
    public private(set) var isCapturing = false

    // MARK: - Init

    /// Private initializer to enforce singleton pattern.
    private init() {}

    // MARK: - Public API

    /// Returns all captured log entries.
    ///
    /// This property provides thread-safe read access to the log entries.
    /// The array is ordered chronologically with the oldest entries first.
    ///
    /// ## Example
    /// ```swift
    /// let logs = ConsoleLogger.instance.allLogs
    /// for log in logs {
    ///     print("\(log.formattedTimestamp): \(log.message)")
    /// }
    /// ```
    public var allLogs: [ConsoleLogEntry] {
        logsQueue.sync { logs }
    }

    /// Starts capturing console output from stdout and stderr.
    ///
    /// This method redirects both standard output and standard error streams to internal pipes,
    /// allowing the logger to capture all console output. The original console output is preserved,
    /// so logs will still appear in the Xcode console.
    ///
    /// Calling this method multiple times has no effect if already capturing.
    ///
    /// ## Example
    /// ```swift
    /// ConsoleLogger.instance.start()
    /// print("This will be captured") // Appears in both Xcode console and ConsoleLogger
    /// ```
    ///
    /// - Note: Call `stop()` to restore the original console streams when finished.
    public func start() {
        guard !isCapturing else { return }
        isCapturing = true

        // Capture stdout
        captureStdout()

        // Capture stderr
        captureStderr()
    }

    /// Stops capturing console output and restores the original streams.
    ///
    /// This method restores the original stdout and stderr file descriptors, stopping
    /// console log capture. Previously captured logs remain available until cleared.
    ///
    /// Calling this method when not capturing has no effect.
    ///
    /// ## Example
    /// ```swift
    /// ConsoleLogger.instance.stop()
    /// print("This will not be captured")
    /// ```
    public func stop() {
        guard isCapturing else { return }
        isCapturing = false

        // Restore stdout
        if originalStdout != -1 {
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            originalStdout = -1
        }
        stdoutPipe = nil

        // Restore stderr
        if originalStderr != -1 {
            dup2(originalStderr, STDERR_FILENO)
            close(originalStderr)
            originalStderr = -1
        }
        stderrPipe = nil
    }

    /// Removes all captured log entries.
    ///
    /// This method clears the internal log buffer and posts a `ConsoleLoggerDidLog` notification
    /// to notify observers that the log state has changed.
    ///
    /// ## Example
    /// ```swift
    /// ConsoleLogger.instance.clear()
    /// print(ConsoleLogger.instance.allLogs.count) // 0
    /// ```
    public func clear() {
        logsQueue.async(flags: .barrier) {
            self.logs.removeAll()
        }
        NotificationCenter.default.post(name: .ConsoleLoggerDidLog, object: nil)
    }

    // MARK: - Capture Implementation

    /// Sets up stdout capture by redirecting the stream to a pipe.
    ///
    /// This method creates a pipe to intercept stdout while preserving the original output.
    /// Data written to stdout is captured for logging and also forwarded to the original stream.
    private func captureStdout() {
        stdoutPipe = Pipe()
        guard let pipe = stdoutPipe else { return }

        // Save original stdout
        originalStdout = dup(STDOUT_FILENO)

        // Redirect stdout to pipe
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        // Also write to original stdout so Xcode console still works
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Write to original stdout
            if let self = self, self.originalStdout != -1 {
                write(self.originalStdout, (data as NSData).bytes, data.count)
            }

            // Parse and store log
            if let message = String(data: data, encoding: .utf8) {
                self?.addLog(message: message, source: .stdout)
            }
        }
    }

    /// Sets up stderr capture by redirecting the stream to a pipe.
    ///
    /// This method creates a pipe to intercept stderr while preserving the original output.
    /// Data written to stderr is captured for logging and also forwarded to the original stream.
    private func captureStderr() {
        stderrPipe = Pipe()
        guard let pipe = stderrPipe else { return }

        // Save original stderr
        originalStderr = dup(STDERR_FILENO)

        // Redirect stderr to pipe
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        // Also write to original stderr so Xcode console still works
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Write to original stderr
            if let self = self, self.originalStderr != -1 {
                write(self.originalStderr, (data as NSData).bytes, data.count)
            }

            // Parse and store log
            if let message = String(data: data, encoding: .utf8) {
                self?.addLog(message: message, source: .stderr)
            }
        }
    }

    /// Adds a log message to the internal buffer.
    ///
    /// This method splits multi-line messages into separate log entries and enforces
    /// the maximum log entry limit by removing oldest entries when necessary.
    /// A notification is posted after adding the log to notify observers.
    ///
    /// - Parameters:
    ///   - message: The log message text to add.
    ///   - source: The source stream (stdout or stderr) that produced the message.
    private func addLog(message: String, source: ConsoleLogEntry.LogSource) {
        // Split by newlines and create separate entries for each line
        let lines = message.components(separatedBy: .newlines).filter { !$0.isEmpty }

        // Also written to disk, so a crash can be exported with the console output that led to it.
        SessionJournal.shared.recordConsole(lines, source: source.rawValue)

        logsQueue.async(flags: .barrier) {
            for line in lines {
                let entry = ConsoleLogEntry(
                    timestamp: Date(),
                    message: line,
                    source: source
                )
                self.logs.append(entry)
            }

            // Trim old logs if over limit
            if self.logs.count > Self.MaxLogEntries {
                self.logs.removeFirst(self.logs.count - Self.MaxLogEntries)
            }
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ConsoleLoggerDidLog, object: nil)
        }
    }
}
#endif
