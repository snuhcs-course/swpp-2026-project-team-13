import XCTest
import PencilKit
@testable import IPadApp

final class AuthenticationAppProtocol: URLProtocol {
    static var handle: ((AuthenticationAppProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handle?(self) }
    override func stopLoading() { }
    func respond(_ status: Int, data: Data = Data(), json: Bool = true) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: json ? ["Content-Type": "application/json"] : [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor private final class AuthenticationFixture {
    let base = "https://login-\(UUID().uuidString.lowercased()).example/api/v1/"
    let user = UserProfile(id: UUID(), displayName: "첫 학습자", learningGoal: "other")
    let other = UserProfile(id: UUID(), displayName: "다른 학습자", learningGoal: "other")
    let http: URLSession
    let defaults = UserDefaults.standard.dictionaryRepresentation()
    var activeUser: UserProfile
    var rejectedQuestions = false
    var loginStatus = 200
    var loginCalls = 0
    var held: ((AuthenticationAppProtocol) -> Bool)?

    init() throws {
        activeUser = user
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthenticationAppProtocol.self]
        http = URLSession(configuration: config)
        try TokenVault.save("shared-token", server: base)
        AuthenticationAppProtocol.handle = { [unowned self] request in
            if self.held?(request) == true { return }
            let path = request.request.url!.path
            if path.contains("auth/login") {
                self.loginCalls += 1
                if self.loginStatus == 200 {
                    request.respond(200, data: try! ContractJSON.encoder().encode(LoginResponse(accessToken: "shared-token", tokenType: "Bearer", user: self.activeUser)))
                } else {
                    request.respond(self.loginStatus, data: self.failure(self.loginStatus == 429 ? "RATE_LIMITED" : "INVALID_CREDENTIALS", retry: self.loginStatus == 429 ? 1000 : nil))
                }
            } else if path.contains("auth/logout") { request.respond(204, json: false) }
            else if path.contains("/me") { request.respond(200, data: try! ContractJSON.encoder().encode(self.activeUser)) }
            else if path.contains("/questions") {
                request.respond(self.rejectedQuestions ? 401 : 200, data: self.rejectedQuestions ? self.failure("AUTHENTICATION_REQUIRED") : try! Bundled.data("questions", ext: "json"))
            } else { request.respond(404, data: self.failure("RESOURCE_NOT_FOUND")) }
        }
    }
    func failure(_ code: String, retry: Int? = nil) -> Data {
        try! ContractJSON.encoder().encode(ErrorEnvelope(error: ErrorDetail(code: code, message: "확인해 주세요.", fields: [], retryAfterMs: retry), requestId: "test-request"))
    }
    func model() -> AppModel {
        let value = AppModel(httpSession: http); value.demo = false; value.server = base; return value
    }
    func store(_ user: UserProfile) throws -> LocalStore { try LocalStore(scope: base + ":" + user.id.uuidString) }
    func cleanup() {
        AuthenticationAppProtocol.handle = nil; http.invalidateAndCancel()
        try? TokenVault.delete(server: base)
        for profile in [user, other] { if let local = try? store(profile) { try? FileManager.default.removeItem(at: local.root) } }
        for key in ["sori.demo", "sori.server", "sori.demoOutcome"] { UserDefaults.standard.set(defaults[key], forKey: key) }
    }
}

@MainActor final class AuthenticationIntegrationTests: XCTestCase {
    func testRelaunch401AndReloginPreserveDrawingAndSubmissionKeys() async throws {
        let fixture = try AuthenticationFixture(); defer { fixture.cleanup() }
        let local = try fixture.store(fixture.user)
        var saved = SessionRecord(attempt: try Bundled.decode("attempt-started"))
        saved.frozen = true; saved.clientAnswerId = UUID(); saved.uploadKey = UUID(); saved.submitKey = UUID()
        let bytes = PKDrawing().dataRepresentation()
        try local.write(bytes, name: "drawing.pkdrawing", id: saved.id); try local.save(saved)
        let model = fixture.model(); await model.connect()
        XCTAssertEqual(model.profile?.id, fixture.user.id); XCTAssertEqual(model.history.first?.uploadKey, saved.uploadKey)
        fixture.rejectedQuestions = true; await model.loadMore()
        XCTAssertNil(model.profile); XCTAssertTrue(model.history.isEmpty); XCTAssertFalse(model.connected)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "")
        XCTAssertEqual(try local.read("drawing.pkdrawing", id: saved.id), bytes)
        fixture.rejectedQuestions = false
        await model.login(username: "student01", password: "pw")
        let recovered = try XCTUnwrap(model.history.first)
        XCTAssertEqual(recovered.clientAnswerId, saved.clientAnswerId)
        XCTAssertEqual(recovered.uploadKey, saved.uploadKey); XCTAssertEqual(recovered.submitKey, saved.submitKey)
        XCTAssertTrue(recovered.frozen)
        let relaunched = fixture.model(); await relaunched.connect()
        XCTAssertEqual(relaunched.profile?.id, fixture.user.id); XCTAssertEqual(relaunched.history.first?.id, saved.id)
    }

    func testAccountSwitchHidesOtherRecordsAndLogoutAcceptsEmpty204() async throws {
        let fixture = try AuthenticationFixture(); defer { fixture.cleanup() }
        let local = try fixture.store(fixture.user)
        let saved = SessionRecord(attempt: try Bundled.decode("attempt-started")); try local.save(saved)
        let model = fixture.model(); await model.connect()
        XCTAssertEqual(model.history.count, 1)
        model.switchAccount(); XCTAssertNil(model.profile); XCTAssertTrue(model.history.isEmpty)
        fixture.activeUser = fixture.other
        await model.login(username: "other", password: "pw")
        XCTAssertEqual(model.profile?.id, fixture.other.id); XCTAssertTrue(model.history.isEmpty)
        await model.logout()
        XCTAssertNil(model.profile); XCTAssertFalse(model.authenticating)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "")
        fixture.activeUser = fixture.user
        await model.login(username: "student01", password: "pw")
        XCTAssertEqual(model.history.first?.id, saved.id)
    }

    func testLoginRateLimitNeedsExplicitRetryAndNetworkFailureRetainsToken() async throws {
        let fixture = try AuthenticationFixture(); defer { fixture.cleanup() }
        let model = fixture.model()
        fixture.loginStatus = 429
        await model.login(username: "student01", password: "pw")
        XCTAssertEqual(fixture.loginCalls, 1)
        XCTAssertNotNil(model.loginRetryUntil)
        await model.login(username: "student01", password: "pw")
        XCTAssertEqual(fixture.loginCalls, 1)
        try await Task.sleep(for: .milliseconds(1100))
        fixture.loginStatus = 200
        await model.login(username: "student01", password: "pw")
        XCTAssertEqual(fixture.loginCalls, 2); XCTAssertTrue(model.connected)
        fixture.held = { request in
            request.client?.urlProtocol(request, didFailWithError: URLError(.notConnectedToInternet))
            return true
        }
        await model.connect()
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "shared-token")
        XCTAssertFalse(model.connected)
    }

    func testLateProtected401CannotClearLaterLoginUsingSameToken() async throws {
        let fixture = try AuthenticationFixture(); defer { fixture.cleanup() }
        let model = fixture.model(); await model.connect()
        let started = expectation(description: "Old question request")
        var pending: AuthenticationAppProtocol?
        fixture.held = { request in
            if request.request.url!.path.contains("/questions") {
                pending = request; started.fulfill(); return true
            }
            return false
        }
        let old = Task { await model.loadMore() }
        await fulfillment(of: [started], timeout: 5)
        fixture.held = nil; fixture.activeUser = fixture.other
        await model.login(username: "other", password: "pw")
        try XCTUnwrap(pending).respond(401, data: fixture.failure("AUTHENTICATION_REQUIRED"))
        await old.value
        XCTAssertEqual(model.profile?.id, fixture.other.id); XCTAssertTrue(model.connected)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "shared-token")
    }

    func testLateLoginCannotOverwriteNewAccountEvenWhenTokenIsReused() async throws {
        let fixture = try AuthenticationFixture(); defer { fixture.cleanup() }
        let model = fixture.model()
        let started = expectation(description: "Old login")
        var pending: AuthenticationAppProtocol?
        fixture.held = { request in
            if request.request.url!.path.contains("auth/login") {
                pending = request; started.fulfill(); return true
            }
            return false
        }
        let old = Task { await model.login(username: "old", password: "pw") }
        await fulfillment(of: [started], timeout: 5)
        fixture.held = nil; fixture.activeUser = fixture.other
        await model.login(username: "other", password: "pw")
        let late = LoginResponse(accessToken: "shared-token", tokenType: "Bearer", user: fixture.user)
        try XCTUnwrap(pending).respond(200, data: ContractJSON.encoder().encode(late))
        await old.value
        XCTAssertEqual(model.profile?.id, fixture.other.id)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "shared-token")
    }

    func testLateLogoutAndProfileRecoveryCannotOverwriteNewLogin() async throws {
        for operation in ["logout", "restore"] {
            let fixture = try AuthenticationFixture(); defer { fixture.cleanup() }
            let model = fixture.model(); await model.connect()
            let started = expectation(description: operation)
            var pending: AuthenticationAppProtocol?
            fixture.held = { request in
                let path = request.request.url!.path
                if operation == "logout" ? path.contains("auth/logout") : path.contains("/me") {
                    pending = request; started.fulfill(); return true
                }
                return false
            }
            let old = Task { if operation == "logout" { await model.logout() } else { await model.connect() } }
            await fulfillment(of: [started], timeout: 5)
            fixture.held = nil; fixture.activeUser = fixture.other
            await model.login(username: "other", password: "pw")
            if operation == "logout" { try XCTUnwrap(pending).respond(204, json: false) }
            else { try XCTUnwrap(pending).respond(200, data: ContractJSON.encoder().encode(fixture.user)) }
            await old.value
            XCTAssertEqual(model.profile?.id, fixture.other.id); XCTAssertTrue(model.connected)
            XCTAssertEqual(try TokenVault.read(server: fixture.base), "shared-token")
        }
    }

    func testUnconfirmedLogoutRetainsTokenUntilExplicitLocalLogout() async throws {
        let fixture = try AuthenticationFixture(); defer { fixture.cleanup() }
        let model = fixture.model(); await model.connect()
        fixture.held = { request in
            if request.request.url!.path.contains("auth/logout") {
                request.respond(503, data: fixture.failure("UNAVAILABLE")); return true
            }
            return false
        }
        await model.logout()
        XCTAssertTrue(model.logoutNeedsConfirmation)
        XCTAssertEqual(model.profile?.id, fixture.user.id)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "shared-token")
        XCTAssertTrue(model.logoutFailure?.contains("서버 토큰이 남아") == true)
        model.localLogout()
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "")
        XCTAssertFalse(model.logoutNeedsConfirmation); XCTAssertNil(model.profile)
    }
}
