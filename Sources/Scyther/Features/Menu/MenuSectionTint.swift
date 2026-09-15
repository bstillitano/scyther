//
//  MenuSectionTint.swift
//  Scyther
//
//  Created by Brandon Stillitano on 3/8/2026.
//

import SwiftUI

extension MenuSection {
    /// The tile colour for rows belonging to a section, keyed by ``MenuSectionID``.
    ///
    /// Every row's icon tile is tinted with its *home* section's colour, giving each
    /// section a distinct identity the way the iOS Settings app colours its icons.
    /// Rows rendered outside their home section — the "Pinned" section and search
    /// results — keep their home colour, so a row is recognisable wherever it appears.
    ///
    /// Keyed on the identifier rather than the title because ``MenuSection/title`` is
    /// localised: a title-keyed switch would fall through to the accent colour for every
    /// section as soon as the user picked a language other than English.
    ///
    /// - Parameter id: A section identifier, as declared in ``MenuSectionID``. Unknown
    ///   identifiers fall back to the app's accent colour rather than failing.
    /// - Returns: The section's tile colour.
    static func tint(forID id: String) -> Color {
        switch id {
        case MenuSectionID.device: return .gray
        case MenuSectionID.application: return .indigo
        case MenuSectionID.developmentTools: return .brown
        case MenuSectionID.networking: return .blue
        case MenuSectionID.data: return .orange
        case MenuSectionID.security: return .green
        case MenuSectionID.systemTools: return .purple
        case MenuSectionID.notifications: return .red
        case MenuSectionID.uiux: return .teal
        default: return .accentColor
        }
    }

    /// This section's tile colour — see ``tint(forID:)``.
    var tint: Color { Self.tint(forID: id) }
}

extension MenuItem {
    /// The row's tile colour — its home section's ``MenuSection/tint``.
    ///
    /// A computed sibling of ``title`` and ``icon``, so a row's whole presentation
    /// reads off the item itself. Home sections of built-in rows are static layout
    /// (``MenuSection/builtInLayout``), and a developer option always lives in the
    /// Development Tools section, so no live menu state is needed.
    ///
    /// A dictionary lookup in ``MenuSection/homeSectionIDs``, and deliberately so: every row
    /// asks for its tint on every render. This used to rebuild the localised section list to
    /// find the row's home, which was most of the work a render of the menu did.
    var tint: Color {
        if case .developerOption = self {
            return MenuSection.tint(forID: MenuSectionID.developmentTools)
        }
        guard let home = MenuSection.homeSectionIDs[self] else { return .accentColor }
        return MenuSection.tint(forID: home)
    }
}
