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

struct SignupAvailability: Codable, Equatable {
    var signupEnabled: Bool
}

// Guidance for the signup screen. The server's validation stays authoritative.
enum SignupRules {
    private static let usernameFormat = try! Regex("[a-z][a-z0-9_]{3,19}")
    static func usernameIsValid(_ value: String) -> Bool { value.wholeMatch(of: usernameFormat) != nil }
    static func displayNameIsValid(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard (1...20).contains(scalars.count), let first = scalars.first, let last = scalars.last,
              !first.properties.isWhitespace, !last.properties.isWhitespace else { return false }
        return !scalars.contains { scalar in
            scalar.properties.isBidiControl || [.control, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
        }
    }
    static func passwordLengthIsValid(_ value: String) -> Bool { (1...1024).contains(value.unicodeScalars.count) }
}
