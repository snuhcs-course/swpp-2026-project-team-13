import XCTest
import PencilKit
@testable import IPadApp

@MainActor private final class DeletionFixture {
    let base = "https://delete-\(UUID().uuidString.lowercased()).example/api/v1/"
    let user = UserProfile(id: UUID(), displayName: "삭제할 학습자", learningGoal: "other")
    let other = UserProfile(id: UUID(), displayName: "다른 학습자", learningGoal: "other")
    let http: URLSession
    let defaults = UserDefaults.standard.dictionaryRepresentation()
    // Each deletion takes the next outcome and the last one repeats.
    var outcomes: [(AuthenticationAppProtocol) -> Void]
    var deleteCalls = 0
    var held: ((AuthenticationAppProtocol) -> Bool)?
    var activeUser: UserProfile

    init() throws {
        activeUser = user
        outcomes = [{ $0.respond(204, json: false) }]
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthenticationAppProtocol.self]
        http = URLSession(configuration: config)
        try TokenVault.save("delete-token", server: base)
        AuthenticationAppProtocol.handle = { [unowned self] request in
            let path = request.request.url!.path
            if request.request.httpMethod == "DELETE", path.contains("/me") {
                self.deleteCalls += 1
                if self.held?(request) == true { return }
                let outcome = self.outcomes.count > 1 ? self.outcomes.removeFirst() : self.outcomes[0]
                outcome(request)
            } else if path.contains("auth/login") {
                request.respond(200, data: try! ContractJSON.encoder().encode(LoginResponse(accessToken: "new-token", tokenType: "Bearer", user: self.activeUser)))
            } else if path.contains("/me") { request.respond(200, data: try! ContractJSON.encoder().encode(self.activeUser)) }
            else if path.contains("/questions") { request.respond(200, data: try! Bundled.data("questions", ext: "json")) }
            else { request.respond(404, data: self.failure("RESOURCE_NOT_FOUND")) }
        }
    }
    func failure(_ code: String) -> Data {
        try! ContractJSON.encoder().encode(ErrorEnvelope(error: ErrorDetail(code: code, message: "서버 메시지", fields: [], retryAfterMs: nil), requestId: "test-request"))
    }
    func model() -> AppModel {
        let value = AppModel(httpSession: http); value.demo = false; value.server = base; return value
    }
    func store(_ profile: UserProfile) throws -> LocalStore { try LocalStore(scope: Origin(URL(string: base)!)!.key + "/api/v1/:" + profile.id.uuidString) }
    func seeded(_ profile: UserProfile) throws -> (LocalStore, SessionRecord) {
        let local = try store(profile)
        let saved = SessionRecord(attempt: try Bundled.decode("attempt-started"))
        try local.save(saved); try local.write(PKDrawing().dataRepresentation(), name: "drawing.pkdrawing", id: saved.id)
        return (local, saved)
    }
    func cleanup() {
        AuthenticationAppProtocol.handle = nil; http.invalidateAndCancel()
        try? TokenVault.delete(server: base)
        for profile in [user, other] { if let local = try? store(profile) { try? FileManager.default.removeItem(at: local.root) } }
        for key in ["sori.demo", "sori.server", "sori.demoOutcome"] { UserDefaults.standard.set(defaults[key], forKey: key) }
    }
}

@MainActor final class AccountDeletionIntegrationTests: XCTestCase {
    private func exists(_ local: LocalStore) -> Bool { FileManager.default.fileExists(atPath: local.root.path) }

    func testSuccessRemovesTokenAndOnlyThisAccountsRecordsThenShowsLogin() async throws {
        let fixture = try DeletionFixture(); defer { fixture.cleanup() }
        let (local, _) = try fixture.seeded(fixture.user)
        let (otherLocal, otherSaved) = try fixture.seeded(fixture.other)
        let model = fixture.model(); await model.connect()
        XCTAssertEqual(model.history.count, 1)
        await model.deleteAccount()
        XCTAssertEqual(fixture.deleteCalls, 1)
        XCTAssertNil(model.profile); XCTAssertFalse(model.connected); XCTAssertFalse(model.authenticating)
        XCTAssertTrue(model.history.isEmpty); XCTAssertNil(model.error)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "")
        XCTAssertFalse(exists(local))
        XCTAssertEqual(try otherLocal.load(otherSaved.id).id, otherSaved.id)
        // A relaunch must land on login rather than restoring anything.
        let relaunched = fixture.model(); await relaunched.connect()
        XCTAssertNil(relaunched.profile); XCTAssertFalse(relaunched.connected)
    }

    func testOpenSessionDrawingIsNotSavedBackAfterDeletion() async throws {
        let fixture = try DeletionFixture(); defer { fixture.cleanup() }
        let (local, saved) = try fixture.seeded(fixture.user)
        let model = fixture.model(); await model.connect()
        model.session = saved; model.drawingMissing = false
        XCTAssertFalse(model.isLocked, "The session must be writable for this test to mean anything")
        await model.deleteAccount()
        XCTAssertNil(model.session); XCTAssertFalse(exists(local))
    }

    func testAdminRefusalKeepsTokenRecordsAndSession() async throws {
        let fixture = try DeletionFixture(); defer { fixture.cleanup() }
        let (local, saved) = try fixture.seeded(fixture.user)
        fixture.outcomes = [{ [unowned fixture] in $0.respond(403, data: fixture.failure("ACCOUNT_DELETION_NOT_ALLOWED")) }]
        let model = fixture.model(); await model.connect()
        await model.deleteAccount()
        XCTAssertEqual(model.error, "관리자 계정은 앱에서 삭제할 수 없어요.")
        XCTAssertEqual(model.profile?.id, fixture.user.id); XCTAssertTrue(model.connected); XCTAssertFalse(model.authenticating)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "delete-token")
        XCTAssertEqual(try local.load(saved.id).id, saved.id)
        // The operation must leave a working client behind.
        model.error = nil; await model.loadMore()
        XCTAssertTrue(model.connected)
    }

    func testUnreadableProxy403IsNotTreatedAsTheAdminRefusal() async throws {
        let fixture = try DeletionFixture(); defer { fixture.cleanup() }
        fixture.outcomes = [{ $0.respond(403, data: Data("<html>blocked</html>".utf8), json: false) }]
        let model = fixture.model(); await model.connect()
        await model.deleteAccount()
        let message = try XCTUnwrap(model.error)
        XCTAssertTrue(message.hasPrefix("계정이 삭제됐는지 확인하지 못했어요"), message)
        XCTAssertEqual(model.profile?.id, fixture.user.id)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "delete-token")
    }

    func testServerAndNetworkFailuresKeepEverythingAndAreNotResent() async throws {
        let failures: [(AuthenticationAppProtocol) -> Void] = [
            { $0.respond(503, data: Data("<html>down</html>".utf8), json: false) },
            { $0.respond(500, data: Data("{}".utf8)) },
            { $0.client?.urlProtocol($0, didFailWithError: URLError(.networkConnectionLost)) },
            { $0.client?.urlProtocol($0, didFailWithError: URLError(.timedOut)) },
        ]
        for failure in failures {
            let fixture = try DeletionFixture(); defer { fixture.cleanup() }
            let (local, saved) = try fixture.seeded(fixture.user)
            fixture.outcomes = [failure]
            let model = fixture.model(); await model.connect()
            await model.deleteAccount()
            XCTAssertEqual(fixture.deleteCalls, 1)
            XCTAssertTrue(model.error?.hasPrefix("계정이 삭제됐는지 확인하지 못했어요") == true, model.error ?? "no error")
            XCTAssertEqual(model.profile?.id, fixture.user.id); XCTAssertTrue(model.connected)
            XCTAssertEqual(try TokenVault.read(server: fixture.base), "delete-token")
            XCTAssertEqual(try local.load(saved.id).id, saved.id)
        }
    }

    func testRetryAfterLostResponseGets401KeepsRecordsAndExplains() async throws {
        let fixture = try DeletionFixture(); defer { fixture.cleanup() }
        let (local, saved) = try fixture.seeded(fixture.user)
        fixture.outcomes = [
            { $0.client?.urlProtocol($0, didFailWithError: URLError(.networkConnectionLost)) },
            { [unowned fixture] in $0.respond(401, data: fixture.failure("AUTHENTICATION_REQUIRED")) },
        ]
        let model = fixture.model(); await model.connect()
        await model.deleteAccount()
        XCTAssertTrue(model.connected)
        await model.deleteAccount()
        XCTAssertEqual(fixture.deleteCalls, 2)
        XCTAssertNil(model.profile); XCTAssertFalse(model.connected); XCTAssertFalse(model.authenticating)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "")
        XCTAssertEqual(model.error, "계정이 이미 삭제됐거나 다른 기기에서 로그아웃했을 수 있어요. 같은 아이디로 다시 로그인되면 계정이 남아 있는 거예요.")
        XCTAssertEqual(try local.load(saved.id).id, saved.id)
    }

    func testLateDeletionResponseCannotTouchANewLogin() async throws {
        let fixture = try DeletionFixture(); defer { fixture.cleanup() }
        let (local, saved) = try fixture.seeded(fixture.user)
        let started = expectation(description: "deletion sent")
        var pending: AuthenticationAppProtocol?
        fixture.held = { pending = $0; started.fulfill(); return true }
        let model = fixture.model(); await model.connect()
        let deletion = Task { await model.deleteAccount() }
        await fulfillment(of: [started], timeout: 5)
        fixture.activeUser = fixture.other
        await model.login(username: "other", password: "pw")
        XCTAssertEqual(model.profile?.id, fixture.other.id)
        pending?.respond(204, json: false)
        await deletion.value
        XCTAssertEqual(model.profile?.id, fixture.other.id); XCTAssertTrue(model.connected); XCTAssertNil(model.error)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "new-token")
        XCTAssertEqual(try local.load(saved.id).id, saved.id, "A stale 204 must not remove records")
    }

    func testFailureToRemoveLocalRecordsStillEndsTheSessionAndSaysSo() async throws {
        let fixture = try DeletionFixture(); defer { fixture.cleanup() }
        let (local, _) = try fixture.seeded(fixture.user)
        let model = fixture.model(); await model.connect()
        // Removing the directory first makes the app's own removal fail.
        try FileManager.default.removeItem(at: local.root)
        await model.deleteAccount()
        XCTAssertNil(model.profile); XCTAssertFalse(model.connected)
        XCTAssertEqual(try TokenVault.read(server: fixture.base), "")
        XCTAssertEqual(model.error, "계정은 삭제했지만 이 기기에 저장된 정보 일부를 지우지 못했어요.")
    }

    func testSameAccountCanSignInAgainWithNoOldRecordsAfterDeletion() async throws {
        let fixture = try DeletionFixture(); defer { fixture.cleanup() }
        _ = try fixture.seeded(fixture.user)
        let model = fixture.model(); await model.connect()
        await model.deleteAccount()
        await model.login(username: "student01", password: "pw")
        XCTAssertEqual(model.profile?.id, fixture.user.id); XCTAssertTrue(model.history.isEmpty); XCTAssertNil(model.error)
    }
}
