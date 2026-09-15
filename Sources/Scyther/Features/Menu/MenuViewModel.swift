//
//  MenuViewModel.swift
//  Scyther
//
//  Created by Brandon Stillitano on 16/6/2025.
//

import Combine
import Foundation
import SwiftUI
import UIKit

/// View model for the main menu interface.
///
/// `MenuViewModel` manages the state and data loading for the Scyther developer menu,
/// including network information retrieval and UI toolkit settings synchronization.
///
/// ## Features
///
/// - **Menu Structure**: Supplies the ordered section layout and the set of pinned rows
/// - **Pinning**: Persists pinned rows to Scyther's preferences suite, oldest pin first
/// - **Row Values**: Snapshots the fixed device and application facts the value rows show
/// - **Network Information**: Asynchronously fetches and displays the device's current IP address
/// - **Animation Controls**: Manages slow animations mode for UI debugging
/// - **View Debugging**: Controls visibility of view frames and sizes
/// - **Automatic Synchronization**: Two-way binding with ``InterfaceToolkit`` settings
///
/// ## Everything localised is held, not recomputed
///
/// ``sections`` and the search index both hold resolved copy, and both are stored rather than
/// computed, because `MenuView` reads them repeatedly while it renders — once per row for the count
/// pass and once for the render pass. Recomputing them there is what made opening the menu slow:
/// each rebuild resolves every section title, and each keystroke rebuilt the whole search index.
/// ``refreshLocalizedContent()`` rebuilds both, and only the two things that can change what the
/// copy says trigger it: the effective language, and the menu reappearing (which is how a
/// pseudo-localisation switch flipped on its own page gets picked up).
///
/// ## Usage
///
/// The view model is used by ``MenuView`` to manage its state:
///
/// ```swift
/// struct MenuView: View {
///     @StateObject private var viewModel = MenuViewModel()
///
///     var body: some View {
///         List {
///             // IP address with loading indicator
///             row(
///                 withLabel: "IP Address",
///                 description: viewModel.ipAddress,
///                 andLoadingState: viewModel.isLoadingIPAddress
///             )
///
///             // Toggle controls bound to view model
///             Toggle("Slow Animations", isOn: $viewModel.slowAnimationsEnabled)
///             Toggle("Show View Frames", isOn: $viewModel.showViewFrames)
///             Toggle("Show View Sizes", isOn: $viewModel.showViewSizes)
///         }
///         .onFirstAppear {
///             await viewModel.onFirstAppear()
///         }
///     }
/// }
/// ```
///
/// ## Topics
///
/// ### Menu Structure
///
/// - ``sections``
/// - ``pinnedItems``
/// - ``pinnedItemIDs``
/// - ``isPinned(_:)``
/// - ``togglePin(for:)``
/// - ``developerOption(named:)``
/// - ``refreshLocalizedContent()``
///
/// ### Row Values
///
/// - ``valueDescription(for:)``
/// - ``tokenValue(for:)``
///
/// ### Search
///
/// - ``searchText``
/// - ``searchResults``
/// - ``assistedResults``
/// - ``displayedSearchResults``
///
/// ### Network Information
///
/// - ``ipAddress``
/// - ``isLoadingIPAddress``
///
/// ### Request Overrides
///
/// - ``enabledOverrideCount``
///
/// ### Network Conditioning
///
/// - ``conditioningSummary``
///
/// ### UI Debugging Controls
///
/// - ``slowAnimationsEnabled``
/// - ``layoutGuidesEnabled``
/// - ``canShowLayoutGuides``
/// - ``canShowViewHierarchy``
/// - ``activateLayoutRuler()``
/// - ``showsLayoutRulerUnavailableAlert``
/// - ``showViewFrames``
/// - ``showViewSizes``
///
/// ### Lifecycle
///
/// - ``onFirstAppear()``
/// - ``onSubsequentAppear()``
@MainActor
class MenuViewModel: ViewModel {
    // MARK: - Menu Structure

    /// The key backing ``pinnedItemIDs`` in Scyther's preferences store.
    static let pinnedItemsKey = "Scyther.Menu.PinnedItems"

    /// The store pinned item identifiers are read from and written to.
    private let defaults: UserDefaults

    /// The override store the Request Overrides row's badge counts.
    private let networkRuleStore: NetworkRuleStore

    /// The conditioning store the Network Conditioning row's detail text describes.
    private let conditioningStore: NetworkConditioningStore

    /// The breakpoint store this view model mirrors.
    private let breakpointStore: BreakpointStore

    /// The language override whose changes re-resolve every title this view model holds.
    private let languageOverride: LanguageOverride

    /// Keeps the override store's publishers alive for the lifetime of the menu.
    private var cancellables: Set<AnyCancellable> = []

    /// How many request overrides are currently being applied, persisted and transient together.
    ///
    /// Shown as a badge on the Request Overrides row so overrides are never silently on. A
    /// developer chasing a response that will not change has to be able to see, from the menu's
    /// first screen, that something is rewriting their traffic — the MOCKED badge is only visible
    /// inside the network log, and the master switch only on the overrides screen itself.
    ///
    /// Zero when nothing is enabled, which is what hides the badge — and zero while the master
    /// switch is off, however many overrides are enabled behind it. The badge says what is being
    /// applied, not what is configured; with the switch off nothing is, and a count there would
    /// send that developer looking for an override that is not running.
    @Published private(set) var enabledOverrideCount: Int = 0

    /// How many breakpoints are currently being applied.
    ///
    /// Shown as a badge on the Breakpoints row, for a sharper version of the reason the override
    /// count is shown: an override changes a response, while a breakpoint stops the app until
    /// somebody decides what to do. A developer whose app has just frozen needs to be able to see
    /// why from the menu's first screen.
    ///
    /// Zero while the master switch is off, however many breakpoints are enabled behind it.
    @Published private(set) var enabledBreakpointCount: Int = 0

    /// What the Network Conditioning row shows as its detail text: the active preset, `Custom`,
    /// or `Off`.
    ///
    /// Conditioning applies to every request the app makes, so it has to be visible from the
    /// menu's first screen for the same reason the override count is — a developer who has
    /// forgotten it is on will otherwise spend an afternoon blaming their backend.
    @Published private(set) var conditioningSummary: String = localized("Off")

    /// The identifiers of pinned rows, in the order they were pinned.
    ///
    /// An array rather than a `Set` so that oldest-first pin order survives a relaunch.
    @Published private(set) var pinnedItemIDs: [String] {
        didSet { pinnedItems = Self.resolvePinnedItems(from: pinnedItemIDs, in: sections) }
    }

    /// A snapshot of ``Scyther/developerOptions``, taken once when the view model is created.
    ///
    /// `Scyther.developerOptions` is a `nonisolated(unsafe)` global a host app can mutate at
    /// any time, including while the menu is on screen. ``sections``, ``pinnedItems``, and
    /// ``developerOption(named:)`` all derive from this single stored copy rather than
    /// re-reading the global independently, so they can never disagree about which developer
    /// options exist for the lifetime of this view model. Without that, a section could list a
    /// `.developerOption(name:)` row that a later, independent lookup could no longer resolve —
    /// `MenuView` would render nothing for that row while its swipe-to-pin action, attached
    /// alongside the row content, remains live.
    private let developerOptions: [DeveloperOption]

    /// The full menu layout, including any host-supplied developer options.
    ///
    /// Stored, not computed: every section header here is resolved copy, and `MenuView` reads this
    /// several times per body. Rebuilt only by ``refreshLocalizedContent()``.
    @Published private(set) var sections: [MenuSection]

    /// The pinned rows, oldest pin first.
    ///
    /// Stored identifiers that no longer resolve to a row currently present in ``sections``
    /// are dropped. This covers both a feature removed in a later version of Scyther and a
    /// developer option the host app no longer registers.
    ///
    /// Maintained alongside ``pinnedItemIDs`` rather than computed from it, because computing it
    /// meant rebuilding and flattening every section — twice per menu body, since `MenuView` asks
    /// whether there are any pins before it renders them.
    private(set) var pinnedItems: [MenuItem]

    /// Resolves stored pin identifiers against the rows the menu is actually showing.
    ///
    /// - Parameters:
    ///   - ids: The persisted identifiers, oldest pin first.
    ///   - sections: The layout the pins must resolve against.
    /// - Returns: The pinned rows, in pin order, without any that no longer exist.
    private static func resolvePinnedItems(from ids: [String], in sections: [MenuSection]) -> [MenuItem] {
        let available = Set(sections.flatMap(\.items))
        return ids
            .compactMap(MenuItem.init(id:))
            .filter { available.contains($0) }
    }

    /// Resolves a host-supplied developer option by name.
    ///
    /// Looks up the option in ``developerOptions``, the snapshot also used to build
    /// ``sections`` — the same name that appears in a `.developerOption(name:)` row is
    /// therefore always resolvable here, regardless of what a host app has since done to
    /// `Scyther.developerOptions`.
    ///
    /// - Parameter name: A developer option's ``DeveloperOption/name``, as carried by a
    ///   ``MenuItem/developerOption(name:)`` row.
    /// - Returns: The matching option, or `nil` if none was registered under that name when
    ///   this view model was created.
    func developerOption(named name: String) -> DeveloperOption? {
        developerOptions.first { $0.name == name }
    }

    /// Re-resolves everything this view model holds that is localised copy: ``sections`` and the
    /// search index.
    ///
    /// Called when the effective language changes, and on every reappearance of the menu — which is
    /// what picks up a pseudo-localisation mode switched on from its own page, since that page is
    /// pushed on top of this one.
    ///
    /// ``sections`` is only republished when the rebuild differs, so a reappearance that changed
    /// nothing does not invalidate every row in the list.
    func refreshLocalizedContent() {
        let rebuilt = MenuSection.allSections(developerOptions: developerOptions)
        if rebuilt != sections {
            sections = rebuilt
            pinnedItems = Self.resolvePinnedItems(from: pinnedItemIDs, in: rebuilt)
        }
        searchIndex = nil
    }

    /// Creates a menu view model.
    ///
    /// Snapshots ``Scyther/developerOptions`` at this point — see ``developerOptions``.
    ///
    /// - Parameters:
    ///   - defaults: The store backing pin state. Defaults to Scyther's private
    ///     preferences suite; tests inject a throwaway suite.
    ///   - assistants: The fuzzy-search tiers, in pipeline order. Defaults to the
    ///     tiers available on this device; tests inject mocks.
    ///   - assistedSearchDelay: The typing pause before assistants run. Defaults to
    ///     300 ms; tests inject something shorter.
    ///   - languageOverride: The override this view model follows, so a language picked on the
    ///     Language page re-resolves every title it holds.
    ///   - deviceValues: Reads the fixed device and application facts. Defaults to
    ///     ``MenuDeviceValues/current()``, read once on first use; tests inject a stub. Optional
    ///     rather than defaulted to the function itself so that `MenuView`, which is not
    ///     main-actor isolated where it creates this, never has to name a main-actor function.
    init(
        defaults: UserDefaults = .scyther,
        assistants: [any MenuSearchAssistant] = MenuSearchAssistants.available(),
        assistedSearchDelay: Duration = .milliseconds(300),
        networkRuleStore: NetworkRuleStore = .shared,
        conditioningStore: NetworkConditioningStore = .shared,
        breakpointStore: BreakpointStore = .shared,
        languageOverride: LanguageOverride = .shared,
        deviceValues: (() -> [MenuItem: String])? = nil
    ) {
        let developerOptions = Scyther.developerOptions
        let sections = MenuSection.allSections(developerOptions: developerOptions)
        let pinnedItemIDs = defaults.stringArray(forKey: Self.pinnedItemsKey) ?? []

        self.defaults = defaults
        self.developerOptions = developerOptions
        self.sections = sections
        self.pinnedItemIDs = pinnedItemIDs
        self.pinnedItems = Self.resolvePinnedItems(from: pinnedItemIDs, in: sections)
        self.assistants = assistants
        self.assistedSearchDelay = assistedSearchDelay
        self.networkRuleStore = networkRuleStore
        self.conditioningStore = conditioningStore
        self.breakpointStore = breakpointStore
        self.languageOverride = languageOverride
        self.deviceValuesProvider = deviceValues
        super.init()
    }

    /// Mirrors both networking stores so ``enabledOverrideCount`` and ``conditioningSummary``
    /// are live, and follows the language override so every title stays in the effective language.
    ///
    /// Subscribing rather than reading once on appearance: an override can be enabled from the
    /// overrides screen, from a swipe on its row, or from `Scyther.network.rules` while the menu
    /// is on screen, and the badge has to follow all three. The master switch is a fourth: it
    /// stops every override being applied without changing one of them, so it has to be joined
    /// here or the badge keeps reading a count for overrides that are standing down. No
    /// `receive(on:)` — the store and this view model are both main-actor isolated, so the values
    /// already arrive on the main thread.
    ///
    /// The language subscription is what makes holding ``sections`` safe. ``LanguageOverride``
    /// sends its change *after* installing the new bundle and locale, so rebuilding on receipt
    /// resolves in the language just picked rather than the one being left.
    override func setup() {
        super.setup()
        networkRuleStore.$rules
            .combineLatest(networkRuleStore.$transientRules, networkRuleStore.$isEnabled)
            .sink { [weak self] rules, transient, isEnabled in
                guard isEnabled else {
                    self?.enabledOverrideCount = 0
                    return
                }
                self?.enabledOverrideCount = (rules + transient).filter(\.isEnabled).count
            }
            .store(in: &cancellables)
        conditioningStore.$isEnabled
            .combineLatest(conditioningStore.$condition)
            .sink { [weak self] isEnabled, condition in
                self?.conditioningSummary = NetworkConditioningPreset.summary(isEnabled: isEnabled,
                                                                               condition: condition)
            }
            .store(in: &cancellables)
        breakpointStore.$breakpoints
            .combineLatest(breakpointStore.$isEnabled)
            .sink { [weak self] breakpoints, isEnabled in
                self?.enabledBreakpointCount = isEnabled ? breakpoints.filter(\.isEnabled).count : 0
            }
            .store(in: &cancellables)
        languageOverride.objectWillChange
            .sink { [weak self] _ in
                self?.refreshLocalizedContent()
            }
            .store(in: &cancellables)
    }

    /// Whether the given row is pinned.
    ///
    /// - Parameter item: The row to check.
    /// - Returns: `true` when the row appears in the "Pinned" section.
    func isPinned(_ item: MenuItem) -> Bool {
        pinnedItemIDs.contains(item.id)
    }

    /// Pins or unpins a row, persisting the change immediately.
    ///
    /// Pinning appends the row to the end of the pinned list, so the "Pinned" section reads
    /// oldest pin first. Unpinning leaves the order of the remaining rows untouched.
    ///
    /// - Parameter item: The row to pin or unpin.
    func togglePin(for item: MenuItem) {
        if let index = pinnedItemIDs.firstIndex(of: item.id) {
            pinnedItemIDs.remove(at: index)
        } else {
            pinnedItemIDs.append(item.id)
        }
        defaults.set(pinnedItemIDs, forKey: Self.pinnedItemsKey)
    }

    /// Re-reads ``pinnedItemIDs`` from ``defaults``.
    ///
    /// `MenuView` sits at the root of a `UINavigationController` (see `Scyther.hideMenu()`
    /// and `Scyther.showMenu()`), so its `@StateObject MenuViewModel` survives pushing into,
    /// and popping back from, other screens — including the UserDefaults browser. Without
    /// this, a "Reset all Scyther settings" or a hand-edit of `Scyther.Menu.PinnedItems`
    /// performed while the menu is off screen would go unnoticed: ``pinnedItemIDs`` would
    /// keep reflecting whatever was in memory when the view model was created, and the next
    /// ``togglePin(for:)`` would write that stale array straight back to disk, undoing the
    /// reset.
    private func reloadPinnedItemIDs() {
        pinnedItemIDs = defaults.stringArray(forKey: Self.pinnedItemsKey) ?? []
    }

    // MARK: - Row Values

    /// The fixed device and application facts, read once on first use — see ``MenuDeviceValues``.
    private lazy var deviceValues: [MenuItem: String] = deviceValuesProvider?() ?? MenuDeviceValues.current()

    /// Supplies ``deviceValues``, so a test can hand in a stub and count how often it is read.
    private let deviceValuesProvider: (() -> [MenuItem: String])?

    /// The static description shown trailing a value row, or `nil` for rows whose content is not a
    /// plain value.
    ///
    /// Device and application facts come from a snapshot taken once per menu: they cannot change
    /// while the process runs, and reading them is not free — the App ID Prefix is a keychain
    /// query that *writes* an item when it finds none, and the build date stats `Info.plist`.
    /// `MenuView` used to read them inside every row's body, so scrolling paid for them again and
    /// again.
    ///
    /// Push tokens are deliberately read live: the host app sets them, possibly after the menu is
    /// already open.
    ///
    /// - Parameter item: The row.
    /// - Returns: The row's trailing value, or `nil` for navigation, toggle and developer-option
    ///   rows, and for ``MenuItem/ipAddress`` which loads asynchronously.
    func valueDescription(for item: MenuItem) -> String? {
        switch item {
        case .apnsToken, .fcmToken:
            return tokenValue(for: item) ?? localized("Not set")
        default:
            return deviceValues[item]
        }
    }

    /// The push token behind ``MenuItem/apnsToken`` / ``MenuItem/fcmToken``, or `nil` when the
    /// host app hasn't set it yet.
    ///
    /// - Parameter item: The token row.
    /// - Returns: The token, or `nil` when it is unset or `item` is not a token row.
    func tokenValue(for item: MenuItem) -> String? {
        switch item {
        case .apnsToken: return Scyther.apnsToken
        case .fcmToken: return Scyther.fcmToken
        default: return nil
        }
    }

    // MARK: - Search

    /// The current global-search query, bound to `MenuView`'s search field.
    ///
    /// Every change restarts the assisted-search pipeline — see ``assistedResults``.
    @Published var searchText: String = "" {
        didSet { scheduleAssistedSearch() }
    }

    /// The search index, built on first use and dropped by ``refreshLocalizedContent()``.
    ///
    /// Every entry carries a resolved title and breadcrumb, so building it resolves well over a
    /// hundred strings. It used to be rebuilt on each keystroke, by both the synchronous results
    /// and the assisted pipeline.
    private var searchIndex: [MenuSearchEntry]?

    /// The search index, building it if this is the first ask since the copy last changed.
    private func indexedEntries() -> [MenuSearchEntry] {
        if let searchIndex { return searchIndex }
        let built = MenuSearchIndex.entries(developerOptions: developerOptions)
        searchIndex = built
        return built
    }

    /// The synchronous search results for ``searchText`` — exact and alias matches.
    ///
    /// Filters ``indexedEntries()``, which is built from the same developer-options snapshot
    /// ``sections`` is, so a host-supplied row is searchable exactly when it is visible. Empty
    /// while ``searchText`` is empty or whitespace, and in that case the index is not built at all.
    var searchResults: [MenuSearchEntry] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return MenuSearchIndex.entries(matching: searchText, in: indexedEntries())
    }

    /// Results contributed by the fuzzy tiers (``MenuSearchAssistant``), already
    /// deduplicated against ``searchResults`` and each other.
    ///
    /// Populated by a debounced task so the synchronous results never wait on
    /// inference: each edit of ``searchText`` cancels the previous task, clears
    /// these, and — after a short pause in typing — runs each assistant in order,
    /// appending its findings as they arrive. Responses for stale queries are
    /// discarded.
    @Published private(set) var assistedResults: [MenuSearchEntry] = []

    /// Everything search shows, in tier order: exact/alias matches first, then
    /// assisted matches as they arrive.
    var displayedSearchResults: [MenuSearchEntry] {
        searchResults + assistedResults
    }

    /// The fuzzy-search tiers, in pipeline order. Empty when none are available.
    private let assistants: [any MenuSearchAssistant]

    /// How long typing must pause before the assistants run.
    private let assistedSearchDelay: Duration

    /// The in-flight assisted search, if any.
    private var assistedSearchTask: Task<Void, Never>?

    /// Restarts the assisted-search pipeline for the current ``searchText``.
    private func scheduleAssistedSearch() {
        assistedSearchTask?.cancel()
        assistedResults = []

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !assistants.isEmpty else { return }

        let entries = indexedEntries()
        assistedSearchTask = Task { [weak self, assistants, assistedSearchDelay] in
            try? await Task.sleep(for: assistedSearchDelay)
            guard !Task.isCancelled else { return }

            for assistant in assistants {
                let matches = await assistant.matches(for: query, in: entries)
                guard let self, !Task.isCancelled else { return }
                // Drop responses that arrive after the query has moved on.
                guard self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                self.appendAssistedResults(matches)
            }
        }
    }

    /// Appends assistant matches, skipping anything an earlier tier already shows.
    private func appendAssistedResults(_ matches: [MenuSearchEntry]) {
        var shown = Set(displayedSearchResults.map(\.id))
        for match in matches where !shown.contains(match.id) {
            shown.insert(match.id)
            assistedResults.append(match)
        }
    }

    // MARK: - Network Properties

    /// The device's current IP address.
    ///
    /// This property is populated asynchronously during ``onFirstAppear()`` using
    /// ``NetworkHelper`` to fetch the device's IP address. While loading, this
    /// will be an empty string and ``isLoadingIPAddress`` will be `true`.
    @Published var ipAddress: String = ""

    /// Whether the IP address is currently being fetched.
    ///
    /// This property is `true` while the IP address is being loaded from ``NetworkHelper``.
    /// Use this to display a loading indicator in the UI.
    @Published var isLoadingIPAddress: Bool = true

    // MARK: - UI Debugging Properties

    /// Whether slow animations mode is enabled.
    ///
    /// This property is two-way synchronized with ``InterfaceToolkit/slowAnimationsEnabled``.
    /// When enabled, all animations in the app run at a slower speed to aid in debugging
    /// UI transitions and animations.
    ///
    /// Changes to this property automatically update the global toolkit setting.
    @Published var slowAnimationsEnabled: Bool = InterfaceToolkit.slowAnimationsEnabled {
        didSet {
            InterfaceToolkit.slowAnimationsEnabled = slowAnimationsEnabled
        }
    }

    /// Whether the layout guides overlay is visible.
    ///
    /// This property is two-way synchronized with ``Scyther/interface``'s
    /// ``Interface/layoutGuidesEnabled`` facade — the same pattern ``Interface/gridOverlayEnabled``
    /// uses, rather than ``showViewFrames``'s direct binding to a static on ``InterfaceToolkit``,
    /// because ``LayoutGuides`` is a settings singleton like ``GridOverlay``, not a bare
    /// `UserDefaults`-backed static.
    ///
    /// The explicit call to ``InterfaceToolkit/showLayoutGuides()`` is not strictly needed —
    /// ``LayoutGuides/enabled``'s own setter already pushes the change there — but it is kept
    /// here anyway so this binding does not rely on a side effect buried two layers down: if a
    /// future change to ``LayoutGuides`` ever dropped that push, the menu's own toggle would
    /// still work.
    @Published var layoutGuidesEnabled: Bool = Scyther.interface.layoutGuidesEnabled {
        didSet {
            Scyther.interface.layoutGuidesEnabled = layoutGuidesEnabled
            InterfaceToolkit.instance.showLayoutGuides()
        }
    }

    /// Whether the guides row can do anything, so ``MenuView`` can disable it when it cannot.
    ///
    /// The guides' half of the spec's "neither tool activates; the menu row reports it rather than
    /// appearing to work". The ruler answers that with an alert because it has a tap to intercept;
    /// a `Toggle` has none — by the time it calls back the flag has already moved — so the row says
    /// it instead by being disabled, which is the stock way a control states it cannot act. The
    /// setting itself is left alone: it is persisted, and a launch that has a key window should
    /// still find the guides as the developer left them.
    var canShowLayoutGuides: Bool {
        InterfaceToolkit.instance.canShowLayoutGuides
    }

    /// Whether there is a key window for the view hierarchy inspector to walk, so ``MenuView`` can
    /// disable the row when there is not.
    ///
    /// The spec's first edge case — "no key window: the menu row reports it rather than appearing
    /// to work" — answered the same way the layout guides row answers it, because a row that
    /// pushes a page saying there was nothing to inspect *is* a row that appeared to work. The
    /// page keeps its own report as well: the check that matters is the one taken at walk time,
    /// and a window can go between the menu being drawn and the row being tapped.
    var canShowViewHierarchy: Bool {
        UIApplication.scytherKeyWindow != nil
    }

    /// Dismisses the menu and puts the layout ruler on screen.
    ///
    /// Not a toggle, which is why it is a method rather than a `@Published` property: the ruler
    /// consumes every touch on the screen while it is active, so leaving it switched on behind an
    /// open menu would mean the developer dismissed the menu into an app that no longer responds
    /// to anything. Activation and dismissal are one gesture.
    ///
    /// Activated in `hideMenu`'s completion rather than before it, so the overlay starts taking
    /// touches only once the menu has actually gone — an overlay is brought to the front of the
    /// key window, and one activated mid-animation would sit over the dismissal it is interrupting.
    /// The hop through `Task { @MainActor in }` is because that completion is a plain,
    /// non-isolated closure, while ``LayoutRuler`` is main-actor state.
    ///
    /// With no key window there is nothing to draw over, and this reports that instead of
    /// dismissing the menu — ``showsLayoutRulerUnavailableAlert``. The spec's rule for the case is
    /// that the tool "does not activate; the menu row reports it rather than appearing to work",
    /// and the ruler is the worst possible place to fail silently: it would leave
    /// ``LayoutRuler/isActive`` set with no visible Done to clear it.
    func activateLayoutRuler() {
        guard InterfaceToolkit.instance.canShowLayoutRuler else {
            showsLayoutRulerUnavailableAlert = true
            return
        }

        Scyther.hideMenu {
            Task { @MainActor in
                LayoutRuler.instance.isActive = true
            }
        }
    }

    /// Whether to tell the developer the ruler has no window to draw over.
    ///
    /// Driven only by ``activateLayoutRuler()``; ``MenuView`` binds an alert to it.
    @Published var showsLayoutRulerUnavailableAlert: Bool = false

    /// Whether view frames are shown.
    ///
    /// This property is two-way synchronized with ``InterfaceToolkit/showViewFrames``.
    /// When enabled, visual overlays are drawn around all view frames to help with
    /// layout debugging.
    ///
    /// Changes to this property automatically update the global toolkit setting.
    @Published var showViewFrames: Bool = InterfaceToolkit.showViewFrames {
        didSet {
            InterfaceToolkit.showViewFrames = showViewFrames
        }
    }

    /// Whether view sizes are shown.
    ///
    /// This property is two-way synchronized with ``InterfaceToolkit/showViewSizes``.
    /// When enabled, view dimensions are displayed as overlays on each view to help
    /// with layout debugging.
    ///
    /// Changes to this property automatically update the global toolkit setting.
    @Published var showViewSizes: Bool = InterfaceToolkit.showViewSizes {
        didSet {
            InterfaceToolkit.showViewSizes = showViewSizes
        }
    }

    // MARK: - Lifecycle Methods

    /// Called the first time the menu view appears.
    ///
    /// This method initiates the asynchronous loading of the device's IP address.
    /// The loading state is tracked via ``isLoadingIPAddress`` and the result is
    /// stored in ``ipAddress``.
    ///
    /// - Important: Always call `await super.onFirstAppear()` to ensure proper lifecycle tracking.
    override func onFirstAppear() async {
        await super.onFirstAppear()

        await loadIPAddress()
    }

    /// Called every time the menu reappears after the first time.
    ///
    /// Reloads ``pinnedItemIDs`` from ``defaults`` — see ``reloadPinnedItemIDs()`` — so pins
    /// changed while the menu was off screen (a reset of the Scyther store, or a hand-edit of
    /// `Scyther.Menu.PinnedItems` in the UserDefaults browser) are reflected immediately on
    /// return. Also re-resolves the localised copy this view model holds — see
    /// ``refreshLocalizedContent()`` — which is how a pseudo-localisation mode switched on its own
    /// page, pushed from this one, reaches the section headers. Deliberately does not re-run
    /// ``loadIPAddress()``, which stays confined to ``onFirstAppear()``.
    ///
    /// - Important: Always call `await super.onSubsequentAppear()` to ensure proper lifecycle
    ///   tracking.
    override func onSubsequentAppear() async {
        await super.onSubsequentAppear()

        reloadPinnedItemIDs()
        refreshLocalizedContent()
    }

    // MARK: - Private Methods

    /// Loads the device's IP address from ``NetworkHelper``.
    ///
    /// This method fetches the IP address asynchronously and updates ``ipAddress``
    /// and ``isLoadingIPAddress`` accordingly. The loading state is automatically
    /// set to `false` when the operation completes, regardless of success or failure.
    private func loadIPAddress() async {
        defer { isLoadingIPAddress = false }
        isLoadingIPAddress = true
        ipAddress = await NetworkHelper.instance.ipAddress
    }
}
