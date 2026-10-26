//
//  ArchiveExportViewModel.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

import Foundation

/// The shared logic behind every sheet that builds a zip archive, offers to redact it, and shares
/// it: the network log export and the crash export.
///
/// On first appearance it builds the archive off the main actor, publishing ``state`` transitions
/// so the sheet can show progress, the finished archive, or an error. Toggling redaction through
/// ``setRedaction(_:)`` rebuilds the archive in place. ``cleanup()`` deletes the archive when the
/// sheet closes.
///
/// Subclasses supply the export itself and whatever they describe the archive's contents with.
class ArchiveExportViewModel: ViewModel {
    /// The stages of an export.
    enum State: Equatable, Sendable {
        /// The archive is being written.
        case preparing
        /// The archive is ready at the given URL.
        case ready(URL)
        /// The export failed with a user-facing message.
        case failed(String)
    }

    /// The current stage of the export.
    @Published private(set) var state: State = .preparing

    /// Whether the archive is redacted. Defaults to on.
    @Published private(set) var redactSensitiveValues: Bool = true

    /// Whether a replacement archive is being built after a setting change.
    ///
    /// While true, ``state`` still holds the previous archive so the sheet can keep its rows in
    /// place and show an inline spinner rather than tearing the section down.
    @Published private(set) var isRebuilding: Bool = false

    /// The shortest time a rebuild is allowed to take, so the inline spinner is seen rather than flickering.
    static let defaultMinimumRebuildDuration: Duration = .milliseconds(750)

    /// Produces the archive for a redaction setting.
    private let archive: @Sendable (Bool) throws -> URL

    /// The minimum wall-clock time for a rebuild triggered by ``setRedaction(_:)``.
    private let minimumRebuildDuration: Duration

    /// Creates an export view model.
    ///
    /// - Parameters:
    ///   - minimumRebuildDuration: Floor on how long a rebuild appears to take. Pass `.zero` in tests.
    ///   - archive: Builds the archive, given whether to redact it. Runs off the main actor.
    init(minimumRebuildDuration: Duration, archive: @escaping @Sendable (Bool) throws -> URL) {
        self.minimumRebuildDuration = minimumRebuildDuration
        self.archive = archive
        super.init()
    }

    /// The finished archive, once ``state`` is ``State/ready(_:)``.
    var archiveURL: URL? {
        if case .ready(let url) = state { return url }
        return nil
    }

    /// The finished archive's filename, for display.
    var archiveFilename: String? { archiveURL?.lastPathComponent }

    /// Builds the archive off the main actor and publishes the outcome.
    override func onFirstAppear() async {
        await super.onFirstAppear()
        await build()
    }

    /// Changes the redaction setting and rebuilds the archive.
    ///
    /// The setting and ``isRebuilding`` flip synchronously so a bound `Toggle` never bounces. The
    /// previous archive stays in ``state`` until the replacement is ready, after which the old
    /// file is deleted. The rebuild is padded to at least the minimum duration so the spinner is
    /// visible rather than a flicker.
    ///
    /// - Parameter enabled: Whether to redact.
    /// - Returns: The rebuild task, or `nil` when the value did not change. Await it in tests.
    @discardableResult
    func setRedaction(_ enabled: Bool) -> Task<Void, Never>? {
        guard enabled != redactSensitiveValues else { return nil }
        redactSensitiveValues = enabled
        isRebuilding = true
        let previous = archiveURL
        let minimum = minimumRebuildDuration
        return Task { @MainActor in
            let started = ContinuousClock.now
            await build()
            let remaining = minimum - (ContinuousClock.now - started)
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
            isRebuilding = false
            if let previous, previous != archiveURL {
                try? FileManager.default.removeItem(at: previous)
            }
        }
    }

    private func build() async {
        let redact = redactSensitiveValues
        let archive = self.archive
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try archive(redact)
            }.value
            state = .ready(url)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Deletes the archive file, if one was produced.
    func cleanup() {
        guard let archiveURL else { return }
        try? FileManager.default.removeItem(at: archiveURL)
    }
}

/// Identified by the instance, so a sheet can be presented with `sheet(item:)` for exactly the
/// export it was opened for.
extension ArchiveExportViewModel: Identifiable {}
