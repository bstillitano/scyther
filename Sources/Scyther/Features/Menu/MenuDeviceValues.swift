//
//  MenuDeviceValues.swift
//  Scyther
//
//  Created by Brandon Stillitano on 16/9/2026.
//

#if !os(macOS)
import UIKit

/// The fixed facts the menu's **Device** and **Application** rows show — OS version, hardware,
/// bundle identifier, build date and the like.
///
/// None of them can change while the process is running, but several are not cheap to read, and one
/// is not even free of side effects: ``Bundle/seedId`` queries the keychain and *adds* an item when
/// it finds none, ``Bundle/buildDate`` stats `Info.plist`, and `UIDevice.modelName` reflects over
/// `utsname`. ``MenuView`` used to read all of them inside every row's body, which meant on every
/// render — each scroll that brought a row back on screen included. ``MenuViewModel`` now takes one
/// snapshot per menu and serves the rows from it.
///
/// Push tokens are deliberately not here. `Scyther.apnsToken` and `Scyther.fcmToken` are set by the
/// host app, possibly after the menu is already open, so ``MenuViewModel/valueDescription(for:)``
/// reads those live.
///
/// ## Topics
///
/// ### Reading the values
/// - ``current()``
enum MenuDeviceValues {
    /// Reads every fixed device and application value once.
    ///
    /// - Returns: Each row's value, keyed by row. A row whose value the system cannot supply —
    ///   ``MenuItem/appIdPrefix`` without keychain access, ``MenuItem/uuid`` before first unlock —
    ///   is absent rather than present and empty, so the row renders without a value exactly as it
    ///   did when it read `nil` directly.
    @MainActor
    static func current() -> [MenuItem: String] {
        var values: [MenuItem: String] = [:]
        values[.osVersion] = UIDevice.current.systemVersion
        values[.hardware] = UIDevice.current.modelName
        values[.releaseYear] = UIDevice.current.generation.withoutDecimals
        values[.uuid] = UIDevice.current.identifierForVendor?.uuidString
        values[.appIdPrefix] = Bundle.main.seedId
        values[.displayName] = String(UIApplication.shared.appName)
        values[.bundleId] = Bundle.main.bundleIdentifier
        values[.processId] = String(getpid())
        values[.version] = Bundle.main.versionNumber
        values[.buildNumber] = Bundle.main.buildNumber
        values[.buildDate] = Bundle.main.buildDate.formatted()
        values[.releaseType] = AppEnvironment.configuration().rawValue
        return values
    }
}
#endif
