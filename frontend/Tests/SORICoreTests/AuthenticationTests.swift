import XCTest
import Foundation
@testable import SORICore

final class DelayedAuthProtocol: URLProtocol {
    static var started: ((DelayedAuthProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started?(self) }
    override func stopLoading() { }
    func complete(status: Int, body: Data = Data(), mime: String? = nil) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: mime.map { ["Content-Type": $0] } ?? [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor final class AuthenticationTests: XCTestCase {
    let base = URL(string: "https://api.sori.example/api/v1/")!
    let user = UserProfile(id: UUID(), displayName: "학습자", learningGoal: "other")

    func client(delayed: Bool = false, token: String = "") throws -> HTTPExamAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = delayed ? [DelayedAuthProtocol.self] : [StubProtocol.self]
        return try HTTPExamAPI(base: base, token: token, session: URLSession(configuration: config))
    }
    func errorData(_ code: String, retry: Int? = nil) throws -> Data {
        try ContractJSON.encoder().encode(ErrorEnvelope(error: ErrorDetail(code: code, message: "오류", fields: [], retryAfterMs: retry), requestId: "request"))
    }
    func testLoginSendsExactCredentialsWithoutBearerOrIdempotencyKey() async throws {
        let response = LoginResponse(accessToken: "opaque-token", tokenType: "Bearer", user: user)
        let data = try ContractJSON.encoder().encode(response)
        let api = try client(token: "stale-token")
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/login")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body: Data
            if let bytes = request.httpBody { body = bytes }
            else {
                let stream = try XCTUnwrap(request.httpBodyStream); stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = stream.read(&bytes, maxLength: bytes.count); body = Data(bytes.prefix(max(0, count)))
            }
            let fields = try JSONSerialization.jsonObject(with: body) as? [String: String]
            XCTAssertEqual(fields, ["username": " Student01 ", "password": " password \n"])
            return (200, "application/json", data)
        }
        defer { StubProtocol.handler = nil }
        let actual = try await api.login(username: " Student01 ", password: " password \n")
        XCTAssertEqual(actual.accessToken, "opaque-token"); XCTAssertEqual(actual.user, user)
    }
    func testLoginNeverAutomaticallyRetriesRateLimitServerOrNetworkFailures() async throws {
        for status in [429, 503, 401, 0] {
            let api = try client()
            var calls = 0
            let data = try errorData(status == 429 ? "RATE_LIMITED" : "INVALID_CREDENTIALS", retry: status == 429 ? 9000 : nil)
            StubProtocol.handler = { _ in
                calls += 1
                if status == 0 { throw URLError(.timedOut) }
                return (status, "application/json", data)
            }
            do { _ = try await api.login(username: "u", password: "p"); XCTFail("Expected failure") }
            catch { XCTAssertEqual(calls, 1) }
        }
        StubProtocol.handler = nil
    }
    func testLogoutAccepts204WithoutBodyOrContentType() async throws {
        let api = try client(token: "token")
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/logout")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
            return (204, nil, Data())
        }
        defer { StubProtocol.handler = nil }
        try await api.logout()
    }
    func testLogoutRejectsUnexpectedSuccessStatus() async throws {
        let api = try client(token: "token")
        StubProtocol.handler = { _ in (200, "application/json", Data("{}".utf8)) }
        defer { StubProtocol.handler = nil }
        do { try await api.logout(); XCTFail("Revocation requires 204") }
        catch { XCTAssertTrue(error is SORIError) }
    }
    func testCurrent401InvalidatesOnlyTheMatchingToken() async throws {
        let state = AuthenticationState(), ticket = state.begin(base: base)
        state.accept("current", for: ticket)
        let api = try client(token: "current")
        api.isCurrent = { state.matches(ticket, token: "current") }
        api.onUnauthorized = { state.invalidate(ticket, token: "current") }
        let data = try errorData("AUTHENTICATION_REQUIRED")
        StubProtocol.handler = { _ in (401, "application/json", data) }
        defer { StubProtocol.handler = nil }
        do { _ = try await api.profile(); XCTFail("Expected 401") } catch { }
        XCTAssertNil(state.ticket); XCTAssertNil(state.token)
    }
    func testGenerationRejectsLateLoginLogoutMeAnd401EvenWithSameToken() async throws {
        for operation in ["login", "logout", "me", "401"] {
            let state = AuthenticationState(), old = state.begin(base: base)
            state.accept("same-token", for: old)
            let api = try client(delayed: true, token: "same-token")
            api.isCurrent = { state.matches(old) }
            api.onUnauthorized = { XCTFail("Stale 401 reached app"); state.invalidate(old, token: "same-token") }
            let started = expectation(description: operation)
            var pending: DelayedAuthProtocol?
            DelayedAuthProtocol.started = { pending = $0; started.fulfill() }
            let request = Task { @MainActor in
                do {
                    if operation == "login" { _ = try await api.login(username: "old", password: "pw") }
                    else if operation == "logout" { try await api.logout() }
                    else { _ = try await api.profile() }
                    XCTFail("Stale response was accepted")
                } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
            }
            await fulfillment(of: [started], timeout: 5)
            let fresh = state.begin(base: base); state.accept("same-token", for: fresh)
            let data: Data
            if operation == "login" { data = try ContractJSON.encoder().encode(LoginResponse(accessToken: "old-token", tokenType: "Bearer", user: user)) }
            else if operation == "401" { data = try errorData("AUTHENTICATION_REQUIRED") }
            else { data = try ContractJSON.encoder().encode(user) }
            try XCTUnwrap(pending).complete(status: operation == "logout" ? 204 : operation == "401" ? 401 : 200, body: operation == "logout" ? Data() : data, mime: operation == "logout" ? nil : "application/json")
            await request.value
            XCTAssertTrue(state.matches(fresh, token: "same-token"))
            XCTAssertFalse(state.accept("late-token", for: old))
            XCTAssertFalse(state.invalidate(old, token: "same-token"))
        }
        DelayedAuthProtocol.started = nil
    }
    func testCancelAndServerSwitchInvalidatePendingAuthentication() {
        let state = AuthenticationState(), ticket = state.begin(base: base)
        state.cancel()
        XCTAssertFalse(state.accept("cancelled", for: ticket))
        let second = state.begin(base: base)
        let third = state.begin(base: URL(string: "https://another.example/api/v1/")!)
        XCTAssertFalse(state.accept("old-server", for: second))
        XCTAssertTrue(state.accept("new-server", for: third))
        XCTAssertEqual(Origin(URL(string: "https://API.SORI.EXAMPLE:443/api/v1/")!)?.key, Origin(base)?.key)
    }
}
