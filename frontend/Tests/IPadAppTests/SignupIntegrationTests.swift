import XCTest
@testable import IPadApp

@MainActor private final class SignupFixture {
    let base = "https://signup-\(UUID().uuidString.lowercased()).example/api/v1/"
    let user = UserProfile(id: UUID(), displayName: "청음 연습생", learningGoal: "college_entrance")
    let http: URLSession
    let defaults = UserDefaults.standard.dictionaryRepresentation()
    // nil means success. Each signup takes the next outcome and the last one repeats.
    var outcomes: [(status: Int, code: String, fields: [FieldError], retry: Int?)?] = [nil]
    var availability: (status: Int, body: String) = (200, "{\"signup_enabled\": true}")
    var html = false
    var dropConnection = false
    var signupCalls = 0
    var loginCalls = 0
    var availabilityCalls = 0
    var lastAuthorization: String?
    var held: ((AuthenticationAppProtocol) -> Bool)?

    init() {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthenticationAppProtocol.self]
        http = URLSession(configuration: config)
        AuthenticationAppProtocol.handle = { [unowned self] request in
            let path = request.request.url!.path
            if path.contains("auth/signup-availability") {
                self.availabilityCalls += 1
                self.lastAuthorization = request.request.value(forHTTPHeaderField: "Authorization")
                if self.held?(request) == true { return }
                request.respond(self.availability.status, data: Data(self.availability.body.utf8))
            } else if path.contains("auth/signup") {
                self.signupCalls += 1
                self.lastAuthorization = request.request.value(forHTTPHeaderField: "Authorization")
                if self.held?(request) == true { return }
                if self.dropConnection {
                    request.client?.urlProtocol(request, didFailWithError: URLError(.networkConnectionLost)); return
                }
                let outcome = self.outcomes.count > 1 ? self.outcomes.removeFirst() : self.outcomes[0]
                if let outcome {
                    if self.html { request.respond(outcome.status, data: Data("<html>proxy</html>".utf8), json: false); return }
                    request.respond(outcome.status, data: self.failure(outcome.code, fields: outcome.fields, retry: outcome.retry))
                } else {
                    request.respond(201, data: self.success)
                }
            } else if path.contains("auth/login") { self.loginCalls += 1; request.respond(401, data: self.failure("INVALID_CREDENTIALS")) }
            else if path.contains("/me") { request.respond(200, data: try! ContractJSON.encoder().encode(self.user)) }
            else if path.contains("/questions") { request.respond(200, data: try! Bundled.data("questions", ext: "json")) }
            else { request.respond(404, data: self.failure("RESOURCE_NOT_FOUND")) }
        }
    }
    var success: Data { try! ContractJSON.encoder().encode(LoginResponse(accessToken: "signup-token", tokenType: "Bearer", user: user)) }
    func failure(_ code: String, fields: [FieldError] = [], retry: Int? = nil) -> Data {
        try! ContractJSON.encoder().encode(ErrorEnvelope(error: ErrorDetail(code: code, message: "확인해 주세요.", fields: fields, retryAfterMs: retry), requestId: "test-request"))
    }
    func model() -> AppModel {
        let value = AppModel(httpSession: http); value.demo = false; value.server = base; return value
    }
    func cleanup() {
        AuthenticationAppProtocol.handle = nil; http.invalidateAndCancel()
        try? TokenVault.delete(server: base)
        if let local = try? LocalStore(scope: Origin(URL(string: base)!)!.key + "/api/v1/:" + user.id.uuidString) { try? FileManager.default.removeItem(at: local.root) }
        for key in ["sori.demo", "sori.server", "sori.demoOutcome"] { UserDefaults.standard.set(defaults[key], forKey: key) }
    }
}

@MainActor final class SignupIntegrationTests: XCTestCase {
    private func signup(_ model: AppModel, username: String = "student01") async {
        await model.signup(username: username, displayName: "청음 연습생", learningGoal: "college_entrance", password: "quiet-lantern-48")
    }

    func testSuccessStoresTokenLinksLocalRecordsAndSurvivesRelaunch() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        let local = try LocalStore(scope: Origin(URL(string: fixture.base)!)!.key + "/api/v1/:" + fixture.user.id.uuidString)
        let saved = SessionRecord(attempt: try Bundled.decode("attempt-started")); try local.save(saved)
        let model = fixture.model(); model.openSignup()
        await signup(model)
        XCTAssertTrue(model.connected); XCTAssertFalse(model.showingSignup); XCTAssertFalse(model.authenticating)
        XCTAssertEqual(model.profile, fixture.user)
        XCTAssertEqual(model.history.first?.id, saved.id)
        XCTAssertEqual(model.screen, .home)
        XCTAssertNil(model.error)
        XCTAssertNil(fixture.lastAuthorization)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "signup-token")
        XCTAssertEqual(fixture.loginCalls, 0)
        let relaunched = fixture.model(); await relaunched.connect()
        XCTAssertEqual(relaunched.profile, fixture.user); XCTAssertEqual(relaunched.history.first?.id, saved.id)
    }

    func testPasswordIsNeverStoredLocally() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        let model = fixture.model(); await signup(model)
        XCTAssertNotEqual(try TokenVault.read(server: fixture.base), "quiet-lantern-48")
        XCTAssertFalse(UserDefaults.standard.dictionaryRepresentation().values.contains { "\($0)".contains("quiet-lantern-48") })
    }

    func testCancelledSignupIgnoresTheLateResponseButRemembersTheUnknownOutcome() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        var pending: AuthenticationAppProtocol?
        let started = expectation(description: "signup started")
        fixture.held = { request in pending = request; started.fulfill(); return true }
        let model = fixture.model(); model.openSignup()
        let task = Task { await signup(model) }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(model.authenticating)
        model.cancelLogin()
        XCTAssertFalse(model.authenticating); XCTAssertTrue(model.showingSignup)
        try XCTUnwrap(pending).respond(201, data: fixture.success)
        await task.value
        XCTAssertFalse(model.connected); XCTAssertNil(model.profile)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "")
        fixture.held = nil
        fixture.outcomes = [(409, "USERNAME_TAKEN", [FieldError(field: "username", code: "taken", message: "이미 사용 중")], nil)]
        await signup(model)
        XCTAssertEqual(model.loginPrefill, "student01"); XCTAssertFalse(model.showingSignup)
    }

    func testAStartedNewSignupWinsOverAnOlderOne() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        var first: AuthenticationAppProtocol?
        let started = expectation(description: "first signup")
        fixture.held = { request in
            guard first == nil else { return false }
            first = request; started.fulfill(); return true
        }
        let model = fixture.model()
        let older = Task { await signup(model, username: "older_user") }
        await fulfillment(of: [started], timeout: 5)
        await signup(model, username: "newer_user")
        XCTAssertTrue(model.connected)
        try XCTUnwrap(first).respond(409, data: fixture.failure("USERNAME_TAKEN", fields: [FieldError(field: "username", code: "taken", message: "늦은 응답")]))
        await older.value
        XCTAssertTrue(model.connected); XCTAssertTrue(model.signupFieldErrors.isEmpty); XCTAssertNil(model.error)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "signup-token")
    }

    func testFailuresAreNeverResentAutomatically() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        for outcome in [(429, "RATE_LIMITED"), (500, "INTERNAL"), (503, "UNAVAILABLE"), (400, "VALIDATION_ERROR"), (409, "USERNAME_TAKEN"), (403, "SIGNUP_DISABLED")] {
            fixture.signupCalls = 0
            fixture.outcomes = [(outcome.0, outcome.1, [], outcome.0 == 429 ? 1000 : nil)]
            let model = fixture.model()
            await signup(model, username: "user_\(outcome.0)")
            XCTAssertEqual(fixture.signupCalls, 1, outcome.1)
            XCTAssertFalse(model.connected)
        }
        fixture.signupCalls = 0; fixture.dropConnection = true
        let model = fixture.model(); await signup(model)
        XCTAssertEqual(fixture.signupCalls, 1); XCTAssertEqual(fixture.loginCalls, 0)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "")
    }

    func testRetryAfterLostResponseThat409sSuggestsLoginWithoutTryingIt() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        let model = fixture.model(); model.openSignup()
        fixture.dropConnection = true
        await signup(model)
        XCTAssertNotNil(model.error); XCTAssertTrue(model.showingSignup); XCTAssertNil(model.loginPrefill)
        fixture.dropConnection = false; model.error = nil
        fixture.outcomes = [(409, "USERNAME_TAKEN", [FieldError(field: "username", code: "taken", message: "이미 사용 중")], nil)]
        await signup(model)
        XCTAssertEqual(model.loginPrefill, "student01"); XCTAssertFalse(model.showingSignup)
        XCTAssertTrue(try XCTUnwrap(model.error).contains("로그인"))
        XCTAssertEqual(fixture.loginCalls, 0)
        XCTAssertFalse(model.connected)
    }

    func testRetryAfterServerErrorAlsoCountsAsLostResponse() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        let model = fixture.model(); model.openSignup()
        fixture.outcomes = [(500, "INTERNAL", [], nil), (409, "USERNAME_TAKEN", [], nil)]
        await signup(model)
        XCTAssertNil(model.loginPrefill)
        await signup(model)
        XCTAssertEqual(model.loginPrefill, "student01"); XCTAssertFalse(model.showingSignup)
    }

    func testPlainConflictStaysOnTheFormWithAFieldError() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        let model = fixture.model(); model.openSignup()
        fixture.outcomes = [(409, "USERNAME_TAKEN", [FieldError(field: "username", code: "taken", message: "이미 사용 중인 아이디입니다.")], nil)]
        await signup(model)
        XCTAssertTrue(model.showingSignup); XCTAssertNil(model.loginPrefill); XCTAssertNil(model.error)
        XCTAssertEqual(model.signupFieldErrors.map(\.code), ["taken"])
        model.clearSignupError("username")
        XCTAssertTrue(model.signupFieldErrors.isEmpty)
    }

    func testConflictOnADifferentUsernameIsNotTreatedAsLostResponse() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        let model = fixture.model(); model.openSignup()
        fixture.dropConnection = true
        await signup(model, username: "first_try")
        fixture.dropConnection = false
        fixture.outcomes = [(409, "USERNAME_TAKEN", [FieldError(field: "username", code: "taken", message: "x")], nil)]
        await signup(model, username: "second_try")
        XCTAssertTrue(model.showingSignup); XCTAssertNil(model.loginPrefill)
    }

    func testValidationKeepsEveryPasswordError() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        let codes = ["password_too_short", "password_too_common", "password_entirely_numeric"]
        fixture.outcomes = [(400, "VALIDATION_ERROR", codes.map { FieldError(field: "password", code: $0, message: $0) }, nil)]
        let model = fixture.model(); model.openSignup()
        await signup(model)
        XCTAssertEqual(model.signupFieldErrors.map(\.code), codes)
        XCTAssertNil(model.error); XCTAssertTrue(model.showingSignup)
    }

    func testRateLimitBlocksResendUntilTheWaitPasses() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        fixture.outcomes = [(429, "RATE_LIMITED", [], 60000)]
        let model = fixture.model(); model.openSignup()
        await signup(model)
        let deadline = try XCTUnwrap(model.signupRetryUntil)
        XCTAssertEqual(deadline.timeIntervalSinceNow, 60, accuracy: 3)
        XCTAssertNil(model.loginPrefill)
        await signup(model)
        XCTAssertEqual(fixture.signupCalls, 1)
        // Signup's wait is separate from login's.
        XCTAssertNil(model.loginRetryUntil)
    }

    func testRetryAfterLostResponseThat429sShowsWaitAndSuggestsLogin() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        let model = fixture.model(); model.openSignup()
        fixture.dropConnection = true
        await signup(model)
        fixture.dropConnection = false; model.error = nil
        fixture.outcomes = [(429, "RATE_LIMITED", [], 120000)]
        await signup(model)
        let message = try XCTUnwrap(model.error)
        XCTAssertTrue(message.contains("120초"), message); XCTAssertTrue(message.contains("로그인"), message)
        XCTAssertEqual(model.loginPrefill, "student01")
        XCTAssertNotNil(model.signupRetryUntil); XCTAssertEqual(fixture.loginCalls, 0)
    }

    func testDisabled403HidesTheEntryAndReturnsToLogin() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        fixture.outcomes = [(403, "SIGNUP_DISABLED", [], nil)]
        let model = fixture.model(); model.openSignup()
        await signup(model)
        XCTAssertFalse(model.signupEnabled); XCTAssertFalse(model.showingSignup); XCTAssertNotNil(model.error)
    }

    func testUndecodableProxyErrorsDoNotBranchOnCodeOrChangeAuthentication() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        fixture.html = true
        for status in [403, 409, 502] {
            fixture.outcomes = [(status, "", [], nil)]
            let model = fixture.model(); model.openSignup()
            await signup(model)
            XCTAssertTrue(model.signupEnabled); XCTAssertTrue(model.showingSignup, "\(status)")
            XCTAssertTrue(model.signupFieldErrors.isEmpty); XCTAssertNil(model.loginPrefill)
            XCTAssertTrue(try XCTUnwrap(model.error).contains("HTTP \(status)"))
            XCTAssertEqual(try TokenVault.read(server: fixture.base), "")
        }
    }

    func testUndecodable429StillWaitsBeforeResending() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        fixture.html = true; fixture.outcomes = [(429, "", [], nil)]
        let model = fixture.model(); model.openSignup()
        await signup(model)
        XCTAssertNotNil(model.signupRetryUntil); XCTAssertTrue(model.showingSignup)
    }

    func testAvailabilityControlsTheEntryAndFailuresKeepItVisible() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        let model = fixture.model()
        fixture.availability = (200, "{\"signup_enabled\": false}")
        await model.refreshSignupAvailability()
        XCTAssertFalse(model.signupEnabled)
        XCTAssertNil(fixture.lastAuthorization)
        fixture.availability = (200, "{\"signup_enabled\": true, \"extra\": 1}")
        await model.refreshSignupAvailability()
        XCTAssertTrue(model.signupEnabled)
        for failure in [(500, "<html/>"), (503, "{}"), (200, "not json"), (200, "{}")] {
            model.signupEnabled = false
            fixture.availability = failure
            await model.refreshSignupAvailability()
            XCTAssertTrue(model.signupEnabled, "\(failure)")
        }
    }

    func testAvailabilityIsNotAppliedAfterTheServerChanged() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        var pending: AuthenticationAppProtocol?
        let started = expectation(description: "lookup started")
        fixture.held = { request in pending = request; started.fulfill(); return true }
        let model = fixture.model()
        let lookup = Task { await model.refreshSignupAvailability() }
        await fulfillment(of: [started], timeout: 5)
        model.server = "https://another-\(UUID().uuidString.lowercased()).example/api/v1/"
        try XCTUnwrap(pending).respond(200, data: Data("{\"signup_enabled\": false}".utf8))
        await lookup.value
        XCTAssertTrue(model.signupEnabled)
    }

    func testLongAdminDisplayNameIsAccepted() async throws {
        let fixture = SignupFixture(); defer { fixture.cleanup() }
        let name = String(repeating: "가", count: 80)
        let data = try ContractJSON.encoder().encode(UserProfile(id: fixture.user.id, displayName: name, learningGoal: "other"))
        XCTAssertEqual(try ContractJSON.decoder().decode(UserProfile.self, from: data).displayName, name)
    }
}
