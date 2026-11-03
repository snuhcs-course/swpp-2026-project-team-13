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

struct UsernameCheck: Codable, Equatable {
    var available: Bool
}

// unknown: the server gave no clear answer. It never holds signup back; the signup's 409 has the final say.
enum UsernameStatus: Equatable { case available, taken, unknown }

// Guidance for the signup screen. The server's validation stays authoritative.
enum SignupRules {
    // How many fields after the username may open. A nil status means the check has not finished.
    static func reachableFields(username: String, status: UsernameStatus?, displayName: String, password: String) -> Int {
        guard usernameIsValid(username), let status, status != .taken else { return 0 }
        guard displayNameIsValid(displayName) else { return 1 }
        return passwordMeetsPolicy(password) ? 3 : 2
    }
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
    // The two policy rules that need no server: length and all digits. The server also refuses common passwords.
    static func passwordMeetsPolicy(_ value: String) -> Bool {
        (8...1024).contains(value.unicodeScalars.count) && !value.allSatisfy(\.isNumber)
    }

    enum Confirmation: Equatable { case pending, matches, differs }
    // Still typing the same password is not a mistake yet.
    static func confirmation(_ value: String, of password: String) -> Confirmation {
        if value.isEmpty { return .pending }
        if value == password { return .matches }
        return password.hasPrefix(value) ? .pending : .differs
    }

    enum UsernameIssue: Equatable { case empty, tooShort, tooLong, mustStartWithLowercase, invalidCharacter, none }
    static func usernameIssue(_ value: String) -> UsernameIssue {
        guard let first = value.unicodeScalars.first else { return .empty }
        if !("a"..."z").contains(first) { return .mustStartWithLowercase }
        if !value.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }) { return .invalidCharacter }
        if value.unicodeScalars.count > 20 { return .tooLong }
        return value.unicodeScalars.count < 4 ? .tooShort : .none
    }
}
