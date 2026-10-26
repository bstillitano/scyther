//
//  ScytherStartTests.swift
//  ScytherTests
//
//  Created by Brandon Stillitano on 14/9/2026.
//

#if !os(macOS)
@testable import Scyther
import XCTest

/// `Scyther.start()` may be called more than once by a host app, and only the first call may run
/// the setup.
///
/// The real `start()` is called rather than a narrower seam, because the guard under test lives in
/// `start()` itself. The production gate cannot be exercised here: `AppEnvironment.isAppStore` is
/// derived from the simulator and debug flags and is always `false` in the test host.
@MainActor
final class ScytherStartTests: XCTestCase {

    /// Whether the process was already started when this test began.
    private var wasStarted = false

    /// Whether the console was already capturing when this test began.
    private var wasCapturing = false

    override func setUp() async throws {
        wasStarted = Scyther.isStarted
        wasCapturing = ConsoleLogger.instance.isCapturing
    }

    /// Puts back the process state `start()` changes that later tests can observe, the same way
    /// `NetworkRuleStartupTests` does. The remaining hooks install once per process and are inert
    /// while `Scyther._started` is `false`.
    override func tearDown() async throws {
        NetworkRuleSnapshot.update(isEnabled: true, rules: [])
        if !wasCapturing {
            ConsoleLogger.instance.stop()
        }
        Scyther._started = wasStarted
    }

    func testStartMarksScytherAsStarted() {
        Scyther.start()

        XCTAssertTrue(Scyther.isStarted)
    }

    /// Publishing the persisted overrides is one of the steps `start()` runs, and the snapshot it
    /// writes can be observed. Clearing the snapshot between two calls and finding it still clear
    /// shows that the second call skipped the setup.
    func testSecondStartDoesNotRunTheSetupAgain() {
        let rule = NetworkRule(
            id: UUID(),
            name: "idempotent start",
            isEnabled: true,
            match: .host("idempotent-start.invalid"),
            actions: NetworkRuleActions(stub: .mock(MockResponse(statusCode: 200, headers: [:], bodyID: nil, delay: 0)))
        )
        NetworkRuleStore.shared.add(rule)
        defer { NetworkRuleStore.shared.remove(id: rule.id) }

        Scyther.start()
        NetworkRuleSnapshot.update(isEnabled: true, rules: [])

        Scyther.start()

        XCTAssertTrue(Scyther.isStarted)
        XCTAssertFalse(
            NetworkRuleSnapshot.current.rules.contains { $0.id == rule.id },
            "a second start() must return before re-running any setup"
        )
    }

    /// The failure a second `start()` used to cause, when the `URLSessionConfiguration` hooks were
    /// installed by `start()`: it exchanged the implementations back, so new configurations no
    /// longer carried the interceptor.
    func testSecondStartKeepsSessionConfigurationsIntercepted() {
        Scyther.start()
        Scyther.start()

        assertIntercepted(URLSessionConfiguration.default, "default")
        assertIntercepted(URLSessionConfiguration.ephemeral, "ephemeral")
    }

    /// `NetworkHelper.start()` installs no hooks of its own any more — `ScytherBootstrap` installs
    /// them once, at image load — so calling it repeatedly must leave them in place.
    func testInstallingTheSessionConfigurationHooksTwiceKeepsThemInstalled() {
        NetworkHelper.instance.start()
        NetworkHelper.instance.start()

        assertIntercepted(URLSessionConfiguration.default, "default")
        assertIntercepted(URLSessionConfiguration.ephemeral, "ephemeral")
    }

    // MARK: - Helpers

    private func assertIntercepted(_ configuration: URLSessionConfiguration,
                                   _ name: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        let classes = configuration.protocolClasses ?? []
        XCTAssertTrue(
            classes.contains { $0 == HTTPInterceptorURLProtocol.self },
            "a \(name) configuration must still carry HTTPInterceptorURLProtocol",
            file: file,
            line: line
        )
    }
}
#endif
