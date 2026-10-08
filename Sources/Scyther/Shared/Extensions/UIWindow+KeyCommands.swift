//
//  UIWindow+KeyCommands.swift
//  Scyther
//
//  Created by Brandon Stillitano on 8/10/2026.
//

#if os(iOS)
import UIKit

/// The hardware keyboard shortcut that opens the Scyther menu.
///
/// Shaking an iPad that is sitting in a keyboard case is awkward, so whenever the menu is invoked
/// by ``ScytherGesture/shake`` it can also be opened with **Control–Command–Z** (⌃⌘Z) from a
/// connected hardware keyboard. The shortcut is deliberately the same chord the iOS Simulator uses
/// for *Device › Shake*, so one shortcut opens the menu everywhere: in the Simulator the chord is
/// turned into a shake before the app sees it, and on a device it arrives as this key command.
///
/// The command is offered from every `UIWindow`, which sits at the end of the responder chain for
/// everything shown in it, so it works whatever the app has focused — including a text field. It
/// appears in the shortcuts overlay shown while ⌘ is held, under the title "Open Scyther".
///
/// - Note: A host app whose own `UIWindow` subclass overrides `keyCommands` without calling
///   `super` hides the shortcut, exactly as such a subclass would hide UIKit's own.
@MainActor
enum ScytherKeyCommand {
    /// The key the shortcut is bound to.
    static let input = "z"

    /// The modifiers held with ``input``.
    static let modifierFlags: UIKeyModifierFlags = [.control, .command]

    /// Whether the shortcut should be offered right now.
    ///
    /// It is offered only when Scyther has been started, the menu is invoked by shaking (an app
    /// that chose ``ScytherGesture/custom`` decides for itself how the menu opens), and the menu
    /// is not already up — so the shortcuts overlay inside the menu does not offer to open it.
    static var isAvailable: Bool {
        Scyther.isStarted && Scyther.invocationGesture == .shake && !Scyther.isPresented
    }

    /// Builds the key command, targeting `UIWindow.scytherShowMenu(_:)` through the responder chain.
    ///
    /// - Returns: A key command for ⌃⌘Z titled with the localised "Open Scyther".
    static func make() -> UIKeyCommand {
        UIKeyCommand(
            title: localized("Open Scyther", comment: "Hardware keyboard shortcut title for opening the Scyther menu"),
            action: #selector(UIWindow.scytherShowMenu(_:)),
            input: input,
            modifierFlags: modifierFlags
        )
    }
}

/// Offers ``ScytherKeyCommand`` from every window.
extension UIWindow {
    /// The window's key commands, with Scyther's menu shortcut appended while it is available.
    ///
    /// `UIWindow` does not implement `keyCommands` itself — UIKit's implementation lives on
    /// `UIResponder` — so this override replaces nothing of UIKit's, and `super` still returns
    /// whatever the responder implementation would have.
    override open var keyCommands: [UIKeyCommand]? {
        guard ScytherKeyCommand.isAvailable else {
            return super.keyCommands
        }
        return (super.keyCommands ?? []) + [ScytherKeyCommand.make()]
    }

    /// Opens the Scyther menu in response to ``ScytherKeyCommand``.
    ///
    /// - Parameter sender: The key command that fired. Unused.
    @objc func scytherShowMenu(_ sender: UIKeyCommand) {
        Scyther.showMenu()
    }
}
#endif
