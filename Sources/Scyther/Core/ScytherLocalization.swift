//
//  ScytherLocalization.swift
//  Scyther
//
//  Created by Brandon Stillitano on 4/9/2026.
//

import Foundation

/// Resolves a piece of Scyther's own UI copy from the package's String Catalog.
///
/// Every user-facing string in Scyther goes through this function so that SwiftUI and UIKit
/// call sites behave identically and follow the ``LanguageOverride``: when a language has been
/// forced from the Language page, strings are read from that language's `.lproj` table inside
/// the module bundle, so Scyther's menu switches language without a relaunch.
///
/// The parameter is a `String.LocalizationValue`, so a literal at the call site is recognised by
/// Xcode's catalog extraction and interpolations become format placeholders (`Int` → `%lld`,
/// `String` → `%@`). Add every new key, with all supported languages, to the fragment for its
/// module under `Scripts/localization/strings/` and run `Scripts/localization/build_catalog.py`.
///
/// ## Usage
///
/// ```swift
/// Text(localized("Network logs"))
/// LabeledContent(localized("Requests"), value: "\(count)")
/// Text(localized("Preparing archive of \(count) requests…"))
/// ```
///
/// - Parameters:
///   - key: The English source text, which is also the catalog key.
///   - comment: Context for translators. Not used at runtime.
/// - Returns: The string in the effective language, or the English source if the key is missing.
func localized(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String {
    localized(key, comment: comment, override: .shared)
}

/// Resolves a piece of Scyther's own UI copy against a specific ``LanguageOverride``.
///
/// The seam ``localized(_:comment:)`` is built on, so tests can drive a throwaway override backed
/// by its own `UserDefaults` suites instead of mutating the shared one.
///
/// Both the table *and* the locale come from `override`. `bundle` alone is not enough:
/// `String(localized:bundle:locale:)` picks the `.lproj` table from `bundle`, but selects the CLDR
/// plural category and formats `%lld` using `locale`, which otherwise defaults to `Locale.current`
/// — frozen at process launch and so still the *launch* language after a switch on the Language
/// page. Passing ``LanguageOverride/resolutionLocale`` keeps the two in step, so a Russian override
/// gets Russian's `few`/`many` forms rather than English's `one`/`other`.
///
/// - Parameters:
///   - key: The English source text, which is also the catalog key.
///   - comment: Context for translators. Not used at runtime.
///   - override: The override supplying the table and the resolution locale.
/// - Returns: The string in the override's effective language, or the English source if the key is
///   missing.
func localized(_ key: String.LocalizationValue, comment: StaticString? = nil, override: LanguageOverride) -> String {
    pseudoLocalized(localizedChrome(key, comment: comment, override: override), key: key)
}

/// Resolves a piece of Scyther's own UI copy *without* pseudo-localising it.
///
/// Pseudo-localisation has an obvious trap: a developer who switches on "Show keys" and
/// right-to-left, then finds the whole debug menu rendered as `Þšéûðö-ļöçåļîšåţîöñ`, still has to
/// be able to find the screen that switches it off again. The rows that form that escape hatch —
/// the menu row itself, and every control on ``PseudoLocalizationView`` — resolve their copy
/// through this function instead, so they are the one part of Scyther that stays legible no matter
/// what is switched on.
///
/// It is deliberately narrow. Exempting the whole menu would be safer still, and would also mean
/// the feature demonstrated nothing: Scyther's interface is a real, fully localised SwiftUI app,
/// and watching it grow, flip and lose its accents is most of what there is to see when the host
/// app resolves its strings through a path no hook can reach.
///
/// - Parameters:
///   - key: The English source text, which is also the catalog key.
///   - comment: Context for translators. Not used at runtime.
///   - override: The override supplying the table and the resolution locale.
/// - Returns: The string in the override's effective language, never transformed.
func localizedChrome(
    _ key: String.LocalizationValue,
    comment: StaticString? = nil,
    override: LanguageOverride = .shared
) -> String {
    String(localized: key, bundle: override.effectiveBundle, locale: override.resolutionLocale, comment: comment)
}

/// Applies whichever pseudo-localisation modes are switched on to an already-resolved string.
///
/// Sits between ``localized(_:comment:override:)`` and ``PseudoLocalizationTransform`` so the
/// platform guard and the fast path live in one place rather than at every call site. The fast
/// path matters: this runs once per string in Scyther's interface — about 1,500 times for one
/// render of the main menu — so with every mode off it costs an uncontended lock and an emptiness
/// check before returning the input untouched. The modes come from memory
/// (``PseudoLocalizationModeCache``), never from `UserDefaults`: reading them from disk here was
/// what froze the menu for seconds on every render in the Simulator.
///
/// The key is recovered by reflection rather than passed in, because the call sites hand over a
/// literal and there is no other way to see the `%lld`-shaped catalog key behind an interpolated
/// one. When reflection cannot find it, the resolved string stands in: showing the English copy
/// where a key was asked for is a poor answer, but it is a readable one, and better than the
/// alternative of dropping the whole mode.
///
/// - Parameters:
///   - resolved: The string as the catalog resolved it, arguments already substituted.
///   - key: The localisation value it was resolved from.
/// - Returns: The transformed string, or `resolved` when no text-affecting mode is on.
private func pseudoLocalized(_ resolved: String, key: String.LocalizationValue) -> String {
#if os(macOS)
    return resolved
#else
    let modes = PseudoLocalization.instance.activeModes
    guard !modes.intersection(.textAffecting).isEmpty else { return resolved }
    return PseudoLocalizationTransform.apply(
        to: resolved,
        key: PseudoLocalizationKey.extract(from: key) ?? resolved,
        modes: modes
    )
#endif
}

/// Package-level localisation constants.
enum ScytherLocalization {
    /// The bundle holding Scyther's compiled String Catalog.
    static let moduleBundle: Bundle = .module

    /// The languages shipped in the catalog, in addition to the English source.
    static let supportedLanguages: [String] = [
        "fr", "de", "es", "it", "pt-BR", "nl", "ja", "zh-Hans", "zh-Hant", "ko", "ru", "ar",
    ]
}
