//
//  MenuSectionTests.swift
//  ScytherTests
//

#if !os(macOS)
@testable import Scyther
import SwiftUI
import XCTest

@MainActor
final class MenuSectionTests: XCTestCase {

    func testSectionIDsAreStableAndUnique() {
        let sections = MenuSection.allSections(developerOptions: [])
        let ids = sections.map(\.id)
        XCTAssertEqual(ids, ["device", "application", "networking", "data", "security", "systemTools", "notifications", "uiux"])
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testTintIsKeyedOnIDNotTitle() {
        XCTAssertEqual(MenuSection.tint(forID: "uiux"), .teal)
        XCTAssertEqual(MenuSection.tint(forID: "networking"), .blue)
        XCTAssertEqual(MenuSection.tint(forID: "unknown"), .accentColor)
        let uiux = MenuSection(id: "uiux", title: "Interface utilisateur", items: [])
        XCTAssertEqual(uiux.tint, .teal)
    }

    // MARK: - Layout

    /// The displayed sections are the static layout with titles attached — nothing more, in the
    /// same order — so the layout can be trusted as the single statement of the menu's shape.
    func testDisplayedSectionsAreTheStaticLayout() {
        let sections = MenuSection.allSections(developerOptions: [])
        XCTAssertEqual(sections.map(\.id), MenuSection.builtInLayout.map(\.id))
        XCTAssertEqual(sections.map(\.items), MenuSection.builtInLayout.map(\.items))
    }

    func testDeveloperOptionsAreInsertedAfterApplication() {
        let ids = MenuSection
            .allSections(developerOptions: [DeveloperOption(name: "Panel", value: "x")])
            .map(\.id)

        XCTAssertEqual(
            Array(ids.prefix(3)),
            [MenuSectionID.device, MenuSectionID.application, MenuSectionID.developmentTools]
        )
    }

    // MARK: - Home section index

    /// What makes ``MenuItem/tint`` a dictionary lookup rather than a rebuild of the whole
    /// localised layout.
    func testEveryBuiltInRowIsIndexedToItsOwnSection() {
        for section in MenuSection.builtInLayout {
            for item in section.items {
                XCTAssertEqual(
                    MenuSection.homeSectionIDs[item], section.id,
                    "\(item) is indexed to the wrong home section"
                )
            }
        }
    }

    func testTheHomeSectionIndexCoversEveryStaticItem() {
        XCTAssertEqual(Set(MenuSection.homeSectionIDs.keys), Set(MenuItem.allStaticCases))
    }

    // MARK: - Titles

    func testTitlesAreResolvedFromTheIdentifier() {
        XCTAssertEqual(MenuSection.title(forID: MenuSectionID.device), "Device")
        XCTAssertEqual(MenuSection.title(forID: MenuSectionID.uiux), "UI/UX")
        XCTAssertEqual(MenuSection.title(forID: MenuSectionID.developmentTools), "Development Tools")
        XCTAssertEqual(MenuSection.title(forID: MenuSectionID.pinned), "Pinned")
    }

    func testAnUnknownIdentifierTitlesAsItself() {
        XCTAssertEqual(MenuSection.title(forID: "removedInV2"), "removedInV2")
    }
}
#endif
