//
//  ScytherKeyCommandTests.swift
//  ScytherTests
//
//  Created by Brandon Stillitano on 8/10/2026.
//

#if os(iOS)
@testable import Scyther
import UIKit
import XCTest

/// Every window offers ⌃⌘Z to open the menu while the menu is invoked by shaking, so an iPad in a
/// keyboard case does not have to be shaken.
///
/// The key press itself cannot be synthesised here; what is checked is that the window offers the
/// command, that it is bound to the chord documented in the README, and that it routes to an action
/// the window responds to.
@MainActor
final class ScytherKeyCommandTests: XCTestCase {

    /// Whether the process was already started when this test began.
    private var wasStarted = false

    /// The invocation gesture when this test began.
    private var originalGesture: ScytherGesture = .shake

    override func setUp() async throws {
        wasStarted = Scyther._started
        originalGesture = Scyther.invocationGesture
        Scyther._started = true
        Scyther.invocationGesture = .shake
    }

    override func tearDown() async throws {
        Scyther._started = wasStarted
        Scyther.invocationGesture = originalGesture
    }

    /// The Scyther command in `window`'s key commands, if it is offered.
    private func scytherCommand(in window: UIWindow) -> UIKeyCommand? {
        window.keyCommands?.first { $0.action == #selector(UIWindow.scytherShowMenu(_:)) }
    }

    func testWindowOffersTheShortcutWhenInvokedByShaking() throws {
        let command = try XCTUnwrap(scytherCommand(in: UIWindow()))

        XCTAssertEqual(command.input, "z")
        XCTAssertEqual(command.modifierFlags, [.control, .command])
        XCTAssertEqual(command.title, localized("Open Scyther"))
    }

    func testWindowRespondsToTheShortcutsAction() {
        XCTAssertTrue(UIWindow().responds(to: #selector(UIWindow.scytherShowMenu(_:))))
    }

    /// An app that chose `.custom` decides for itself how the menu opens.
    func testWindowDoesNotOfferTheShortcutForACustomGesture() {
        Scyther.invocationGesture = .custom

        XCTAssertNil(scytherCommand(in: UIWindow()))
    }

    /// Before `start()` the menu cannot be shown, so the shortcuts overlay must not offer it.
    func testWindowDoesNotOfferTheShortcutBeforeStart() {
        Scyther._started = false

        XCTAssertNil(scytherCommand(in: UIWindow()))
    }

    /// The command is appended to the window's inherited commands, never offered twice.
    func testShortcutIsOfferedExactlyOnce() {
        let window = UIWindow()
        let matches = window.keyCommands?.filter { $0.action == #selector(UIWindow.scytherShowMenu(_:)) }

        XCTAssertEqual(matches?.count, 1)
    }
}
#endif
