//
//  MenuSearchIndex.swift
//  Scyther
//
//  Created by Brandon Stillitano on 3/8/2026.
//

import Foundation

/// The global search index for the Scyther main menu.
///
/// The index has two parts:
/// - **Main-menu entries** are derived from ``MenuSection/allSections(developerOptions:)``
///   — one entry per row, carrying its section title as the breadcrumb. Because they are
///   derived, they can never drift from the real menu layout.
/// - **Sub-page entries** are a hand-curated list of the static rows inside settings
///   pages (see `subpageTitles`). Dynamic content — network log entries, UserDefaults
///   keys, files, fonts, host-supplied server configurations — is deliberately not
///   indexed, matching how the iOS Settings app treats app content.
///
/// ## Topics
///
/// ### Building the index
/// - ``entries(developerOptions:)``
///
/// ### Searching
/// - ``entries(matching:developerOptions:)``
enum MenuSearchIndex {
    /// Every searchable entry: one per main-menu row, followed by the curated
    /// sub-page entries.
    ///
    /// - Parameter developerOptions: The host app's custom options, so the
    ///   "Development Tools" rows are searchable exactly when they are visible.
    /// - Returns: All entries, in menu order.
    static func entries(developerOptions: [DeveloperOption]) -> [MenuSearchEntry] {
        let sections = MenuSection.allSections(developerOptions: developerOptions)
        let mainPageEntries = sections.flatMap { section in
            section.items.map { item in
                MenuSearchEntry(
                    title: item.title,
                    breadcrumb: [section.title],
                    icon: item.icon,
                    target: item,
                    isSubpageEntry: false,
                    keywords: keywords[item] ?? []
                )
            }
        }
        return mainPageEntries + subpageEntries(in: sections)
    }

    /// The entries matching a search query.
    ///
    /// Matching uses `localizedStandardContains` — case-insensitive,
    /// diacritic-insensitive, locale-aware — against the entry's title, each
    /// breadcrumb component, and each alias keyword, so searching "grid" surfaces
    /// every row under Grid Overlay and searching "remote config" surfaces Feature
    /// Flags. Keywords match in both directions: a query containing a keyword
    /// ("environment env var") and a keyword containing the query ("env va") both hit.
    ///
    /// - Parameters:
    ///   - query: The user's search text. Leading and trailing whitespace is
    ///     ignored; an effectively empty query matches nothing.
    ///   - developerOptions: The host app's custom options — see ``entries(developerOptions:)``.
    /// - Returns: Matching entries, in menu order.
    static func entries(
        matching query: String,
        developerOptions: [DeveloperOption]
    ) -> [MenuSearchEntry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return entries(matching: query, in: entries(developerOptions: developerOptions))
    }

    /// The entries of an already-built index that match a search query.
    ///
    /// The same matching as ``entries(matching:developerOptions:)``, over an index the caller
    /// built once. Building the index resolves the localised title of every row and every
    /// sub-page entry, so ``MenuViewModel`` keeps one and filters it on each keystroke instead
    /// of rebuilding it.
    ///
    /// - Parameters:
    ///   - query: The user's search text. Leading and trailing whitespace is ignored; an
    ///     effectively empty query matches nothing.
    ///   - index: Entries from ``entries(developerOptions:)``.
    /// - Returns: Matching entries, in index order.
    static func entries(matching query: String, in index: [MenuSearchEntry]) -> [MenuSearchEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return index.filter { entry in
            entry.title.localizedStandardContains(trimmed)
                || entry.breadcrumb.contains { $0.localizedStandardContains(trimmed) }
                || entry.keywords.contains {
                    $0.localizedStandardContains(trimmed) || trimmed.localizedStandardContains($0)
                }
        }
    }

    /// Alias terms per row — jargon a developer might type instead of the visible
    /// title. Hand-curated, matched case- and diacritic-insensitively.
    ///
    /// Deliberately left in English in every language: these are search aliases, never
    /// displayed, and the jargon a developer types ("remote config", "sqlite", "env var")
    /// is English regardless of the interface language.
    static let keywords: [MenuItem: [String]] = [
        .uuid: ["identifier", "idfv", "device id"],
        .bundleId: ["bundle identifier", "app id"],
        .version: ["build", "release"],
        .buildNumber: ["build"],
        .releaseType: ["configuration", "testflight", "app store", "debug"],
        .ipAddress: ["ip", "network address"],
        .networkLogs: ["http", "requests", "responses", "traffic", "api", "charles", "proxy"],
        .networkConditioning: [
            "conditioning", "link conditioner", "network link conditioner", "throttle", "throttling",
            "latency", "slow", "bandwidth", "offline", "flaky", "3g", "edge", "packet loss"
        ],
        .networkRules: [
            "mock", "stub", "map local", "throttle", "latency", "offline", "rewrite", "charles",
            "proxyman", "rules", "network rules", "override", "overrides", "request overrides"
        ],
        .networkBreakpoints: [
            "breakpoint", "breakpoints", "pause", "hold", "intercept", "edit request",
            "edit response", "charles", "proxyman", "debug request"
        ],
        .serverConfiguration: ["backend", "staging", "production", "base url", "endpoint"],
        .environmentVariables: ["env", "env var", "env vars", "environment"],
        .featureFlags: ["remote config", "experiments", "toggles", "flags", "ab test", "launch darkly"],
        .userDefaults: ["preferences", "prefs", "defaults", "nsuserdefaults", "plist"],
        .cookies: ["http cookies"],
        .fileBrowser: ["files", "documents", "sandbox", "caches"],
        .databaseBrowser: ["sqlite", "core data", "coredata", "swiftdata", "db"],
        .keychainBrowser: ["secure storage", "credentials", "passwords", "secrets"],
        .locationSpoofer: ["gps", "fake location", "mock location", "coordinates", "geo"],
        .consoleLogs: ["stdout", "stderr", "print", "logs", "logging"],
        .deepLinkTester: ["url scheme", "universal link", "deeplink", "deep link"],
        .crashLogs: ["crashes", "exceptions", "stack trace"],
        .notificationLogger: ["push", "apns", "payload"],
        .notificationTester: ["push", "apns", "local notification"],
        .apnsToken: ["push token", "device token"],
        .fcmToken: ["firebase", "push token"],
        .fonts: ["typography", "typefaces", "text styles"],
        .interfaceComponents: ["previews", "components", "design system"],
        .gridOverlay: ["alignment", "layout grid"],
        .layoutGuides: ["safe area", "layout margins", "insets"],
        .layoutRuler: ["ruler", "measure", "distance", "gap", "spacing", "points", "pt", "snap"],
        .viewHierarchy: ["views", "tree", "inspector", "subviews", "hierarchy", "frames"],
        .fpsCounter: ["frame rate", "performance", "hitches"],
        .touchVisualiser: ["touches", "taps", "gestures"],
        .accessibilityAudit: ["a11y", "voiceover", "contrast", "labels", "touch targets"],
        .appearance: ["dark mode", "light mode", "theme", "dynamic type", "contrast"],
        .language: ["locale", "translation", "localisation", "localization", "i18n", "l10n", "region"],
        .pseudoLocalization: [
            "pseudo", "pseudoloc", "pseudo localisation", "pseudo localization", "accented",
            "expansion", "rtl", "right to left", "bidi", "truncation", "i18n", "l10n",
            "translation", "localisation keys", "localization keys"
        ],
        .slowAnimations: ["animation speed"],
        .showViewFrames: ["debug view", "borders", "layout"],
        .showViewSizes: ["dimensions", "layout"]
    ]

    /// The static rows inside settings sub-pages, keyed by the page's menu item.
    ///
    /// Hand-curated: when a settings page gains or loses a static row, update its
    /// titles here. Titles should match the visible row labels closely enough that
    /// searching what the user can read finds the page.
    ///
    /// Computed rather than stored so the labels are resolved in the language that is
    /// effective *now*: a stored property would cache whatever language was active the first
    /// time search ran, and results would stay in that language after the user switched.
    private static var subpageTitles: [(target: MenuItem, titles: [String])] {[
        (.networkRules, [localized("New Override"), localized("Import from HAR")]),
        (.networkBreakpoints, [localized("Enable Breakpoints"), localized("New Breakpoint")]),
        (.networkConditioning, [localized("Enable Network Conditioning"), localized("Preset")]),
        (.gridOverlay, [localized("Enable Grid"), localized("Grid Size"), localized("Grid Opacity"), localized("Grid Color")]),
        (.fpsCounter, [localized("Enable FPS Counter"), localized("FPS Counter Position")]),
        (.touchVisualiser, [
            localized("Show Screen Touches"), localized("Log Screen Touches"),
            localized("Show Touch Duration"), localized("Show Touch Radius")
        ]),
        (.accessibilityAudit, [
            localized("Show Issues On Screen"), localized("Missing Labels"),
            localized("Touch Targets"), localized("Contrast")
        ]),
        (.appearance, [
            localized("Color Scheme"), localized("Dynamic Type"), localized("Override Text Size"),
            localized("Increase Contrast"), localized("Reset to System Defaults")
        ]),
        (.locationSpoofer, [
            localized("Enable Location Spoofing"), localized("Location Presets"), localized("Custom Location")
        ]),
        (.notificationTester, [
            localized("Request Notification Permission"), localized("Send Push Notification"),
            localized("Badge Count"), localized("Cancel Scheduled Notifications"), localized("Clear Badge & Notifications")
        ]),
        (.deepLinkTester, [localized("Open URL"), localized("Deep Link Presets"), localized("Deep Link History")]),
        (.language, [localized("System Default"), localized("Reset Language Override")]),
        (.pseudoLocalization, [
            localizedChrome("Accented"), localizedChrome("Lengthened"),
            localizedChrome("Right to Left"), localizedChrome("Show Keys"),
            localizedChrome("Turn Everything Off")
        ])
    ]}

    /// Builds the sub-page entries, resolving each target's home section from the
    /// live layout so breadcrumbs can never drift from the real menu.
    private static func subpageEntries(in sections: [MenuSection]) -> [MenuSearchEntry] {
        subpageTitles.flatMap { target, titles -> [MenuSearchEntry] in
            guard let home = sections.first(where: { $0.items.contains(target) }) else {
                return []
            }
            return titles.map { title in
                MenuSearchEntry(
                    title: title,
                    breadcrumb: [home.title, target.title],
                    icon: target.icon,
                    target: target,
                    isSubpageEntry: true
                )
            }
        }
    }
}
