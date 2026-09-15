//
//  MenuSection.swift
//  Scyther
//
//  Created by Brandon Stillitano on 22/7/2026.
//

import Foundation

/// A titled group of rows in the Scyther main menu.
///
/// Describing the menu as data rather than as literal SwiftUI sections is what lets
/// ``MenuView`` render the same ``MenuItem`` in both its home section and the "Pinned"
/// section from a single row definition.
///
/// Identity and display copy are deliberately separate: ``id`` is a stable, language
/// independent token used for tinting and for SwiftUI's `ForEach` identity, while ``title``
/// is localised copy that changes with the user's language.
///
/// ## Usage
///
/// ```swift
/// for section in MenuSection.allSections(developerOptions: Scyther.developerOptions) {
///     print(section.id, section.title, section.items.count)
/// }
/// ```
///
/// ## Topics
///
/// ### Properties
/// - ``id``
/// - ``title``
/// - ``items``
///
/// ### Layout
/// - ``allSections(developerOptions:)``
/// - ``builtInLayout``
/// - ``homeSectionIDs``
/// - ``title(forID:)``
/// - ``MenuSectionID``
struct MenuSection: Identifiable, Equatable {
    /// Stable, language independent identifier — see ``MenuSectionID``.
    ///
    /// Never derived from ``title``: the title is localised, so keying anything on it would
    /// break the moment the user switched language.
    let id: String

    /// The section header text, already localised.
    let title: String

    /// The rows in this section, in display order.
    let items: [MenuItem]

    /// The built-in sections, in display order, as identifiers and rows with no copy attached.
    ///
    /// The single statement of which row lives in which section. ``allSections(developerOptions:)``
    /// titles it for display, and ``homeSectionIDs`` indexes it so ``MenuItem/tint`` can find a
    /// row's section without resolving a single string.
    ///
    /// "Development Tools" is absent because its rows come from the host app at runtime;
    /// ``allSections(developerOptions:)`` inserts it after "Application" when there are any.
    static let builtInLayout: [(id: String, items: [MenuItem])] = [
        (MenuSectionID.device, [
            .osVersion, .hardware, .releaseYear, .uuid
        ]),
        (MenuSectionID.application, [
            .appIdPrefix, .displayName, .bundleId, .processId,
            .version, .buildNumber, .buildDate, .releaseType
        ]),
        (MenuSectionID.networking, [
            .ipAddress, .networkLogs, .networkConditioning, .networkRules, .networkBreakpoints,
            .serverConfiguration, .environmentVariables
        ]),
        (MenuSectionID.data, [
            .featureFlags, .userDefaults, .cookies, .fileBrowser, .databaseBrowser
        ]),
        (MenuSectionID.security, [
            .keychainBrowser
        ]),
        (MenuSectionID.systemTools, [
            .locationSpoofer, .consoleLogs, .deepLinkTester, .crashLogs
        ]),
        (MenuSectionID.notifications, [
            .notificationLogger, .notificationTester, .apnsToken, .fcmToken
        ]),
        (MenuSectionID.uiux, [
            .fonts, .interfaceComponents, .gridOverlay, .layoutGuides, .layoutRuler, .viewHierarchy,
            .fpsCounter, .touchVisualiser, .accessibilityAudit, .appearance, .language, .pseudoLocalization,
            .slowAnimations, .showViewFrames, .showViewSizes
        ])
    ]

    /// Each built-in row's home section identifier, indexed once from ``builtInLayout``.
    ///
    /// What makes ``MenuItem/tint`` a dictionary lookup. It used to rebuild
    /// ``allSections(developerOptions:)`` — nine localised titles — to find one row's section, and
    /// every row asked for its tint on every render.
    static let homeSectionIDs: [MenuItem: String] = Dictionary(
        uniqueKeysWithValues: builtInLayout.flatMap { section in
            section.items.map { item in (item, section.id) }
        }
    )

    /// A section's header text, localised into the effective language.
    ///
    /// - Parameter id: A section identifier, as declared in ``MenuSectionID``.
    /// - Returns: The localised title, or `id` itself for an identifier this version does not know.
    static func title(forID id: String) -> String {
        switch id {
        case MenuSectionID.device: return localized("Device")
        case MenuSectionID.application: return localized("Application")
        case MenuSectionID.developmentTools: return localized("Development Tools")
        case MenuSectionID.networking: return localized("Networking")
        case MenuSectionID.data: return localized("Data")
        case MenuSectionID.security: return localized("Security")
        case MenuSectionID.systemTools: return localized("System Tools")
        case MenuSectionID.notifications: return localized("Notifications")
        case MenuSectionID.uiux: return localized("UI/UX")
        case MenuSectionID.pinned: return localized("Pinned")
        default: return id
        }
    }

    /// The full menu layout, in display order.
    ///
    /// "Device" is always first — ``MenuView`` renders the device header inside it and
    /// inserts the "Pinned" section immediately afterwards.
    ///
    /// Resolves every section title, so it is not free: callers that render should hold on to the
    /// result, as ``MenuViewModel/sections`` does, rather than call this per row.
    ///
    /// - Parameter developerOptions: The host app's custom options, from
    ///   `Scyther.developerOptions`. When empty, the "Development Tools" section is omitted
    ///   entirely rather than rendered blank.
    /// - Returns: Every section that should be displayed.
    static func allSections(developerOptions: [DeveloperOption]) -> [MenuSection] {
        var sections = builtInLayout.map { section in
            MenuSection(id: section.id, title: title(forID: section.id), items: section.items)
        }

        if !developerOptions.isEmpty,
           let application = sections.firstIndex(where: { $0.id == MenuSectionID.application }) {
            sections.insert(
                MenuSection(
                    id: MenuSectionID.developmentTools,
                    title: title(forID: MenuSectionID.developmentTools),
                    items: developerOptions.map { .developerOption(name: $0.name) }
                ),
                at: application + 1
            )
        }

        return sections
    }
}

/// The stable identifiers of every ``MenuSection``.
///
/// These tokens are the menu's structural vocabulary: ``MenuSection/tint(forID:)`` keys the
/// section tile colours on them, and ``MenuView`` uses them for SwiftUI row identity. They are
/// never shown to the user and never translated, so a section keeps its colour and its identity
/// in every language.
enum MenuSectionID {
    /// Hardware and OS information.
    static let device = "device"

    /// App metadata and build details.
    static let application = "application"

    /// The host app's custom `DeveloperOption` rows.
    static let developmentTools = "developmentTools"

    /// Network tools, logs, and configuration.
    static let networking = "networking"

    /// Feature flags, `UserDefaults`, cookies, files, and databases.
    static let data = "data"

    /// The Keychain browser.
    static let security = "security"

    /// Location spoofing, console logs, deep links, and crash logs.
    static let systemTools = "systemTools"

    /// The notification logger and tester.
    static let notifications = "notifications"

    /// Fonts, components, overlays, and appearance overrides.
    static let uiux = "uiux"

    /// The synthetic section ``MenuView`` renders for pinned rows.
    static let pinned = "pinned"
}
