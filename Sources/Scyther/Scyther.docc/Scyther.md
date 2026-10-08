# ``Scyther``

A comprehensive iOS debugging toolkit that helps you cut through bugs in your app.

@Metadata {
    @DisplayName("Scyther")
    @PageImage(purpose: icon, source: "scyther-logo", alt: "The Scyther logo")
    @PageColor(green)
}

## Overview

Scyther is a powerful debugging toolkit for iOS developers, QA testers, UI/UX teams, and backend developers. It provides a suite of tools accessible via a shake gesture or programmatic invocation.

Named after the [Pokemon Scyther](https://pokemondb.net/pokedex/scyther), a bug-type known for its cutting ability - just like this library cuts through bugs!

### Key Features

- **Feature Flags**: Register and override feature flags at runtime
- **Server Configuration**: Switch between development, staging, and production environments
- **Network Logging**: Automatically intercept and log all HTTP requests/responses
- **Location Spoofing**: Fake GPS coordinates for testing location-based features
- **UI Debugging**: Grid overlays, touch visualization, view frame debugging
- **Console Logging**: Capture and view stdout/stderr output
- **Push Notification Testing**: Schedule and log test notifications

### Quick Start

```swift
import Scyther

@main
struct MyApp: App {
    init() {
        Scyther.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

Once started, **shake your device** (or press `Control + Command + Z` on a hardware keyboard or in the simulator) to open the debug menu.

### Swift 6 Ready

Scyther is fully compatible with Swift 6 strict concurrency. Key components use proper actor isolation:

| Component | Isolation | Description |
|-----------|-----------|-------------|
| ``Scyther`` | `@MainActor` | Main entry point |
| ``Servers`` | `actor` | Thread-safe server configuration |
| ``NetworkLogger`` | `actor` | Thread-safe request logging |
| ``FeatureFlags`` | `@MainActor` | Feature flag management |

## Topics

### Essentials

- <doc:GettingStarted>
- ``Scyther/start(allowProductionBuilds:)``
- ``Scyther/showMenu(from:)``
- ``ScytherDelegate``

### Feature Flags

- <doc:WorkingWithFeatureFlags>
- ``FeatureFlags``
- ``FeatureToggle``

### Server Configuration

- <doc:ManagingServerConfigurations>
- ``Servers``
- ``ServerConfiguration``

### Network Debugging

- <doc:NetworkDebugging>
- ``NetworkLogger``
- ``Network``
- ``NetworkLoggerRequest``
- ``NetworkRules``
- ``NetworkRule``
- ``NetworkRuleMatch``
- ``NetworkRulePattern``
- ``NetworkRuleActions``
- ``NetworkRuleStub``
- ``MockResponse``
- ``MapLocalFile``
- ``NetworkHeaderRewrite``
- ``NetworkCondition``

### Location Spoofing

- <doc:SpoofingLocations>
- ``LocationSpoofer``
- ``Location``
- ``Route``

### UI Debugging Tools

- <doc:UIDebuggingTools>
- ``InterfaceToolkit``
- ``TouchVisualiser``
- ``TouchVisualiserConfiguration``
- ``GridOverlay``

### Accessibility Auditing

- <doc:AccessibilityAuditing>
- ``AccessibilityAuditView``
- ``AccessibilityAuditViewModel``
- ``AccessibilityAuditor``
- ``AccessibilityCheck``
- ``AccessibilityFinding``
- ``AccessibilitySeverity``

### Console & Logging

- ``ConsoleLogger``
- ``ConsoleLogEntry``

### Push Notifications

- ``NotificationTester``

### Language Support

- <doc:Localisation>
- ``LanguageOverride``
- <doc:PseudoLocalisation>
- ``PseudoLocalization``

### Customization

- ``DeveloperOption``
- ``ScytherGesture``

