//
//  MenuView.swift
//  Scyther
//
//  Created by Brandon Stillitano on 16/6/2025.
//

import Combine
import SwiftUI

/// The main menu interface for the Scyther developer toolkit.
///
/// `MenuView` provides a comprehensive dashboard for accessing all Scyther features,
/// organized into logical sections:
/// - **Device**: Hardware and OS information
/// - **Application**: App metadata and build details
/// - **Development Tools**: Custom developer options configured via ``Scyther/developerOptions``
/// - **Networking**: Network tools, logs, and configuration
/// - **Data**: Feature flags, UserDefaults, cookies
/// - **Security**: Keychain browser
/// - **System Tools**: Location spoofer, console logs
/// - **Notifications**: Notification logger and tester
/// - **UI/UX**: Fonts, components, grid overlay, layout guides, layout ruler, touch visualizer
///
/// The menu displays device information in a header and provides navigation
/// to all sub-features.
///
/// Any row can be pinned via a trailing swipe action. Pinned rows appear in a "Pinned"
/// section rendered directly beneath **Device**, and also remain in their home section, so
/// the menu's structure never changes shape as rows are pinned. Pins are ordered oldest
/// first and persist across launches in `UserDefaults.scyther`.
///
/// A search field (iOS-Settings style) filters a global index covering every menu row
/// and the static rows inside settings sub-pages; each result shows its navigation
/// path, and sub-page results push the page containing the matched row.
public struct MenuView: View {
    @StateObject private var viewModel: MenuViewModel = MenuViewModel()

    /// The live language override, so the whole menu re-renders the moment a language is picked
    /// on the Language page rather than waiting for the next launch.
    @ObservedObject private var languageOverride = LanguageOverride.shared

    public init() {}

    /// Whether the menu is showing search results instead of its sections.
    ///
    /// Driven by the query text rather than `@Environment(\.isSearching)`: focusing
    /// the empty search field keeps the browsable menu visible, matching Settings.
    private var isSearchActive: Bool {
        !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        List {
            if isSearchActive {
                searchResultsSection
            } else {
                menuSections
            }
        }
        .searchable(text: $viewModel.searchText, prompt: localized("Search"))
        // An alert rather than anything quieter: the row it answers for did nothing visible, and a
        // tool that silently declines to start is indistinguishable from one that is broken. Bound
        // here rather than on either row so both the browsing row and the search result — which
        // call the same method — are covered by one.
        .alert(localized("No Window to Measure"), isPresented: $viewModel.showsLayoutRulerUnavailableAlert) {
            Button(localized("OK"), role: .cancel) {}
        } message: {
            Text(localized("The layout ruler draws over the app's key window, and this app has none right now."))
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Scyther.hideMenu()
                } label: {
                    Image(systemName: "xmark")
                }
            }
        }
        .onFirstAppear {
            await viewModel.onFirstAppear()
        }
        .onSubsequentAppear {
            await viewModel.onSubsequentAppear()
        }
        .navigationTitle("Scyther") // scyther:unlocalised product name
        .interactiveDismissDisabled()
        .environment(\.locale, languageOverride.namingLocale)
        .transformEnvironment(\.layoutDirection) { direction in
            // Transformed rather than set, so that with no language override the menu inherits the
            // process's own direction — which is what pseudo-localisation's Right to Left mode
            // changes at launch. Setting it unconditionally mirrored the host app and left the
            // menu unmirrored. See `LanguageOverride.menuLayoutDirection`.
            if let overridden = languageOverride.menuLayoutDirection { direction = overridden }
        }
    }

    /// The normal browsing content: device header, Pinned, and every menu section.
    /// This is the exact content the `List` held before search was added.
    @ViewBuilder
    private var menuSections: some View {
        if let deviceSection = viewModel.sections.first {
            Section {
                header
                ForEach(deviceSection.items) { item in
                    pinnableRow(for: item)
                }
            } header: {
                Text(deviceSection.title)
            }
        }

        if !viewModel.pinnedItems.isEmpty {
            // Identified by ``MenuSectionID/pinned`` rather than by its header text, which is
            // localised: a language switch must not read as a different section to SwiftUI.
            Section {
                ForEach(viewModel.pinnedItems, id: \.pinnedRowID) { item in
                    pinnableRow(for: item)
                }
            } header: {
                Text(localized("Pinned"))
            }
            .id(MenuSectionID.pinned)
        }

        ForEach(Array(viewModel.sections.dropFirst())) { section in
            Section {
                ForEach(section.items) { item in
                    pinnableRow(for: item)
                }
            } header: {
                Text(section.title)
            }
        }
    }

    /// The search results, or a "no results" placeholder.
    ///
    /// Result rows are deliberately not pinnable — pinning stays a browsing gesture,
    /// matching the iOS Settings app.
    @ViewBuilder
    private var searchResultsSection: some View {
        let results = viewModel.displayedSearchResults
        if results.isEmpty {
            noResults
        } else {
            Section {
                ForEach(results) { entry in
                    searchResultRow(for: entry)
                }
            }
        }
    }

    /// A single search result, laid out like an iOS Settings search row.
    ///
    /// Every result shares one anatomy — an icon tile vertically centred beside a
    /// two-line title/breadcrumb stack (see ``searchResultLabel(title:icon:breadcrumbText:)``)
    /// — and differs only in its accessory: navigation results (sub-page entries and
    /// main-page navigation rows) are a `NavigationLink` whose label contains the whole
    /// stack, so the entire row including the breadcrumb is tappable; toggle results
    /// carry their live binding; value results show their value trailing.
    @ViewBuilder
    private func searchResultRow(for entry: MenuSearchEntry) -> some View {
        if entry.isSubpageEntry {
            navigationResult(for: entry)
        } else {
            switch entry.target {
            case .slowAnimations:
                Toggle(isOn: $viewModel.slowAnimationsEnabled) { searchResultLabel(for: entry) }
            case .showViewFrames:
                Toggle(isOn: $viewModel.showViewFrames) { searchResultLabel(for: entry) }
            case .showViewSizes:
                Toggle(isOn: $viewModel.showViewSizes) { searchResultLabel(for: entry) }
            case .layoutGuides:
                Toggle(isOn: $viewModel.layoutGuidesEnabled) { searchResultLabel(for: entry) }
                    .disabled(!viewModel.canShowLayoutGuides)
            case .viewHierarchy:
                // A case of its own only so the search hit carries the same gate its row does; a
                // result that pushed a page saying there was nothing to inspect would be the row
                // appearing to work by another route.
                navigationResult(for: entry)
                    .disabled(!viewModel.canShowViewHierarchy)
            case .layoutRuler:
                // An action, not a destination: without a case of its own this would fall
                // through to `navigationResult(for:)`, whose `destination(for:)` has nothing to
                // push for a row that is not a page — a search hit that opened a blank screen with
                // only a back button, which is exactly the defect Layout Guides shipped with.
                Button {
                    viewModel.activateLayoutRuler()
                } label: {
                    searchResultLabel(for: entry)
                }
                .buttonStyle(.plain)
            case .ipAddress:
                HStack {
                    searchResultLabel(for: entry)
                    if viewModel.isLoadingIPAddress {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        resultValue(viewModel.ipAddress)
                    }
                }
            case .developerOption(let name):
                if let option = viewModel.developerOption(named: name) {
                    developerOptionResult(option, entry: entry)
                }
            default:
                if let value = valueDescription(for: entry.target) {
                    HStack {
                        searchResultLabel(for: entry)
                        resultValue(value)
                    }
                } else {
                    navigationResult(for: entry)
                }
            }
        }
    }

    /// A result that pushes ``destination(for:)`` — the containing page for a
    /// sub-page entry, the row's own destination for a main-page navigation row.
    private func navigationResult(for entry: MenuSearchEntry) -> some View {
        NavigationLink {
            destination(for: entry.target)
        } label: {
            searchResultLabel(for: entry)
        }
    }

    /// A search result for a host-supplied developer option.
    ///
    /// Mirrors ``developerOptionRow(_:)`` — value options show their value, view
    /// options navigate — but wears the shared search-result anatomy.
    @ViewBuilder
    private func developerOptionResult(_ option: DeveloperOption, entry: MenuSearchEntry) -> some View {
        let label = searchResultLabel(
            title: option.name,
            icon: option.systemImage,
            tint: entry.target.tint,
            breadcrumbText: entry.breadcrumbText
        )
        switch option.type {
        case .value:
            HStack {
                label
                if let value = option.value {
                    resultValue(value)
                }
            }
        case .viewController:
            if let viewController = option.viewController {
                NavigationLink {
                    ViewControllerRepresentable(viewController: viewController)
                } label: {
                    label
                }
            }
        case .swiftUIView:
            if let swiftUIView = option.swiftUIView {
                NavigationLink {
                    swiftUIView
                } label: {
                    label
                }
            }
        }
    }

    private func searchResultLabel(for entry: MenuSearchEntry) -> some View {
        searchResultLabel(
            title: entry.title,
            icon: entry.icon,
            tint: entry.target.tint,
            breadcrumbText: entry.breadcrumbText
        )
    }

    /// The shared anatomy of every search result: an iOS-Settings-style icon tile
    /// vertically centred beside the title, with the navigation path beneath the
    /// title (never beneath the tile).
    private func searchResultLabel(title: String, icon: String?, tint: Color, breadcrumbText: String) -> some View {
        HStack(spacing: 12) {
            if let icon {
                iconTile(icon, tint: tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(breadcrumbText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// The rounded-square icon tile shown beside every row, matching the icon tiles
    /// in the iOS Settings app. Tinted with the row's home section colour.
    private func iconTile(_ systemImage: String, tint: Color) -> some View {
        iconTile(tint: tint) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
        }
    }

    /// ``iconTile(_:tint:)`` for a host-supplied `UIImage` icon.
    private func iconTile(uiImage: UIImage, tint: Color) -> some View {
        iconTile(tint: tint) {
            Image(uiImage: uiImage)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .padding(6)
        }
    }

    private func iconTile(tint: Color, @ViewBuilder glyph: () -> some View) -> some View {
        glyph()
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(tint)
            )
    }

    /// A result's trailing value, styled like a value row's description.
    private func resultValue(_ value: String) -> some View {
        Text(value)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Shown when the query matches nothing.
    @ViewBuilder
    private var noResults: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView.search(text: viewModel.searchText)
        } else {
            Text(localized("No results for \"\(viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines))\""))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Wraps a row in its pin/unpin swipe action.
    ///
    /// The action's label is derived from the row's current pin state rather than from which
    /// section it is being rendered in, because pinned rows remain in their home section — a
    /// pinned row therefore reads "Unpin" in both places.
    @ViewBuilder
    private func pinnableRow(for item: MenuItem) -> some View {
        rowContent(for: item)
            .swipeActions(edge: .trailing) {
                Button {
                    viewModel.togglePin(for: item)
                } label: {
                    Label(
                        viewModel.isPinned(item) ? localized("Unpin") : localized("Pin"),
                        systemImage: viewModel.isPinned(item) ? "pin.slash" : "pin"
                    )
                }
                .tint(.blue)
            }
    }

    /// Builds a row that pushes a destination view.
    ///
    /// The label is derived entirely from the item, so every navigation row in the
    /// menu is laid out identically and only the destination varies.
    private func navigationRow(for item: MenuItem, description: String? = nil) -> some View {
        NavigationLink {
            destination(for: item)
        } label: {
            row(withLabel: item.title, description: description, icon: item.icon, tint: item.tint)
        }
    }

    /// The single item→destination mapping, shared by ``navigationRow(for:)`` and
    /// search results (a sub-page result pushes the page containing the matched row).
    ///
    /// Items that are not navigation rows (value rows, toggles, tokens, developer
    /// options) return an `EmptyView`; no search entry targets them for navigation.
    @ViewBuilder
    private func destination(for item: MenuItem) -> some View {
        switch item {
        case .networkLogs: NetworkLogsView()
        case .networkConditioning: NetworkConditioningView()
        case .networkRules: NetworkRulesView()
        case .networkBreakpoints: BreakpointsView()
        case .serverConfiguration: ServerConfigurationView()
        case .environmentVariables: EnvironmentVariablesView()
        case .featureFlags: FeatureFlagsView()
        case .userDefaults: UserDefaultsView()
        case .cookies: CookieBrowserView()
        case .fileBrowser: FileBrowserView()
        case .databaseBrowser: DatabaseBrowserView()
        case .keychainBrowser: KeychainBrowserView()
        case .locationSpoofer: LocationSpooferView()
        case .consoleLogs: ConsoleLoggerView()
        case .deepLinkTester: DeepLinkTesterView()
        case .crashLogs: CrashLogsView()
        case .notificationLogger: NotificationLoggerView()
        case .notificationTester: NotificationTesterView()
        case .fonts: FontsView()
        case .interfaceComponents: InterfacePreviewsView()
        case .gridOverlay: GridOverlaySettingsView()
        case .fpsCounter: FPSCounterSettingsView()
        case .viewHierarchy: ViewHierarchyView()
        case .touchVisualiser: TouchVisualiserView()
        case .accessibilityAudit: AccessibilityAuditView()
        case .appearance: AppearanceOverridesView()
        case .language: LanguageView(viewModel: LanguageViewModel())
        case .pseudoLocalization: PseudoLocalizationView()
        default: EmptyView()
        }
    }

    /// The static description shown trailing a value row, or `nil` for rows whose
    /// content is not a plain value (navigation, toggle, token, and developer-option
    /// rows, plus ``MenuItem/ipAddress`` which loads asynchronously).
    ///
    /// Single source for ``rowContent(for:)`` and ``searchResultRow(for:)``, so a
    /// value can never differ between the menu and its search result.
    ///
    /// The values themselves come from ``MenuViewModel/valueDescription(for:)``, which reads the
    /// fixed device and application facts once per menu rather than inside every row's body — one
    /// of them is a keychain query that writes an item when it finds none.
    private func valueDescription(for item: MenuItem) -> String? {
        viewModel.valueDescription(for: item)
    }

    /// The push token behind ``MenuItem/apnsToken`` / ``MenuItem/fcmToken``, or `nil` when the
    /// host app hasn't set it yet.
    private func tokenValue(for item: MenuItem) -> String? {
        viewModel.tokenValue(for: item)
    }

    /// A push-token row. The row truncates the token, so long-press copies it in full.
    @ViewBuilder
    private func tokenRow(for item: MenuItem) -> some View {
        row(
            withLabel: item.title,
            description: valueDescription(for: item),
            icon: item.icon,
            tint: item.tint
        )
        .contextMenu {
            if let token = tokenValue(for: item) {
                Button {
                    UIPasteboard.general.string = token
                } label: {
                    Label(localized("Copy"), systemImage: "doc.on.doc")
                }
            }
        }
    }

    /// The single definition of every menu row.
    ///
    /// ``MenuItem`` supplies each row's title and icon; this method supplies everything
    /// dynamic — a value row's description, a navigation row's destination, a toggle row's
    /// binding. Because there is one definition, the "Pinned" section and a row's home
    /// section always render identically.
    @ViewBuilder
    private func rowContent(for item: MenuItem) -> some View {
        switch item {
        // MARK: Device & Application
        case .osVersion, .hardware, .releaseYear, .uuid,
             .appIdPrefix, .displayName, .bundleId, .processId,
             .version, .buildNumber, .buildDate, .releaseType:
            row(
                withLabel: item.title,
                description: valueDescription(for: item),
                icon: item.icon,
                tint: item.tint
            )

        // MARK: Development Tools
        case .developerOption(let name):
            // Resolved from `viewModel`'s snapshot of `Scyther.developerOptions`, the same
            // snapshot `sections` was built from, rather than re-reading the global directly.
            // A host app can mutate `Scyther.developerOptions` while this menu is on screen;
            // reading the same snapshot here guarantees this lookup always succeeds for a name
            // that `sections` listed, so a row is never left blank while `pinnableRow` has
            // already attached a live swipe action to it.
            if let option = viewModel.developerOption(named: name) {
                developerOptionRow(option)
            }

        // MARK: Networking
        case .ipAddress:
            row(
                withLabel: item.title,
                description: viewModel.ipAddress,
                icon: item.icon,
                tint: item.tint,
                andLoadingState: viewModel.isLoadingIPAddress
            )
        case .networkLogs:
            navigationRow(for: item)
        case .networkConditioning:
            // The active preset, or Off. Conditioning the whole app is a large hammer, and a
            // developer who has forgotten it is on will spend an afternoon blaming their backend;
            // the row says so before the screen has to be opened.
            navigationRow(for: item, description: viewModel.conditioningSummary)
        case .networkRules:
            // The count of enabled overrides, so overrides are never silently on. Carried as the
            // row's trailing detail text rather than through `.badge(_:)`, which on a
            // `NavigationLink` renders *after* the disclosure chevron and reads as "> 1". Passing
            // it as a description keeps the count inside the link's own label, so it sits before
            // the chevron the way a trailing value does everywhere else in this menu — and it is
            // the same `row(withLabel:description:...)` builder every other detail row uses.
            // Nil below one, since a nought would read as a count that means nothing.
            navigationRow(for: item,
                          description: viewModel.enabledOverrideCount > 0
                          ? "\(viewModel.enabledOverrideCount)"
                          : nil)
        case .networkBreakpoints:
            // The count of breakpoints being applied, for the reason the override count is shown:
            // this is the one feature that stops the app, and a developer must be able to see from
            // the menu's first screen that something is about to. Nil below one, since a nought
            // would read as a count that means nothing.
            navigationRow(for: item,
                          description: viewModel.enabledBreakpointCount > 0
                          ? "\(viewModel.enabledBreakpointCount)"
                          : nil)
        case .serverConfiguration:
            navigationRow(for: item)
        case .environmentVariables:
            navigationRow(for: item)

        // MARK: Data
        case .featureFlags:
            navigationRow(for: item)
        case .userDefaults:
            navigationRow(for: item)
        case .cookies:
            navigationRow(for: item)
        case .fileBrowser:
            navigationRow(for: item)
        case .databaseBrowser:
            navigationRow(for: item)

        // MARK: Security
        case .keychainBrowser:
            navigationRow(for: item)

        // MARK: System Tools
        case .locationSpoofer:
            navigationRow(for: item)
        case .consoleLogs:
            navigationRow(for: item)
        case .deepLinkTester:
            navigationRow(for: item)
        case .crashLogs:
            navigationRow(for: item)

        // MARK: Notifications
        case .notificationLogger:
            navigationRow(for: item)
        case .notificationTester:
            navigationRow(for: item)
        case .apnsToken, .fcmToken:
            tokenRow(for: item)

        // MARK: UI/UX
        case .fonts:
            navigationRow(for: item)
        case .interfaceComponents:
            navigationRow(for: item)
        case .gridOverlay:
            navigationRow(for: item)
        case .layoutGuides:
            // Disabled with no key window to draw over, mirroring the ruler's alert — see
            // ``MenuViewModel/canShowLayoutGuides`` for why the two tools report the same
            // condition in two different shapes.
            toggleRow(item.title, icon: item.icon, tint: item.tint, isOn: $viewModel.layoutGuidesEnabled)
                .disabled(!viewModel.canShowLayoutGuides)
        case .layoutRuler:
            actionRow(for: item) { viewModel.activateLayoutRuler() }
        case .viewHierarchy:
            // Disabled with no key window to walk, the same shape the layout guides row uses for
            // the same condition — see ``MenuViewModel/canShowViewHierarchy``.
            navigationRow(for: item)
                .disabled(!viewModel.canShowViewHierarchy)
        case .fpsCounter:
            navigationRow(for: item)
        case .touchVisualiser:
            navigationRow(for: item)
        case .accessibilityAudit:
            navigationRow(for: item)
        case .appearance:
            navigationRow(for: item)
        case .language:
            navigationRow(for: item)
        case .pseudoLocalization:
            navigationRow(for: item)
        case .slowAnimations:
            toggleRow(item.title, icon: item.icon, tint: item.tint, isOn: $viewModel.slowAnimationsEnabled)
        case .showViewFrames:
            toggleRow(item.title, icon: item.icon, tint: item.tint, isOn: $viewModel.showViewFrames)
        case .showViewSizes:
            toggleRow(item.title, icon: item.icon, tint: item.tint, isOn: $viewModel.showViewSizes)
        }
    }

    /// A row that performs something immediately rather than navigating or toggling.
    ///
    /// The layout ruler is the menu's only one: it has no page to push and no setting to show,
    /// because activating it means dismissing the menu and handing the screen to an overlay. The
    /// row still wears the shared anatomy — icon tile, title — so it reads as part of the list
    /// rather than as a stray control, and `.buttonStyle(.plain)` is what keeps it doing so: a
    /// `Button` in a `List` otherwise tints its entire label, icon tile included, with the accent
    /// colour.
    ///
    /// - Parameters:
    ///   - item: The row, supplying its title, icon and section tint.
    ///   - action: What tapping it does.
    /// - Returns: The row.
    func actionRow(for item: MenuItem, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            row(withLabel: item.title, icon: item.icon, tint: item.tint)
        }
        .buttonStyle(.plain)
    }

    func row(withLabel label: String, description: String? = nil, icon: String? = nil, tint: Color = .accentColor, andLoadingState loading: Bool = false) -> some View {
        HStack {
            Group {
                if let icon {
                    HStack(spacing: 12) {
                        iconTile(icon, tint: tint)
                        Text(label)
                    }
                } else {
                    Text(label)
                }
            }
            // The trailing value below is greedy (`maxWidth: .infinity`) so a long one truncates in
            // its own middle rather than pushing the row wider. Without a priority here the title
            // and the value split the row evenly, so a short value like a count still took half the
            // width and wrapped a two-word title onto a second line. The title gets its ideal width
            // first; the value keeps whatever is left, and still truncates when that is not enough.
            .layoutPriority(1)
            if loading {
                ProgressView()
            } else if let description {
                Text(description)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Builds a toggle row bound to a Boolean setting.
    ///
    /// - Parameters:
    ///   - label: The row's title.
    ///   - icon: An optional SF Symbol shown as a tile beside the label. Rows without an
    ///     icon (there are currently none among toggle rows, but ``MenuItem/icon`` is
    ///     optional) render as plain text.
    ///   - tint: The tile's colour — the row's home section colour.
    ///   - isOn: The binding the toggle reads from and writes to.
    func toggleRow(_ label: String, icon: String?, tint: Color = .accentColor, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            if let icon {
                HStack(spacing: 12) {
                    iconTile(icon, tint: tint)
                    Text(label)
                }
            } else {
                Text(label)
            }
        }
    }

    @ViewBuilder
    func developerOptionRow(_ option: DeveloperOption) -> some View {
        switch option.type {
        case .value:
            HStack {
                developerOptionLabel(option)
                if let value = option.value {
                    Text(value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        case .viewController:
            if let viewController = option.viewController {
                NavigationLink {
                    ViewControllerRepresentable(viewController: viewController)
                } label: {
                    developerOptionLabel(option)
                }
            }
        case .swiftUIView:
            if let swiftUIView = option.swiftUIView {
                NavigationLink {
                    swiftUIView
                } label: {
                    developerOptionLabel(option)
                }
            }
        }
    }

    @ViewBuilder
    func developerOptionLabel(_ option: DeveloperOption) -> some View {
        let tint = MenuItem.developerOption(name: option.name).tint
        if let systemImage = option.systemImage {
            HStack(spacing: 12) {
                iconTile(systemImage, tint: tint)
                Text(option.name)
            }
        } else if let icon = option.icon {
            HStack(spacing: 12) {
                iconTile(uiImage: icon, tint: tint)
                Text(option.name)
            }
        } else {
            Text(option.name)
        }
    }

    var header: some View {
        HStack(spacing: 16) {
            if let image = UIImage.appIcon {
                Image(uiImage: image)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray, lineWidth: 1)
                    )
            }
            VStack(alignment: .leading) {
                Text(UIDevice.current.name)
                Text(UIDevice.current.model)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A SwiftUI wrapper for displaying UIKit view controllers.
///
/// Used internally to present custom ``DeveloperOption`` view controllers
/// within the SwiftUI navigation hierarchy.
struct ViewControllerRepresentable: UIViewControllerRepresentable {
    let viewController: UIViewController

    func makeUIViewController(context: Context) -> UIViewController {
        return viewController
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
    }
}
