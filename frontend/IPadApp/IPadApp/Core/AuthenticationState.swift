import Foundation

struct LoginResponse: Codable {
    var accessToken: String
    var tokenType: String
    var user: UserProfile
}

struct AuthenticationTicket: Equatable {
    let origin: Origin
    let generation: UUID
}

// Every authentication operation has its own generation, even if the server
// returns the very same token. The app and HTTP transport share this guard.
@MainActor final class AuthenticationState {
    private(set) var ticket: AuthenticationTicket?
    private(set) var token: String?

    @discardableResult func begin(base: URL) -> AuthenticationTicket {
        let value = AuthenticationTicket(origin: Origin(base)!, generation: UUID())
        ticket = value; token = nil
        return value
    }
    func cancel() { ticket = nil; token = nil }
    func matches(_ value: AuthenticationTicket, token expected: String? = nil) -> Bool {
        ticket == value && (expected == nil || token == expected)
    }
    @discardableResult func accept(_ token: String, for value: AuthenticationTicket) -> Bool {
        guard matches(value) else { return false }
        self.token = token; return true
    }
    @discardableResult func invalidate(_ value: AuthenticationTicket, token: String) -> Bool {
        guard matches(value, token: token) else { return false }
        cancel(); return true
    }
}
