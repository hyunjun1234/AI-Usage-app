import Foundation

/// Subprocess integration tests, runnable with Command Line Tools and Python 3.
@main
struct CodexAppServerTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    final class Fixture {
        let directory: URL
        let client: CodexAppServer
        var results: [Result<CodexLimitsResult, CodexServiceError>] = []
        var loginStates: [CodexLoginState] = []
        var loginURLs: [URL] = []
        var accountChanges = 0
        var callbacksWereOnMainThread = true

        init(_ scenario: String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("aiusage-codex-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/mock-codex-server.py")
            let executable = directory.appendingPathComponent("codex")
            try FileManager.default.copyItem(at: source, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let configuration = try JSONSerialization.data(withJSONObject: ["scenario": scenario])
            try configuration.write(to: directory.appendingPathComponent("scenario.json"))
            client = CodexAppServer(binaryPath: executable.path)
            client.onLimits = { [weak self] result in
                self?.recordThread()
                self?.results.append(result)
            }
            client.onLoginStateChanged = { [weak self] state in
                self?.recordThread()
                self?.loginStates.append(state)
            }
            client.onOpenLoginURL = { [weak self] url in
                self?.recordThread()
                self?.loginURLs.append(url)
            }
            client.onAccountChanged = { [weak self] in
                self?.recordThread()
                self?.accountChanges += 1
            }
        }

        func recordThread() {
            callbacksWereOnMainThread = callbacksWereOnMainThread && Thread.isMainThread
        }

        func close() {
            client.stop()
            // Let the client's serial queue process stop before removing its fixture.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            try? FileManager.default.removeItem(at: directory)
        }

        func events() throws -> [[String: Any]] {
            let data = try Data(contentsOf: directory.appendingPathComponent("events.jsonl"))
            return try data.split(separator: 0x0a).map {
                try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
            }
        }
    }

    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("handshake, fragmented UTF-8, and persistent process", testFragmentedResponseAndProcessReuse),
            ("authentication errors return immediately", testAuthenticationErrorReturnsImmediately),
            ("browser login refreshes limits and logout invalidates them", testBrowserLoginAndLogout),
            ("pending browser login can be canceled", testLoginCancellation),
            ("canceling pending login allows an immediate new attempt", testImmediateLoginRetry),
            ("invalid login URL releases queued refresh", testInvalidLoginURLReleasesRefresh),
            ("failed login completion releases queued refresh", testFailedLoginCompletionReleasesRefresh),
            ("account change discards stale in-flight response", testAccountChangeDiscardsStaleResponse),
            ("weekly primary window uses its reported duration", testWeeklyPrimaryWindow),
            ("reversed windows use reported durations", testReversedWindowDurations),
            ("legacy windows retain positional interpretation", testLegacyWindowPositions),
        ]
        do {
            for (name, test) in tests {
                try test()
                print("PASS: \(name)")
            }
            print("\(tests.count) Codex app-server tests passed")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func testFragmentedResponseAndProcessReuse() throws {
        let fixture = try Fixture("fragmented")
        defer { fixture.close() }
        fixture.client.refresh()
        try wait("first fragmented limits response") { fixture.results.count == 1 }
        let first = try success(fixture.results[0])
        try expect(first.fiveHour?.usedPercent == 10.5, "Primary usage should retain fractional precision")
        try expect(first.weekly?.usedPercent == 42.25, "Secondary usage should be parsed")
        try expect(first.fiveHour?.kind == .fiveHour && first.weekly?.kind == .weekly, "Window kinds should match")
        try expect(first.fiveHour?.isReal == true && first.weekly?.isReal == true, "Server usage should be real")
        try expect(first.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000), "Reset timestamp should be parsed")
        try expect(first.planType == "한글 Plus", "UTF-8 split across subprocess writes should remain intact")

        fixture.client.refresh()
        try wait("second refresh response") { fixture.results.count == 2 }
        try expect(try success(fixture.results[1]).fiveHour?.usedPercent == 20.5, "Second refresh should use the existing server")
        let events = try fixture.events()
        try expect(events.filter { $0["event"] as? String == "started" }.count == 1, "Refresh should reuse one subprocess")
        try expect(events.filter { $0["method"] as? String == "initialize" }.count == 1, "Initialization should happen once")
        try expect(events.filter { $0["method"] as? String == "initialized" }.count == 1, "Initialized notification should be sent once")
        try expect(!events.contains { $0["event"] as? String == "handshakeViolation" }, "Requests must await initialization")
        try expect(fixture.callbacksWereOnMainThread, "UI callbacks should run on the main thread")
    }

    static func testAuthenticationErrorReturnsImmediately() throws {
        let fixture = try Fixture("auth-error")
        defer { fixture.close() }
        let started = Date()
        fixture.client.refresh()
        try wait("authentication failure", timeout: 3) { !fixture.results.isEmpty }
        let error = try failure(fixture.results[0])
        try expect(error.requiresLogin, "Authentication failure should offer login")
        try expect(!error.message.isEmpty, "Server failure should have a visible message")
        try expect(Date().timeIntervalSince(started) < 3, "JSON-RPC errors should return without waiting for the request timeout")
        try expect(fixture.callbacksWereOnMainThread, "Error callback should run on the main thread")
    }

    static func testBrowserLoginAndLogout() throws {
        let fixture = try Fixture("login")
        defer { fixture.close() }
        fixture.client.refresh()
        try wait("initial signed-out result") { fixture.results.count == 1 }
        try expect(try failure(fixture.results[0]).requiresLogin, "Signed-out state should require login")

        fixture.client.startLogin()
        try wait("browser URL") { !fixture.loginURLs.isEmpty }
        try expect(fixture.loginURLs.map(\.absoluteString) == ["https://auth.openai.com/fixture-login"], "Open only the server-provided login URL")
        try expect(fixture.loginStates.contains { if case .waitingForBrowser = $0 { return true }; return false }, "Login should show browser waiting state")
        try wait("automatic limits refresh after login") { fixture.results.count >= 2 }
        try expect(try success(fixture.results[1]).planType == "plus", "Successful browser login should fetch account limits")
        try expect(fixture.loginStates.contains { if case .idle = $0 { return true }; return false }, "Successful login should finish waiting")

        // The mock reports account logout on this refresh, then rejects all reads.
        fixture.client.refresh()
        try wait("account logout and authentication failure") {
            fixture.accountChanges > 0 && fixture.results.count >= 3
        }
        try expect(try failure(fixture.results.last!).requiresLogin, "Logout must report that the previous account's limits are no longer valid")
        try expect(fixture.callbacksWereOnMainThread, "Login and account callbacks should run on the main thread")
    }

    static func testLoginCancellation() throws {
        let fixture = try Fixture("cancel-login")
        defer { fixture.close() }
        fixture.client.startLogin()
        try wait("pending login URL") { fixture.loginURLs.count == 1 }
        fixture.client.cancelLogin()
        try wait("login cancellation request") {
            (try? fixture.events().contains { $0["method"] as? String == "account/login/cancel" }) == true
        }
        let cancellation = try fixture.events().first { $0["method"] as? String == "account/login/cancel" }
        try expect((cancellation?["params"] as? [String: Any])?["loginId"] as? String == "fixture-login", "Cancellation should target the pending login")
        try wait("idle state after cancellation") {
            guard let last = fixture.loginStates.last else { return false }
            if case .idle = last { return true }
            return false
        }
        try expect(fixture.callbacksWereOnMainThread, "Cancellation callback should run on the main thread")
    }

    static func testImmediateLoginRetry() throws {
        let fixture = try Fixture("retry-login")
        defer { fixture.close() }
        fixture.client.startLogin()
        try wait("first login request, before its response") {
            (try? fixture.events().contains { $0["method"] as? String == "account/login/start" }) == true
        }
        fixture.client.cancelLogin()
        fixture.client.startLogin()
        try Data().write(to: fixture.directory.appendingPathComponent("release-login"))
        try wait("replacement login URL and successful limits refresh") {
            !fixture.loginURLs.isEmpty && !fixture.results.isEmpty
        }
        try expect(fixture.loginURLs.map(\.absoluteString) == ["https://auth.openai.com/fixture-login-2"],
                   "The canceled attempt's URL must not open; the new attempt must produce its own URL")
        try expect(try success(fixture.results[0]).planType == "plus", "The replacement login should complete and fetch limits")
        let events = try fixture.events()
        try expect(events.filter { $0["method"] as? String == "account/login/start" }.count == 2,
                   "Immediate retry should start a fresh login")
        try expect(events.contains {
            $0["method"] as? String == "account/login/cancel"
                && ($0["params"] as? [String: Any])?["loginId"] as? String == "fixture-login-1"
        }, "The canceled start response should be canceled on the server once its login ID arrives")
        guard let lastState = fixture.loginStates.last, case .idle = lastState else {
            throw Failure(description: "Successful replacement login must leave the waiting state")
        }
        try expect(fixture.callbacksWereOnMainThread, "Retry callbacks should run on the main thread")
    }

    static func testInvalidLoginURLReleasesRefresh() throws {
        let fixture = try Fixture("invalid-login-url")
        defer { fixture.close() }
        fixture.client.startLogin()
        fixture.client.refresh()
        try wait("login URL rejection and queued refresh") {
            fixture.loginStates.contains { if case .failed = $0 { return true }; return false }
                && !fixture.results.isEmpty
        }
        try expect(fixture.loginURLs.isEmpty, "A lookalike external login URL must never open")
        try expect(try success(fixture.results[0]).fiveHour?.usedPercent == 10.5,
                   "A terminal login failure must release the queued limits refresh")
        try expect(fixture.callbacksWereOnMainThread, "Login failure callbacks should run on the main thread")
    }

    static func testFailedLoginCompletionReleasesRefresh() throws {
        let fixture = try Fixture("login-failed")
        defer { fixture.close() }
        fixture.client.startLogin()
        fixture.client.refresh()
        try wait("failed login completion and queued refresh") {
            fixture.loginStates.contains { if case .failed = $0 { return true }; return false }
                && !fixture.results.isEmpty
        }
        try expect(fixture.loginURLs.count == 1, "The login should have reached the browser step")
        try expect(try success(fixture.results[0]).fiveHour?.usedPercent == 10.5,
                   "Failed login completion must release the queued limits refresh")
        try expect(fixture.callbacksWereOnMainThread, "Failed completion callbacks should run on the main thread")
    }

    static func testAccountChangeDiscardsStaleResponse() throws {
        let fixture = try Fixture("stale-account")
        defer { fixture.close() }
        fixture.client.refresh()
        try wait("new account's fresh limits") {
            fixture.results.contains {
                if case .success(let limits) = $0 { return limits.fiveHour?.usedPercent == 20.5 }
                return false
            }
        }
        try expect(fixture.accountChanges == 1, "The account change should notify the owner")
        try expect(fixture.results.count == 1, "The old account's in-flight response must never be published")
        try expect(try success(fixture.results[0]).fiveHour?.usedPercent == 20.5,
                   "The displayed limits should belong to the new account")
        try expect(fixture.callbacksWereOnMainThread, "Account switch callbacks should run on the main thread")
    }

    static func testWeeklyPrimaryWindow() throws {
        let fixture = try Fixture("weekly-primary")
        defer { fixture.close() }
        fixture.client.refresh()
        try wait("weekly-only primary response") { fixture.results.count == 1 }
        let limits = try success(fixture.results[0])
        try expect(limits.fiveHour == nil, "A weekly primary window must not appear as a five-hour quota")
        try expect(limits.weekly?.kind == .weekly && limits.weekly?.usedPercent == 65.75,
                   "The reported duration should determine the window kind")
        try expect(limits.weekly?.resetsAt == Date(timeIntervalSince1970: 1_800_600_000),
                   "Weekly primary reset should be retained")
    }

    static func testReversedWindowDurations() throws {
        let fixture = try Fixture("reversed-windows")
        defer { fixture.close() }
        fixture.client.refresh()
        try wait("reversed window response") { fixture.results.count == 1 }
        let limits = try success(fixture.results[0])
        try expect(limits.fiveHour?.kind == .fiveHour && limits.fiveHour?.usedPercent == 12.5,
                   "A 300-minute secondary window should appear as the five-hour quota")
        try expect(limits.weekly?.kind == .weekly && limits.weekly?.usedPercent == 65.75,
                   "A 10080-minute primary window should appear as the weekly quota")
        try expect(limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000)
                   && limits.weekly?.resetsAt == Date(timeIntervalSince1970: 1_800_600_000),
                   "Reset timestamps should remain attached to their original windows")
    }

    static func testLegacyWindowPositions() throws {
        let fixture = try Fixture("legacy-windows")
        defer { fixture.close() }
        fixture.client.refresh()
        try wait("legacy window response") { fixture.results.count == 1 }
        let limits = try success(fixture.results[0])
        try expect(limits.fiveHour?.kind == .fiveHour && limits.fiveHour?.usedPercent == 10.5,
                   "Legacy primary without a duration should retain the five-hour fallback")
        try expect(limits.weekly?.kind == .weekly && limits.weekly?.usedPercent == 42.25,
                   "Legacy secondary without a duration should retain the weekly fallback")
    }

    static func wait(_ description: String, timeout: TimeInterval = 4, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try expect(condition(), "Timed out waiting for \(description)")
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func success(_ result: Result<CodexLimitsResult, CodexServiceError>) throws -> CodexLimitsResult {
        switch result {
        case .success(let value): return value
        case .failure(let error): throw Failure(description: "Expected limits, received \(error.message)")
        }
    }

    static func failure(_ result: Result<CodexLimitsResult, CodexServiceError>) throws -> CodexServiceError {
        switch result {
        case .success: throw Failure(description: "Expected an error, received limits")
        case .failure(let error): return error
        }
    }
}
