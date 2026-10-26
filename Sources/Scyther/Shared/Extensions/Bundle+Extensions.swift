//
//  Bundle+Extensions.swift
//  Scyther
//
//  Created by Brandon Stillitano on 15/12/20.
//

import Foundation

/// Provides convenient extensions for accessing bundle and application metadata.
///
/// This extension adds utility properties to retrieve common application information such as
/// version numbers, build dates, and security identifiers from the main bundle.
extension Bundle {
    /// The version number of the application as specified in the Info.plist.
    ///
    /// This corresponds to the `CFBundleShortVersionString` key in the Info.plist file.
    ///
    /// ## Example
    /// ```swift
    /// if let version = Bundle.main.versionNumber {
    ///     print("App version: \(version)") // e.g., "1.0.0"
    /// }
    /// ```
    ///
    /// - Returns: The version string, or `nil` if not found in the Info.plist
    public var versionNumber: String? {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// The build number of the application as specified in the Info.plist.
    ///
    /// This corresponds to the `CFBundleVersion` key in the Info.plist file.
    ///
    /// ## Example
    /// ```swift
    /// if let build = Bundle.main.buildNumber {
    ///     print("Build number: \(build)") // e.g., "42"
    /// }
    /// ```
    ///
    /// - Returns: The build number string, or `nil` if not found in the Info.plist
    public var buildNumber: String? {
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// The build date of the application based on the modification date of the Info.plist file.
    ///
    /// This property retrieves the last modification date of the Info.plist file, which
    /// typically corresponds to when the application was built.
    ///
    /// ## Example
    /// ```swift
    /// let buildDate = Bundle.main.buildDate
    /// print("Built on: \(buildDate)")
    /// ```
    ///
    /// - Returns: The build date, or the current date if the Info.plist file cannot be accessed
    public var buildDate: Date {
        guard let infoPath = self.path(forResource: "Info", ofType: "plist") else {
            return Date()
        }
        guard let infoAttributes = try? FileManager.default.attributesOfItem(atPath: infoPath) else {
            return Date()
        }
        return infoAttributes[.modificationDate] as? Date ?? Date()
    }

    /// Returns the App Identifier Prefix for the application.
    ///
    /// This is also commonly referred to as the "Seed ID" or the "Team ID". It's the prefix
    /// used in the app's keychain access group identifiers.
    ///
    /// The implementation queries the keychain to retrieve the bundle seed ID from the
    /// access group attribute of a generic password item.
    ///
    /// ## Example
    /// ```swift
    /// if let seedId = Bundle.main.seedId {
    ///     print("Team ID: \(seedId)") // e.g., "A1B2C3D4E5"
    /// }
    /// ```
    ///
    /// - Returns: The seed ID string, or `nil` if it cannot be retrieved from the keychain
    ///
    /// - Note: This method requires keychain access and may fail if the app doesn't have
    ///         the necessary entitlements.
    ///
    /// - SeeAlso: [Stack Overflow: Access App Identifier Prefix Programmatically](https://stackoverflow.com/questions/11726672/access-app-identifier-prefix-programmatically)
    public var seedId: String? {
        let queryLoad: [String: AnyObject] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "bundleSeedID" as AnyObject,
            kSecAttrService as String: "" as AnyObject,
            kSecReturnAttributes as String: kCFBooleanTrue
        ]

        var result: AnyObject?
        var status = withUnsafeMutablePointer(to: &result) {
            SecItemCopyMatching(queryLoad as CFDictionary, UnsafeMutablePointer($0))
        }

        if status == errSecItemNotFound {
            status = withUnsafeMutablePointer(to: &result) {
                SecItemAdd(queryLoad as CFDictionary, UnsafeMutablePointer($0))
            }
        }

        if status == noErr {
            if let resultDict = result as? [String: Any], let accessGroup = resultDict[kSecAttrAccessGroup as String] as? String {
                let components = accessGroup.components(separatedBy: ".")
                return components.first
            } else {
                return nil
            }
        } else {
            print("Error getting bundleSeedID to Keychain")
            return nil
        }
    }
}
