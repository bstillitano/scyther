//
//  MenuViewModelTests.swift
//  ScytherTests
//
//  Created by Brandon Stillitano on 22/7/2026.
//

#if !os(macOS)
@testable import Scyther
import SwiftUI
import XCTest

@MainActor
final class MenuViewModelTests: XCTestCase {

    // MARK: - Sections

    func testEveryStaticItemAppearsInExactlyOneSection() {
        let items = MenuSection.allSections(developerOptions: []).flatMap(\.items)

        XCTAssertEqual(Set(items).count, items.count, "An item appears in more than one section")
        XCTAssertEqual(Set(items), Set(MenuItem.allStaticCases), "Sections do not cover every item")
    }

    func testDeviceSectionIsFirst() {
        XCTAssertEqual(MenuSection.allSections(developerOptions: []).first?.title, "Device")
    }

    func testDevelopmentToolsSectionIsOmittedWhenThereAreNoDeveloperOptions() {
        let titles = MenuSection.allSections(developerOptions: []).map(\.title)
        XCTAssertFalse(titles.contains("Development Tools"))
    }

    func testDevelopmentToolsSectionIsIncludedWhenDeveloperOptionsExist() {
        let options = [DeveloperOption(name: "Reset Onboarding", value: "tap")]
        let sections = MenuSection.allSections(developerOptions: options)

        let developmentTools = sections.first { $0.title == "Development Tools" }
        XCTAssertEqual(developmentTools?.items, [.developerOption(name: "Reset Onboarding")])
    }

    func testSectionTitlesAreInTheExpectedOrder() {
        let options = [DeveloperOption(name: "Panel", value: "x")]
        let titles = MenuSection.allSections(developerOptions: options).map(\.title)

        XCTAssertEqual(titles, [
            "Device",
            "Application",
            "Development Tools",
            "Networking",
            "Data",
            "Security",
            "System Tools",
            "Notifications",
            "UI/UX"
        ])
    }

    func testSectionIdentifiersAreUnique() {
        let ids = MenuSection.allSections(developerOptions: []).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: - Section tints

    func testEverySectionHasADedicatedTint() {
        let options = [DeveloperOption(name: "Panel", value: "x")]
        for section in MenuSection.allSections(developerOptions: options) {
            XCTAssertNotEqual(
                section.tint, .accentColor,
                "\"\(section.id)\" falls back to the accent colour — add it to MenuSection.tint(forID:)"
            )
        }
    }

    func testSectionTintsAreDistinct() {
        let options = [DeveloperOption(name: "Panel", value: "x")]
        let tints = MenuSection.allSections(developerOptions: options).map(\.tint)
        XCTAssertEqual(Set(tints).count, tints.count, "Two sections share a tile colour")
    }

    func testUnknownSectionTitleFallsBackToAccent() {
        XCTAssertEqual(MenuSection.tint(forID: "removedInV2"), .accentColor)
    }

    // MARK: - Pinning

    private var suiteName: String { "com.scyther.tests.menu" }

    private func makeDefaults() -> UserDefaults {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    private func wipeDefaults() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    /// Restores the process-global snapshot the badge tests published to.
    ///
    /// Constructing a `NetworkRuleStore` publishes its rules and its body directory to
    /// `NetworkRuleSnapshot`, which every later interceptor test reads.
    override func tearDown() {
        NetworkRuleSnapshot.update(isEnabled: true, rules: [])
    }

    func testNothingIsPinnedByDefault() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())

        XCTAssertTrue(viewModel.pinnedItemIDs.isEmpty)
        XCTAssertTrue(viewModel.pinnedItems.isEmpty)
    }

    func testPinningAppendsTheItem() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())

        viewModel.togglePin(for: .featureFlags)

        XCTAssertTrue(viewModel.isPinned(.featureFlags))
        XCTAssertEqual(viewModel.pinnedItems, [.featureFlags])
    }

    func testUnpinningRemovesTheItem() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())

        viewModel.togglePin(for: .featureFlags)
        viewModel.togglePin(for: .featureFlags)

        XCTAssertFalse(viewModel.isPinned(.featureFlags))
        XCTAssertTrue(viewModel.pinnedItems.isEmpty)
    }

    func testPinnedItemsAreOrderedOldestFirst() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())

        viewModel.togglePin(for: .crashLogs)
        viewModel.togglePin(for: .featureFlags)
        viewModel.togglePin(for: .fonts)

        XCTAssertEqual(viewModel.pinnedItems, [.crashLogs, .featureFlags, .fonts])
    }

    func testUnpinningDoesNotDisturbTheOrderOfOtherItems() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())

        viewModel.togglePin(for: .crashLogs)
        viewModel.togglePin(for: .featureFlags)
        viewModel.togglePin(for: .fonts)
        viewModel.togglePin(for: .featureFlags)

        XCTAssertEqual(viewModel.pinnedItems, [.crashLogs, .fonts])
    }

    func testRepinningMovesTheItemToTheEnd() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())

        viewModel.togglePin(for: .crashLogs)
        viewModel.togglePin(for: .fonts)
        viewModel.togglePin(for: .crashLogs)
        viewModel.togglePin(for: .crashLogs)

        XCTAssertEqual(viewModel.pinnedItems, [.fonts, .crashLogs])
    }

    func testPinStateSurvivesANewViewModel() {
        defer { wipeDefaults() }
        let defaults = makeDefaults()

        let first = MenuViewModel(defaults: defaults)
        first.togglePin(for: .keychainBrowser)
        first.togglePin(for: .cookies)

        let second = MenuViewModel(defaults: defaults)
        XCTAssertEqual(second.pinnedItems, [.keychainBrowser, .cookies])
    }

    func testPinsAreWrittenToTheInjectedStoreOnly() {
        defer { wipeDefaults() }
        let defaults = makeDefaults()

        let viewModel = MenuViewModel(defaults: defaults)
        viewModel.togglePin(for: .fonts)

        XCTAssertEqual(defaults.stringArray(forKey: MenuViewModel.pinnedItemsKey), ["fonts"])
    }

    func testStoredIdentifiersThatNoLongerResolveAreDropped() {
        defer { wipeDefaults() }
        let defaults = makeDefaults()
        defaults.set(["fonts", "removedInV2", "cookies"], forKey: MenuViewModel.pinnedItemsKey)

        let viewModel = MenuViewModel(defaults: defaults)

        XCTAssertEqual(viewModel.pinnedItems, [.fonts, .cookies])
    }

    func testPinnedDeveloperOptionThatNoLongerExistsIsDropped() {
        defer {
            wipeDefaults()
            Scyther.developerOptions = []
        }
        let defaults = makeDefaults()
        defaults.set(["developerOption.Gone", "fonts"], forKey: MenuViewModel.pinnedItemsKey)
        Scyther.developerOptions = []

        let viewModel = MenuViewModel(defaults: defaults)

        XCTAssertEqual(viewModel.pinnedItems, [.fonts])
    }

    func testPinnedDeveloperOptionThatStillExistsIsKept() {
        defer {
            wipeDefaults()
            Scyther.developerOptions = []
        }
        let defaults = makeDefaults()
        defaults.set(["developerOption.Panel"], forKey: MenuViewModel.pinnedItemsKey)
        Scyther.developerOptions = [DeveloperOption(name: "Panel", value: "x")]

        let viewModel = MenuViewModel(defaults: defaults)

        XCTAssertEqual(viewModel.pinnedItems, [.developerOption(name: "Panel")])
    }

    // MARK: - Consistency under a concurrent mutation

    func testDeveloperOptionRowsListedBySectionsStayResolvableAfterHostMutatesDeveloperOptions() {
        defer {
            wipeDefaults()
            Scyther.developerOptions = []
        }
        Scyther.developerOptions = [DeveloperOption(name: "Panel", value: "x")]
        let viewModel = MenuViewModel(defaults: makeDefaults())

        // This is the same item list `MenuView` uses to decide which rows to render (and to
        // wrap in a live swipe action via `pinnableRow`).
        let items = viewModel.sections.flatMap(\.items)
        XCTAssertTrue(items.contains(.developerOption(name: "Panel")))

        // A host app mutates `Scyther.developerOptions` while the menu is already on screen
        // -- e.g. between the section list being computed and a lazily-materialised row
        // actually being rendered.
        Scyther.developerOptions = []

        // Every developer-option row already committed to the item list above must still be
        // resolvable by name. If it isn't, `rowContent` renders nothing for that row while
        // `pinnableRow` has already wrapped it in a live swipe action -- a blank but
        // swipeable row.
        for item in items {
            guard case .developerOption(let name) = item else { continue }
            XCTAssertNotNil(
                viewModel.developerOption(named: name),
                "\"\(name)\" was listed by sections but can no longer be resolved for rendering"
            )
        }
    }

    // MARK: - Reloading pin state on reappearance

    func testPinnedItemIDsReloadOnSubsequentAppear() async {
        defer { wipeDefaults() }
        let defaults = makeDefaults()

        let viewModel = MenuViewModel(defaults: defaults)
        viewModel.togglePin(for: .fonts)
        XCTAssertEqual(viewModel.pinnedItemIDs, ["fonts"])

        // Simulate the pin state changing underneath this view model while the menu is off
        // screen -- e.g. "Reset all Scyther settings" in the UserDefaults browser, or a
        // hand-edit of `Scyther.Menu.PinnedItems`. The view model's `@StateObject` survives
        // this because `MenuView` sits at the root of a `UINavigationController`.
        defaults.removeObject(forKey: MenuViewModel.pinnedItemsKey)

        await viewModel.onSubsequentAppear()

        XCTAssertTrue(
            viewModel.pinnedItemIDs.isEmpty,
            "Reappearing after the underlying store changed should reload pin state from disk"
        )
    }

    func testPinnedItemIDsDoNotChangeBeforeTheFirstSubsequentAppear() {
        defer { wipeDefaults() }
        let defaults = makeDefaults()

        let viewModel = MenuViewModel(defaults: defaults)
        viewModel.togglePin(for: .fonts)

        // A change made to the backing store between init and the first reappearance should
        // not retroactively alter in-memory state until `onSubsequentAppear()` actually runs.
        defaults.removeObject(forKey: MenuViewModel.pinnedItemsKey)

        XCTAssertEqual(viewModel.pinnedItemIDs, ["fonts"])
    }

    func testIsPinnedAgreesWithPinnedItemIdentifiers() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())

        viewModel.togglePin(for: .gridOverlay)

        XCTAssertTrue(viewModel.isPinned(.gridOverlay))
        XCTAssertFalse(viewModel.isPinned(.fpsCounter))
        XCTAssertEqual(viewModel.pinnedItemIDs, [MenuItem.gridOverlay.id])
    }

    // MARK: - Search

    func testSearchResultsAreEmptyByDefault() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())

        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testSearchResultsReflectTheSearchText() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())

        viewModel.searchText = "feature flags"

        XCTAssertTrue(viewModel.searchResults.contains { $0.target == .featureFlags })
    }

    // MARK: - Assisted search

    /// Returns fixed entries for a specific query, nothing otherwise, after an
    /// optional artificial delay.
    private struct StubAssistant: MenuSearchAssistant {
        let query: String
        let stubbed: [MenuSearchEntry]
        var delay: Duration = .zero

        func matches(for query: String, in entries: [MenuSearchEntry]) async -> [MenuSearchEntry] {
            try? await Task.sleep(for: delay)
            return query == self.query ? stubbed : []
        }
    }

    private func indexEntry(for target: MenuItem) -> MenuSearchEntry {
        MenuSearchIndex.entries(developerOptions: [])
            .first { $0.target == target && !$0.isSubpageEntry }!
    }

    /// Polls until `condition` holds or ~1s elapses.
    private func waitUntil(_ condition: @autoclosure () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAssistantMatchesAppendAfterTheDebounce() async throws {
        defer { wipeDefaults() }
        let fps = indexEntry(for: .fpsCounter)
        let viewModel = MenuViewModel(
            defaults: makeDefaults(),
            assistants: [StubAssistant(query: "zzz", stubbed: [fps])],
            assistedSearchDelay: .milliseconds(1)
        )

        viewModel.searchText = "zzz"

        try await waitUntil(!viewModel.assistedResults.isEmpty)
        XCTAssertEqual(viewModel.assistedResults, [fps])
        XCTAssertEqual(viewModel.displayedSearchResults, [fps], "No sync matches for zzz — display is assisted only")
    }

    func testAssistantMatchesDedupeAgainstSynchronousResults() async throws {
        defer { wipeDefaults() }
        let flags = indexEntry(for: .featureFlags)
        let viewModel = MenuViewModel(
            defaults: makeDefaults(),
            assistants: [StubAssistant(query: "feature flags", stubbed: [flags])],
            assistedSearchDelay: .milliseconds(1)
        )

        viewModel.searchText = "feature flags"

        // Give the pipeline ample time to (wrongly) append a duplicate.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(viewModel.searchResults.contains(flags), "Precondition: sync tier already matches")
        XCTAssertTrue(viewModel.assistedResults.isEmpty, "Assistant duplicate of a sync result must be dropped")
    }

    func testAssistedResultsClearWhenTheQueryChanges() async throws {
        defer { wipeDefaults() }
        let fps = indexEntry(for: .fpsCounter)
        let viewModel = MenuViewModel(
            defaults: makeDefaults(),
            assistants: [StubAssistant(query: "zzz", stubbed: [fps])],
            assistedSearchDelay: .milliseconds(1)
        )

        viewModel.searchText = "zzz"
        try await waitUntil(!viewModel.assistedResults.isEmpty)

        viewModel.searchText = ""
        XCTAssertTrue(viewModel.assistedResults.isEmpty)
    }

    func testStaleAssistantResponsesAreDropped() async throws {
        defer { wipeDefaults() }
        let fps = indexEntry(for: .fpsCounter)
        let viewModel = MenuViewModel(
            defaults: makeDefaults(),
            assistants: [StubAssistant(query: "old", stubbed: [fps], delay: .milliseconds(100))],
            assistedSearchDelay: .milliseconds(1)
        )

        viewModel.searchText = "old"
        try await Task.sleep(for: .milliseconds(20))
        viewModel.searchText = "new"

        // Long after the slow "old" response would have landed, nothing may show:
        // the assistant only matches "old", and that query is stale.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(viewModel.assistedResults.isEmpty, "A response for a superseded query must be discarded")
    }

    // MARK: - Request overrides badge

    /// A throwaway override store, so counting the badge cannot depend on — or disturb — whatever
    /// the developer running the suite has configured.
    ///
    /// The suite and the body directory are both torn down. `wipeDefaults()` clears the *pinning*
    /// domain, which is a different one, so every badge test used to leave a populated preference
    /// domain behind on the machine that ran it.
    private func makeOverrideStore() -> NetworkRuleStore {
        let suiteName = "MenuViewModelTests.Overrides.\(UUID().uuidString)"
        let bodyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: bodyDirectory)
        }
        return NetworkRuleStore(defaults: UserDefaults(suiteName: suiteName)!,
                                bodyDirectory: bodyDirectory)
    }

    private func makeOverride(named name: String, isEnabled: Bool) -> NetworkRule {
        NetworkRule(
            id: UUID(),
            name: name,
            isEnabled: isEnabled,
            match: .path("/v1/*"),
            actions: NetworkRuleActions(stub: .mock(MockResponse(statusCode: 200, headers: [:], bodyID: nil, delay: 0)))
        )
    }

    func testTheOverrideCountIsZeroWhenNothingIsEnabled() {
        defer { wipeDefaults() }
        let store = makeOverrideStore()
        store.add(makeOverride(named: "off", isEnabled: false))
        let viewModel = MenuViewModel(defaults: makeDefaults(), networkRuleStore: store)

        XCTAssertEqual(viewModel.enabledOverrideCount, 0, "the badge is hidden when nothing is on")
    }

    /// The spec's safety affordance: the row's badge is what stops overrides being silently on.
    func testTheOverrideCountCountsEnabledPersistedAndTransientOverrides() {
        defer { wipeDefaults() }
        let store = makeOverrideStore()
        store.add(makeOverride(named: "on", isEnabled: true))
        store.add(makeOverride(named: "off", isEnabled: false))
        store.addTransient(makeOverride(named: "registered in code", isEnabled: true))

        let viewModel = MenuViewModel(defaults: makeDefaults(), networkRuleStore: store)

        XCTAssertEqual(viewModel.enabledOverrideCount, 2,
                       "an override registered from code is applied to live traffic too")
    }

    func testTheOverrideCountFollowsTheStoreWhileTheMenuIsOnScreen() {
        defer { wipeDefaults() }
        let store = makeOverrideStore()
        let viewModel = MenuViewModel(defaults: makeDefaults(), networkRuleStore: store)
        XCTAssertEqual(viewModel.enabledOverrideCount, 0)

        var rule = makeOverride(named: "on", isEnabled: true)
        store.add(rule)
        XCTAssertEqual(viewModel.enabledOverrideCount, 1)

        rule.isEnabled = false
        store.update(rule)
        XCTAssertEqual(viewModel.enabledOverrideCount, 0)
    }

    /// The badge's whole job is that overrides are never silently on. With the master switch off
    /// nothing is being applied, so a badge reading a count asserts the opposite of the truth.
    func testTheOverrideCountIsZeroWhileTheMasterSwitchIsOff() {
        defer { wipeDefaults() }
        let store = makeOverrideStore()
        store.add(makeOverride(named: "on", isEnabled: true))
        store.isEnabled = false

        let viewModel = MenuViewModel(defaults: makeDefaults(), networkRuleStore: store)

        XCTAssertEqual(viewModel.enabledOverrideCount, 0, "nothing is applied while overrides are switched off")
    }

    func testTheOverrideCountFollowsTheMasterSwitchWhileTheMenuIsOnScreen() {
        defer { wipeDefaults() }
        let store = makeOverrideStore()
        store.add(makeOverride(named: "on", isEnabled: true))
        let viewModel = MenuViewModel(defaults: makeDefaults(), networkRuleStore: store)
        XCTAssertEqual(viewModel.enabledOverrideCount, 1)

        store.isEnabled = false
        XCTAssertEqual(viewModel.enabledOverrideCount, 0)

        store.isEnabled = true
        XCTAssertEqual(viewModel.enabledOverrideCount, 1, "the overrides were never deleted, only stood down")
    }

    func testSearchResultsUseTheDeveloperOptionsSnapshot() {
        defer {
            wipeDefaults()
            Scyther.developerOptions = []
        }
        Scyther.developerOptions = [DeveloperOption(name: "Reset Onboarding", value: "tap")]
        let viewModel = MenuViewModel(defaults: makeDefaults())

        // Mutating the global after init must not change what search sees — the view
        // model searches the same snapshot `sections` renders from.
        Scyther.developerOptions = []
        viewModel.searchText = "onboarding"

        XCTAssertTrue(viewModel.searchResults.contains {
            $0.target == .developerOption(name: "Reset Onboarding")
        })
    }

    // MARK: - Held localised content

    /// `MenuView` reads `sections` several times per body, so it is stored rather than rebuilt per
    /// read. Republishing it would invalidate every row in the list, so a rebuild that changes
    /// nothing must not.
    func testRefreshingPublishesNothingWhenTheCopyHasNotChanged() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())

        var published = 0
        let cancellable = viewModel.$sections.sink { _ in published += 1 }
        defer { cancellable.cancel() }

        XCTAssertEqual(published, 1, "the current value arrives on subscription")
        let before = viewModel.sections

        viewModel.refreshLocalizedContent()

        XCTAssertEqual(published, 1, "an unchanged rebuild must not invalidate the whole list")
        XCTAssertEqual(viewModel.sections, before)
    }

    func testPinsSurviveARefreshOfTheLocalisedContent() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())
        viewModel.togglePin(for: .fonts)

        viewModel.refreshLocalizedContent()

        XCTAssertEqual(viewModel.pinnedItems, [.fonts])
    }

    func testSearchStillWorksAfterTheIndexIsDropped() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())
        viewModel.searchText = "feature flags"
        let before = viewModel.searchResults.map(\.id)

        // Dropping and rebuilding the index is how a language change reaches search.
        viewModel.refreshLocalizedContent()

        XCTAssertFalse(before.isEmpty)
        XCTAssertEqual(viewModel.searchResults.map(\.id), before)
    }

    func testAnEmptyQueryMatchesNothing() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())

        viewModel.searchText = "   "

        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    // MARK: - Row values

    /// The fixed device and application facts are read once per menu, not once per row render.
    /// Among them is a keychain query that *adds* an item when it finds none, and a file stat.
    func testDeviceValuesAreReadOnce() {
        defer { wipeDefaults() }
        var reads = 0
        let viewModel = MenuViewModel(
            defaults: makeDefaults(),
            deviceValues: {
                reads += 1
                return [.osVersion: "17.0", .hardware: "iPhone17,1"]
            }
        )

        XCTAssertEqual(viewModel.valueDescription(for: .osVersion), "17.0")
        XCTAssertEqual(viewModel.valueDescription(for: .hardware), "iPhone17,1")
        XCTAssertEqual(viewModel.valueDescription(for: .osVersion), "17.0")

        XCTAssertEqual(reads, 1, "the device facts must be snapshotted, not read per row")
    }

    func testDeviceValuesComeFromTheDeviceByDefault() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())

        XCTAssertEqual(viewModel.valueDescription(for: .processId), String(getpid()))
        XCTAssertEqual(viewModel.valueDescription(for: .osVersion), UIDevice.current.systemVersion)
    }

    func testRowsWithoutAPlainValueHaveNoDescription() {
        defer { wipeDefaults() }
        let viewModel = MenuViewModel(defaults: makeDefaults())

        // Navigation, toggle, and the asynchronously loaded IP address.
        XCTAssertNil(viewModel.valueDescription(for: .networkLogs))
        XCTAssertNil(viewModel.valueDescription(for: .slowAnimations))
        XCTAssertNil(viewModel.valueDescription(for: .ipAddress))
    }

    /// Push tokens are the exception to the snapshot: the host app sets them, possibly after the
    /// menu is already on screen.
    func testPushTokensAreReadLive() {
        defer {
            wipeDefaults()
            Scyther.apnsToken = nil
        }
        let viewModel = MenuViewModel(defaults: makeDefaults())
        XCTAssertEqual(viewModel.valueDescription(for: .apnsToken), "Not set")

        Scyther.apnsToken = "a-token-set-while-the-menu-is-open"

        XCTAssertEqual(viewModel.tokenValue(for: .apnsToken), "a-token-set-while-the-menu-is-open")
        XCTAssertEqual(
            viewModel.valueDescription(for: .apnsToken),
            "a-token-set-while-the-menu-is-open"
        )
    }
}
#endif
