//
//  ScytherGesture.swift
//
//
//  Created by Brandon Stillitano on 22/12/20.
//

import Foundation

/// Defines the types of gestures that can trigger the Scyther developer menu.
///
/// `ScytherGesture` allows developers to configure how users can access the Scyther
/// debug menu within their application. The gesture type determines what physical
/// interaction will display the menu.
///
/// ## Usage Example
///
/// ```swift
/// // Configure Scyther to show menu on device shake
/// Scyther.shared.gestureType = .shake
///
/// // Or use a custom gesture
/// Scyther.shared.gestureType = .custom
/// // Then implement your custom trigger logic
/// ```
///
/// ## Gesture Types
///
/// - **Shake**: The menu appears when the device is physically shaken
/// - **Custom**: Allows you to implement your own trigger mechanism
///
/// - Note: This enum is marked `@objc` for Objective-C interoperability.
@objc public enum ScytherGesture: Int {
    /// The Scyther menu is triggered by physically shaking the device.
    ///
    /// This is the most common gesture type and provides a natural way for users
    /// to access debug functionality during development and testing.
    ///
    /// ## Implementation Details
    /// - Works on physical devices (not available in simulator)
    /// - Detects motion events through `UIResponder.motionEnded(_:with:)`
    /// - Also enables the Control–Command–Z (⌃⌘Z) hardware keyboard shortcut, so an iPad in a
    ///   keyboard case does not have to be shaken
    /// - Requires no additional configuration
    case shake

    /// The Scyther menu is triggered by a custom gesture or mechanism defined by the developer.
    ///
    /// Use this option when you want to implement your own trigger logic, such as:
    /// - A specific multi-touch gesture
    /// - A hidden button or UI element
    /// - A combination of actions (e.g., triple-tap on status bar)
    /// - Remote trigger via network request
    ///
    /// ## Usage Example
    ///
    /// ```swift
    /// Scyther.shared.gestureType = .custom
    ///
    /// // In your custom trigger code:
    /// func handleCustomGesture() {
    ///     Scyther.shared.show()
    /// }
    /// ```
    case custom
}
