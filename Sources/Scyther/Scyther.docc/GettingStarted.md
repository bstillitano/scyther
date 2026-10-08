# Getting Started with Scyther

Learn how to integrate Scyther into your iOS app and start debugging.

@Metadata {
    @PageColor(green)
}

## Overview

Scyther is designed to be easy to integrate with minimal configuration. This guide walks you through installation, basic setup, and your first debugging session.

## Installation

### Swift Package Manager

Add Scyther to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/bstillitano/Scyther.git", branch: "main")
]
```

Or in Xcode:
1. Go to **File > Add Package Dependencies**
2. Enter the repository URL: `https://github.com/bstillitano/Scyther.git`
3. Select the `main` branch

## Basic Setup

### SwiftUI Apps

```swift
import SwiftUI
import Scyther

@main
struct MyApp: App {
    init() {
        // Start Scyther - automatically disabled on App Store builds
        Scyther.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

### UIKit Apps

```swift
import UIKit
import Scyther

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Scyther.start()
        return true
    }
}
```

Only the first call to ``Scyther/start(allowProductionBuilds:)`` that is allowed to run does
anything. Later calls are ignored, so calling it from more than one place is safe.

## Opening the Debug Menu

Once Scyther is started, you have several ways to open the debug menu:

### Shake Gesture (Default)

Simply shake your device. In the iOS Simulator, press `Cmd + Ctrl + Z`.

### Keyboard Shortcut

With a hardware keyboard attached — an iPad in a keyboard case, say — press **Control–Command–Z**
(⌃⌘Z). It is the same chord as the Simulator's shake, works whenever ``Scyther/invocationGesture``
is ``ScytherGesture/shake``, and is listed as "Open Scyther" in the overlay shown while ⌘ is held.
It is only added to each window's key commands, so the app's own shortcuts keep working, and an
app command bound to the same chord takes precedence.

### Programmatic Invocation

```swift
// Show the menu
Scyther.showMenu()

// Show from a specific view controller
Scyther.showMenu(from: myViewController)

// Hide the menu
Scyther.hideMenu()
```

### Custom Gesture

If you prefer a different trigger mechanism:

```swift
Scyther.invocationGesture = .custom

// Then trigger manually from your own gesture handler
func handleSecretGesture() {
    Scyther.showMenu()
}
```

## App Store Safety

By default, Scyther automatically disables itself on App Store builds. This ensures:
- No debugging UI accidentally appears for end users
- No performance impact in production
- No risk of App Store rejection

If you need to enable Scyther in production (not recommended):

```swift
Scyther.start(allowProductionBuilds: true)
```

> Warning: Enabling Scyther in production could expose sensitive debugging information to end users.

## Next Steps

Now that Scyther is integrated, explore its features:

- <doc:WorkingWithFeatureFlags> - Toggle features at runtime
- <doc:ManagingServerConfigurations> - Switch between environments
- <doc:NetworkDebugging> - Inspect HTTP traffic
- <doc:UIDebuggingTools> - Visual debugging aids
- <doc:AccessibilityAuditing> - Find missing labels, undersized touch targets, and low-contrast text
- <doc:SpoofingLocations> - Test location-based features

