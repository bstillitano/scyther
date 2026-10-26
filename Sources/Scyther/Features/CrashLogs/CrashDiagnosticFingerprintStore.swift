//
//  CrashDiagnosticFingerprintStore.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation

/// Persists the fingerprints of the MetricKit diagnostics Scyther has already ingested, in
/// `UserDefaults.scyther`.
///
/// MetricKit offers the same diagnostics again on later launches, so without this every launch
/// would store them again. Clearing the crash log does not clear the fingerprints, deliberately: a
/// crash the developer cleared must not come back on the next launch.
///
/// The newest ``maxFingerprints`` are kept, far more than MetricKit ever offers again.
final class CrashDiagnosticFingerprintStore: CrashDiagnosticFingerprintStoring, @unchecked Sendable {
    /// Shared instance.
    static let shared = CrashDiagnosticFingerprintStore()

    /// The key the fingerprints are stored under.
    private let key: String

    /// The suite the fingerprints are stored in.
    private let defaults: UserDefaults

    /// How many fingerprints are kept.
    static let maxFingerprints = 500

    /// Serialises the read-modify-write in ``insert(_:)``.
    private let lock = NSLock()

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - defaults: The suite to store in. Scyther's own by default.
    ///   - key: The key to store under.
    init(defaults: UserDefaults = .scyther, key: String = "Scyther_CrashDiagnosticFingerprints") {
        self.defaults = defaults
        self.key = key
    }

    var fingerprints: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(stored)
    }

    func insert(_ fingerprints: [String]) {
        lock.lock()
        defer { lock.unlock() }
        var updated = stored
        updated.append(contentsOf: fingerprints.filter { !updated.contains($0) })
        defaults.set(Array(updated.suffix(Self.maxFingerprints)), forKey: key)
    }

    /// The stored fingerprints, oldest first.
    private var stored: [String] {
        defaults.stringArray(forKey: key) ?? []
    }
}
#endif
