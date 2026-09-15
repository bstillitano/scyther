//
//  PseudoLocalizationModeCache.swift
//  Scyther
//
//  Created by Brandon Stillitano on 16/9/2026.
//

import Foundation

/// An in-memory copy of the pseudo-localisation switches, so resolving a string never has to read
/// `UserDefaults`.
///
/// ``localized(_:comment:override:)`` asks ``PseudoLocalization/activeModes`` whether a text mode
/// is on for every string Scyther resolves, and one render of the main menu resolves around 1,500
/// of them. Reading the five switches from the defaults suite each time was measured at about 2 ms
/// per read in the iOS Simulator — every read goes to `cfprefsd`, which runs an entitlement check
/// against the code signature on disk — and turned opening the menu into a freeze of 10 to 28
/// seconds. The switches are now loaded once and served from memory until something changes them.
///
/// ## Staying correct
///
/// A cache is only worth having if it is never wrong, so ``invalidate()`` runs on every path that
/// can change what is persisted:
///
/// - ``PseudoLocalization``'s own setters and ``PseudoLocalization/reset()``, directly.
/// - Every other in-process write, through `UserDefaults.didChangeNotification`. That covers the
///   UserDefaults browser editing a key, a test writing the suite directly, and "Reset all Scyther
///   settings", which removes the whole persistent domain. Key-value observation was measured and
///   rejected: it sees a key written through any instance of the suite, but not a removed domain.
///
/// A load that races an invalidation is returned to its caller but never stored; see ``modes()``.
///
/// ## Topics
///
/// ### Creating a Cache
/// - ``init(load:)``
///
/// ### Reading
/// - ``modes()``
///
/// ### Invalidating
/// - ``invalidate()``
final class PseudoLocalizationModeCache: @unchecked Sendable {
    /// Serialises access to ``cached`` and ``generation``.
    private let lock = NSLock()

    /// The modes last loaded, or `nil` when the next ``modes()`` must load them. Guarded by ``lock``.
    private var cached: PseudoLocalizationMode?

    /// Incremented by every ``invalidate()``, so ``modes()`` can tell its load has gone stale.
    /// Guarded by ``lock``.
    private var generation: UInt64 = 0

    /// Reads the modes from wherever they are persisted.
    private let load: () -> PseudoLocalizationMode

    /// Creates an empty cache.
    ///
    /// - Parameter load: Reads the modes from their persistent store. Called by the first
    ///   ``modes()`` and by the first after each ``invalidate()``, on whichever thread asked, and
    ///   never while the cache's lock is held.
    init(load: @escaping () -> PseudoLocalizationMode) {
        self.load = load
    }

    /// The current modes, read from the store only when nothing is cached.
    ///
    /// The load runs outside the lock, so a slow store never blocks another thread, and a store
    /// that posts a change notification while it is being read cannot deadlock against
    /// ``invalidate()``. The cost is a race, which ``generation`` settles: if an invalidation lands
    /// while the load is running, the loaded value may predate the write that caused it, so it is
    /// handed back to this caller but not kept.
    ///
    /// - Returns: The persisted modes, before any environment gating.
    func modes() -> PseudoLocalizationMode {
        let snapshot = lock.withLock { (modes: cached, generation: generation) }
        if let modes = snapshot.modes { return modes }

        let loaded = load()
        lock.withLock {
            if generation == snapshot.generation { cached = loaded }
        }
        return loaded
    }

    /// Discards the cached modes, so the next ``modes()`` reads the store again.
    func invalidate() {
        lock.withLock {
            cached = nil
            generation &+= 1
        }
    }
}
