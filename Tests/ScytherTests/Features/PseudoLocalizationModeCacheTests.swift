//
//  PseudoLocalizationModeCacheTests.swift
//  ScytherTests
//
//  Created by Brandon Stillitano on 16/9/2026.
//

#if !os(macOS)
@testable import Scyther
import XCTest

/// Records every key read out of the store, so a test can assert that resolving a string does not
/// read any.
///
/// Keys rather than a bare count, because `UserDefaults.bool(forKey:)` is itself implemented on top
/// of `object(forKey:)`: a subclass sees one read of a `Bool` switch twice, and a test asserting on
/// the total would be asserting on that implementation detail.
private final class CountingDefaults: UserDefaults {
    /// Every key read through this store, in order, including repeats.
    private(set) var keysRead: [String] = []

    override func bool(forKey defaultName: String) -> Bool {
        keysRead.append(defaultName)
        return super.bool(forKey: defaultName)
    }

    override func object(forKey defaultName: String) -> Any? {
        keysRead.append(defaultName)
        return super.object(forKey: defaultName)
    }
}

/// Covers ``PseudoLocalizationModeCache`` and the thing it exists for: reading the
/// pseudo-localisation switches must not touch `UserDefaults` once per string, and must still never
/// be out of date.
///
/// The cost this guards against is specific to the iOS Simulator, where every defaults read goes to
/// `cfprefsd` and costs about 2 ms. One render of the main menu resolves around 1,500 strings, and
/// reading five switches for each of them froze the menu for 10 to 28 seconds.
@MainActor
final class PseudoLocalizationModeCacheTests: XCTestCase {

    /// A throwaway suite, so nothing here touches the settings a developer has persisted.
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PseudoLocalizationModeCacheTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    // MARK: - The cache

    func testTheFirstReadLoadsAndLaterReadsDoNot() {
        var loads = 0
        let cache = PseudoLocalizationModeCache {
            loads += 1
            return .accented
        }

        for _ in 0..<100 {
            XCTAssertEqual(cache.modes(), .accented)
        }

        XCTAssertEqual(loads, 1, "the store must be read once, not once per ask")
    }

    func testInvalidatingCostsExactlyOneMoreLoad() {
        var loads = 0
        let cache = PseudoLocalizationModeCache {
            loads += 1
            return .lengthened
        }

        _ = cache.modes()
        cache.invalidate()
        for _ in 0..<10 {
            _ = cache.modes()
        }

        XCTAssertEqual(loads, 2)
    }

    /// The load deliberately runs outside the lock, so an invalidation can land while it is in
    /// flight. That value may predate the write that caused the invalidation, so it must not be
    /// kept — and the invalidation must not deadlock against the load either, which is what makes
    /// invalidating from *inside* the load a fair test of both.
    func testALoadThatRacedAnInvalidationIsNotKept() {
        var loads = 0
        var cache: PseudoLocalizationModeCache!
        cache = PseudoLocalizationModeCache {
            loads += 1
            if loads == 1 { cache.invalidate() }
            return loads == 1 ? .accented : .lengthened
        }

        XCTAssertEqual(cache.modes(), .accented, "the racing caller still gets the value it read")
        XCTAssertEqual(cache.modes(), .lengthened, "but it was not cached, so the next ask reloads")
        XCTAssertEqual(loads, 2)
    }

    // MARK: - What the hot path costs

    func testResolvingManyStringsReadsTheSwitchesOnce() {
        let counting = CountingDefaults(suiteName: suiteName)!
        let settings = PseudoLocalization(defaults: counting)

        _ = settings.storedModes
        let afterFirstRead = counting.keysRead.count
        XCTAssertEqual(
            Set(counting.keysRead),
            [
                PseudoLocalization.AccentedDefaultsKey,
                PseudoLocalization.LengthenedDefaultsKey,
                PseudoLocalization.RightToLeftDefaultsKey,
                PseudoLocalization.ShowsKeysDefaultsKey,
                PseudoLocalization.ShowsBoundariesDefaultsKey,
            ],
            "the five switches are read together, in one load"
        )

        for _ in 0..<100 {
            _ = settings.activeModes
        }

        // An unrelated `UserDefaults` write anywhere in the process invalidates the cache, so this
        // allows for one further load rather than asserting the store is never touched again.
        // Without the cache these 100 asks would each have read all five switches.
        XCTAssertLessThanOrEqual(
            counting.keysRead.count, afterFirstRead * 2,
            "reading the modes must not go back to the store per string"
        )
    }

    // MARK: - Staying in step with the store

    func testAWriteThroughAnotherInstanceOfTheSuiteIsPickedUp() {
        let settings = PseudoLocalization(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertFalse(settings.accented)

        // The UserDefaults browser editing a key, or a test writing the suite directly.
        UserDefaults(suiteName: suiteName)!.set(true, forKey: PseudoLocalization.AccentedDefaultsKey)

        XCTAssertTrue(settings.accented, "a write through another instance must not leave a stale cache")
    }

    /// "Reset all Scyther settings" removes the whole suite, through `UserDefaults.standard`. This
    /// is the case key-value observation missed, and the reason the cache listens for change
    /// notifications instead.
    func testRemovingThePersistentDomainIsPickedUp() {
        let settings = PseudoLocalization(defaults: UserDefaults(suiteName: suiteName)!)
        settings.accented = true
        settings.showsBoundaries = false
        XCTAssertTrue(settings.accented)

        UserDefaults.standard.removePersistentDomain(forName: suiteName)

        XCTAssertFalse(settings.accented, "a wiped suite must read as switched off")
        XCTAssertTrue(settings.showsBoundaries, "and the one switch that ships on must read as on again")
    }

    func testTheCacheFollowsItsOwnSetters() {
        let settings = PseudoLocalization(defaults: UserDefaults(suiteName: suiteName)!)

        settings.accented = true
        XCTAssertEqual(settings.storedModes, [.accented, .showsBoundaries])

        settings.lengthened = true
        XCTAssertEqual(settings.storedModes, [.accented, .lengthened, .showsBoundaries])

        settings.reset()
        XCTAssertEqual(settings.storedModes, .showsBoundaries)
    }
}
#endif
