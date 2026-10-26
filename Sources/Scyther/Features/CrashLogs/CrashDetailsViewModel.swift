//
//  CrashDetailsViewModel.swift
//  Scyther
//
//  Created by Brandon Stillitano on 22/12/2024.
//

#if !os(macOS)
import Foundation
import UIKit

/// View model for managing the crash details view.
///
/// `CrashDetailsViewModel` handles the state and logic for displaying
/// detailed crash information, including stack trace filtering and
/// clipboard operations.
///
/// ## Features
/// - Stack trace search and filtering with highlighting
/// - Copy to clipboard with visual feedback
/// - Formatted crash report generation for sharing
///
/// ## Usage
/// ```swift
/// @StateObject private var viewModel: CrashDetailsViewModel
///
/// init(crash: CrashLogEntry) {
///     _viewModel = StateObject(wrappedValue: CrashDetailsViewModel(crash: crash))
/// }
///
/// // Filter stack trace
/// viewModel.searchText = "UIKit"
/// let filtered = viewModel.filteredStackTrace
/// ```
///
/// ## Topics
///
/// ### Properties
/// - ``crash``
/// - ``searchText``
/// - ``copied``
/// - ``filteredStackTrace``
///
/// ### Methods
/// - ``copyToClipboard()``
@MainActor
class CrashDetailsViewModel: ViewModel {
    // MARK: - Properties

    /// The crash log entry being displayed.
    let crash: CrashLogEntry

    /// The crash's threads, images and codes, once loaded — `nil` before that, and for a crash
    /// stored before they were captured.
    @Published private(set) var details: CrashDetails?

    /// The crash in the layout of Apple's text crash reports: every thread and binary image, and
    /// the `atos` command for the app's frames. Until it is loaded, the entry's own report.
    @Published private(set) var fullReport: String

    /// Where the crash's details are read from.
    private let artifacts: CrashArtifactStore

    /// Where the crash's session is read from.
    private let journal: SessionJournal

    // MARK: - Published Properties

    /// The current search text for filtering the stack trace.
    ///
    /// When set, ``filteredStackTrace`` will only include frames
    /// that contain this text (case-insensitive).
    @Published var searchText: String = ""

    /// Whether the crash report was recently copied to clipboard.
    ///
    /// This property is automatically reset to `false` after 2 seconds
    /// to provide visual feedback for the copy action.
    @Published var copied: Bool = false

    // MARK: - Computed Properties

    /// Stack trace entries filtered by the current search text.
    ///
    /// Each entry includes its original index and the symbol text.
    /// If ``searchText`` is empty, all frames are returned.
    var filteredStackTrace: [(index: Int, symbol: String)] {
        let indexed = crash.stackTrace.enumerated().map { (index: $0.offset, symbol: $0.element) }
        if searchText.isEmpty {
            return indexed
        }
        return indexed.filter { $0.symbol.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: - Initialization

    /// Creates a new crash details view model.
    ///
    /// - Parameter crash: The crash log entry to display details for.
    init(crash: CrashLogEntry, artifacts: CrashArtifactStore = .shared, journal: SessionJournal = .shared) {
        self.crash = crash
        self.artifacts = artifacts
        self.journal = journal
        self.fullReport = crash.fullReport
        super.init()
    }

    /// Reads the crash's details and formats its full report, off the main actor: both read
    /// files, and the report runs to every frame of every thread.
    override func onFirstAppear() async {
        await super.onFirstAppear()
        let crash = self.crash
        let artifacts = self.artifacts
        let journal = self.journal
        let loaded = await Task.detached(priority: .userInitiated) {
            let details = artifacts.details(for: crash.id)
            let session = crash.sessionID.flatMap { id in journal.sessions().first { $0.id == id } }
            return (details, CrashReportFormatter.report(entry: crash, details: details, session: session))
        }.value
        details = loaded.0
        fullReport = loaded.1
    }

    /// The exception codes, in hex, or `nil` when there are none.
    var exceptionCodes: String? {
        guard let codes = details?.exceptionCodes, !codes.isEmpty else { return nil }
        return codes.map { String(format: "0x%016llx", $0) }.joined(separator: ", ")
    }

    /// How many threads were captured.
    var threadCount: Int { details?.threads.count ?? 0 }

    /// A view model for exporting this crash.
    func makeExportViewModel() -> CrashExportViewModel {
        CrashExportViewModel(crashes: [crash])
    }

    // MARK: - Public Methods

    /// Copies the full crash report to the clipboard.
    ///
    /// This method copies ``fullReport`` to the system
    /// clipboard and sets ``copied`` to `true` for visual feedback.
    /// The `copied` flag is automatically reset after 2 seconds.
    func copyToClipboard() {
        UIPasteboard.general.string = fullReport
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                copied = false
            }
        }
    }
}
#endif
