//
//  SessionConfigurationHookTests.swift
//  ScytherTests
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
@testable import Scyther
import Foundation
import ScytherBootstrap
import Testing

/// The `ScytherBootstrap` hooks put `HTTPInterceptorURLProtocol` into every
/// `URLSessionConfiguration` from the moment the image loads, so a session built before
/// `Scyther.start()` is still intercepted once Scyther starts.
///
/// Serialized and main-actor bound because several tests flip `Scyther._started`, which every
/// interceptor in the process reads. Each one puts it back.
@Suite(.serialized)
@MainActor
struct SessionConfigurationHookTests {

    @Test func theBootstrapInstalledItsHooks() {
        #expect(ScytherBootstrapIsInstalled())
    }

    /// The interceptor is resolved by its runtime name, so a rename would quietly disable every
    /// hook. This pins the name the bootstrap looks up.
    @Test func theInterceptorResolvesByTheNameTheBootstrapUses() {
        #expect(NSClassFromString("Scyther.HTTPInterceptorURLProtocol") == HTTPInterceptorURLProtocol.self)
    }

    @Test func aConfigurationCreatedBeforeStartIsIntercepted() {
        withScytherStarted(false) {
            #expect(interceptorIndices(URLSessionConfiguration.default) == [0])
            #expect(interceptorIndices(URLSessionConfiguration.ephemeral) == [0])
            #expect(interceptorIndices(URLSessionConfiguration.background(withIdentifier: "scyther.hook.tests")) == [0])
        }
    }

    /// `URLSessionConfiguration()` has been deprecated since iOS 13 and comes back with no protocol
    /// classes at all; on current releases a session cannot even be built from it. The `-init` hook
    /// still runs for it, and must not invent a list: one holding only the interceptor would stand
    /// in for the system's own protocols.
    @Test func anInitialisedConfigurationWithNoProtocolsIsLeftWithout() {
        #expect(URLSessionConfiguration().protocolClasses == nil)
    }

    /// A session copies its configuration when it is created, so the interceptor has to be in the
    /// copy too.
    @Test func aSessionCreatedBeforeStartCarriesTheInterceptor() {
        withScytherStarted(false) {
            let session = URLSession(configuration: .default)
            defer { session.invalidateAndCancel() }

            #expect(interceptorIndices(session.configuration) == [0])
        }
    }

    /// End to end: a session built before Scyther starts, from a configuration the app never
    /// touched, has its requests served by Scyther once it has. The host does not resolve, so only
    /// a request override answering through the interceptor can produce the response.
    @Test func aSessionCreatedBeforeStartIsServedByScytherAfterIt() async throws {
        let wasStarted = Scyther._started
        Scyther._started = false
        let session = URLSession(configuration: .default)
        defer {
            session.invalidateAndCancel()
            NetworkRuleSnapshot.update(isEnabled: true, rules: [])
            Scyther._started = wasStarted
        }

        Scyther._started = true
        NetworkRuleSnapshot.update(isEnabled: true, rules: [
            NetworkRule(
                id: UUID(),
                name: "early session",
                isEnabled: true,
                match: .host("early-session.invalid"),
                actions: NetworkRuleActions(stub: .mock(MockResponse(statusCode: 418, headers: [:], bodyID: nil, delay: 0)))
            ),
        ])

        let (_, response) = try await session.data(from: try #require(URL(string: "https://early-session.invalid/")))

        #expect((response as? HTTPURLResponse)?.statusCode == 418)
    }

    @Test func theInterceptorRefusesEveryRequestUntilScytherStarts() throws {
        let request = URLRequest(url: try #require(URL(string: "https://hook-tests.invalid/path")))

        withScytherStarted(false) {
            #expect(HTTPInterceptorURLProtocol.canInit(with: request) == false)
        }
        withScytherStarted(true) {
            #expect(HTTPInterceptorURLProtocol.canInit(with: request))
        }
    }

    @Test func aBackgroundConfigurationThatOptsOutIsLeftAlone() {
        let configuration = URLSessionConfiguration.background(withIdentifier: "upload_\(String.noSwizzle)")

        #expect(interceptorIndices(configuration).isEmpty)
    }

    /// `.default` is hooked like any other configuration, so the opt-out has to take the
    /// interceptor back out, and the session's copy must not get it back.
    @Test func aDefaultConfigurationThatOptsOutIsLeftAlone() {
        let configuration = URLSessionConfiguration.default(withIdentifier: "webhook_\(String.noSwizzle)")
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        #expect(interceptorIndices(configuration).isEmpty)
        #expect(interceptorIndices(session.configuration).isEmpty)
    }

    @Test func aDefaultConfigurationWithAnOrdinaryIdentifierIsIntercepted() {
        let configuration = URLSessionConfiguration.default(withIdentifier: "api_client")

        #expect(interceptorIndices(configuration) == [0])
        #expect(configuration.sharedContainerIdentifier == "api_client")
    }

    @Test func theHookedGettersStillReturnWorkingConfigurations() {
        let defaultConfiguration = URLSessionConfiguration.default
        let ephemeral = URLSessionConfiguration.ephemeral
        let background = URLSessionConfiguration.background(withIdentifier: "scyther.hook.working")

        /// The system's own protocols are still there, behind the interceptor.
        #expect((defaultConfiguration.protocolClasses?.count ?? 0) > 1)
        #expect(defaultConfiguration.timeoutIntervalForRequest == 60)
        #expect(ephemeral.httpCookieStorage !== HTTPCookieStorage.shared)
        #expect(background.identifier == "scyther.hook.working")
    }

    /// A session built from a hooked configuration still loads. A `data:` URL keeps the test off
    /// the network, and the interceptor declines it, so the system protocol behind it answers.
    @Test func aHookedSessionStillLoads() async throws {
        let session = URLSession(configuration: .default)
        defer { session.invalidateAndCancel() }

        let (data, _) = try await session.data(from: try #require(URL(string: "data:text/plain,scyther")))

        #expect(String(decoding: data, as: UTF8.self) == "scyther")
    }

    // MARK: - Helpers

    /// Where `HTTPInterceptorURLProtocol` appears in a configuration's protocol classes. `[0]` means
    /// it is there exactly once, in front.
    private func interceptorIndices(_ configuration: URLSessionConfiguration) -> [Int] {
        (configuration.protocolClasses ?? []).indices.filter {
            configuration.protocolClasses?[$0] == HTTPInterceptorURLProtocol.self
        }
    }

    /// Runs `body` with `Scyther.isStarted` forced to `started`, then puts it back.
    private func withScytherStarted(_ started: Bool, _ body: () -> Void) {
        let wasStarted = Scyther._started
        Scyther._started = started
        defer { Scyther._started = wasStarted }
        body()
    }
}
#endif
