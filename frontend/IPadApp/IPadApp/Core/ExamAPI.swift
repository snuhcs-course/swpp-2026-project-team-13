import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor protocol ExamAPI {
    var scope: String { get }
    func profile() async throws -> UserProfile
    func updateGoal(_ goal: String) async throws -> UserProfile
    func questions(page: Int) async throws -> QuestionPage
    func classicalQuestions(page: Int) async throws -> QuestionPage
    func question(_ id: UUID) async throws -> Question
    func createAttempt(question: Question, key: UUID) async throws -> Attempt
    func attempt(_ id: UUID) async throws -> Attempt
    func start(_ id: UUID) async throws -> Attempt
    func upload(_ id: UUID, png: Data, clientId: UUID, layout: String, key: UUID) async throws -> Answer
    func answerImage(_ answer: Answer) async throws -> Data
    func submit(_ id: UUID, answerId: UUID, key: UUID) async throws -> Grading
    func result(_ id: UUID) async throws -> Grading
    func retryGrading(_ id: UUID, key: UUID) async throws -> Grading
    func asset(_ url: URL, authenticated: Bool, limit: Int) async throws -> Data
}

extension ExamAPI {
    func classicalQuestions(page: Int) async throws -> QuestionPage {
        QuestionPage(count:0,next:nil,previous:nil,results:[])
    }
}

extension Data {
    var sha256: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

struct Origin: Equatable {
    var scheme: String; var host: String; var port: Int
    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return nil }
        self.scheme = scheme; self.host = host; port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}

// Redirects are refused, including redirects of public templates. This also prevents bearer leakage.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class HTTPExamAPI: ExamAPI {
    let base: URL
    let token: String
    let session: URLSession
    let redirectDelegate = NoRedirectDelegate()
    var scope: String { base.absoluteString }
    init(base: URL, token: String, session: URLSession? = nil) throws {
        guard let origin = Origin(base), base.query == nil, base.fragment == nil,
              base.absoluteString.hasSuffix("/api/v1/"), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.contains("\r"), !token.contains("\n") else { throw SORIError.configuration("서버 주소는 /api/v1/로 끝나야 하며 개발 토큰이 필요합니다.") }
        #if !DEBUG
        guard origin.scheme == "https" else { throw SORIError.configuration("배포 앱은 HTTPS 서버가 필요합니다.") }
        #endif
        _ = origin
        self.base = base; self.token = token
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.ephemeral; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
            c.httpShouldSetCookies = false; c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: c)
        }
    }
    func endpoint(_ path: String) -> URL { base.appendingPathComponent(path) }
    func request(_ url: URL, method: String = "GET", authenticated: Bool = true, accept: String = "application/json", body: Data? = nil, contentType: String? = nil, key: UUID? = nil) throws -> URLRequest {
        guard let origin = Origin(url), origin.scheme == "https" || Origin(base)?.scheme == "http" else { throw SORIError.configuration("올바르지 않은 자산 주소입니다.") }
        if authenticated && origin != Origin(base) { throw SORIError.configuration("외부 서버에 인증 정보를 보낼 수 없습니다.") }
        var r = URLRequest(url: url); r.httpMethod = method; r.httpBody = body; r.timeoutInterval = contentType?.hasPrefix("multipart/") == true ? 60 : 15
        r.cachePolicy = .reloadIgnoringLocalCacheData; r.setValue(accept, forHTTPHeaderField: "Accept")
        if authenticated { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let key { r.setValue(key.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key") }
        return r
    }
    func execute(_ request: URLRequest, limit: Int) async throws -> Data {
        for trial in 0..<3 {
            do {
                let (bytes, rawResponse) = try await session.bytes(for: request, delegate: redirectDelegate)
                guard let response = rawResponse as? HTTPURLResponse else { throw SORIError.transport("잘못된 HTTP 응답입니다.") }
                let success = (200...299).contains(response.statusCode)
                let cap = success ? limit : 256 * 1024
                guard response.expectedContentLength <= cap else { throw SORIError.transport("서버 파일이 허용 용량을 초과했습니다.") }
                var data = Data(); data.reserveCapacity(min(cap, 64 * 1024))
                for try await byte in bytes {
                    guard data.count < cap else { throw SORIError.transport("서버 파일이 허용 용량을 초과했습니다.") }
                    data.append(byte)
                }
                if success {
                    let expected = request.value(forHTTPHeaderField: "Accept") ?? ""
                    let actual = response.mimeType?.lowercased() ?? ""
                    guard expected == actual else { throw SORIError.transport("서버의 콘텐츠 형식이 계약과 다릅니다. (\(actual))") }
                    return data
                }
                let envelope = try? ContractJSON.decoder().decode(ErrorEnvelope.self, from: data)
                let delay = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"), now: Date())
                throw SORIError.server(response.statusCode, envelope, retryAfter: delay)
            } catch {
                try Task.checkCancellation()
                let retry = Self.retryPolicy(error, trial: trial)
                guard trial < 2, let delay = retry else { throw error }
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw SORIError.transport("연결을 다시 확인해 주세요.")
    }
    static func retryDelay(_ header: String?, now: Date) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = Double(header), seconds.isFinite { return max(0, seconds) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return f.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }
    static func retryPolicy(_ error: Error, trial: Int) -> TimeInterval? {
        let backoff = pow(2, Double(trial)) + Double.random(in: 0...0.25)
        if case SORIError.server(let status, let e, let header) = error {
            guard status >= 500 || status == 429 || e?.error.code == "REQUEST_IN_PROGRESS" else { return nil }
            return max(backoff, max(header ?? 0, Double(e?.error.retryAfterMs ?? 0) / 1000))
        }
        if let urlError = error as? URLError, [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(urlError.code) { return backoff }
        return nil
    }
    func json<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, key: UUID? = nil) async throws -> T {
        let request = try request(endpoint(path), method: method, body: body, contentType: body == nil ? nil : "application/json", key: key)
        return try ContractJSON.decoder().decode(T.self, from: await execute(request, limit: 2 * 1024 * 1024))
    }
    func profile() async throws -> UserProfile { try await json("me/") }
    func updateGoal(_ goal: String) async throws -> UserProfile { try await json("me/", method: "PATCH", body: JSONSerialization.data(withJSONObject: ["learning_goal": goal])) }
    func questions(page: Int) async throws -> QuestionPage {
        try await questionPage(page:page)
    }
    func classicalQuestions(page: Int) async throws -> QuestionPage {
        try await questionPage(page:page,collection:"classical")
    }
    private func questionPage(page: Int, collection: String? = nil) async throws -> QuestionPage {
        var components = URLComponents(url: endpoint("questions/"), resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "page_size", value: "20")]
        if let collection { queryItems.append(URLQueryItem(name: "collection", value: collection)) }
        components.queryItems = queryItems
        let data = try await execute(request(components.url!), limit: 2 * 1024 * 1024)
        return try ContractJSON.decoder().decode(QuestionPage.self, from: data)
    }
    func question(_ id: UUID) async throws -> Question { try await json("questions/\(id.uuidString.lowercased())/") }
    func createAttempt(question: Question, key: UUID) async throws -> Attempt {
        try await json("attempts/", method: "POST", body: JSONSerialization.data(withJSONObject: ["question_id": question.id.uuidString.lowercased(), "question_version": question.version]), key: key)
    }
    func attempt(_ id: UUID) async throws -> Attempt { try await json("attempts/\(id.uuidString.lowercased())/") }
    func start(_ id: UUID) async throws -> Attempt { try await json("attempts/\(id.uuidString.lowercased())/start/", method: "POST") }
    static func multipart(png: Data, clientId: UUID, layout: String, boundary: String) throws -> Data {
        guard png.count <= 10 * 1024 * 1024, SheetLayout.supports(layout) else { throw SORIError.configuration("답안 이미지의 규격을 확인해 주세요.") }
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in [("client_answer_id", clientId.uuidString.lowercased()), ("answer_format_version", "1"), ("sheet_layout_id", layout)] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"answer.png\"\r\nContent-Type: image/png\r\n\r\n")
        body.append(png); append("\r\n--\(boundary)--\r\n")
        guard body.count <= 11 * 1024 * 1024 else { throw SORIError.configuration("답안 업로드 용량을 초과했습니다.") }; return body
    }
    func upload(_ id: UUID, png: Data, clientId: UUID, layout: String, key: UUID) async throws -> Answer {
        let boundary = "sori-" + key.uuidString
        let body = try Self.multipart(png: png, clientId: clientId, layout: layout, boundary: boundary)
        let request = try request(endpoint("attempts/\(id.uuidString.lowercased())/answers/"), method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)", key: key)
        return try ContractJSON.decoder().decode(Answer.self, from: await execute(request, limit: 256 * 1024))
    }
    func answerImage(_ answer: Answer) async throws -> Data { try await asset(answer.imageUrl, authenticated: true, limit: 10 * 1024 * 1024) }
    func submit(_ id: UUID, answerId: UUID, key: UUID) async throws -> Grading {
        try await json("attempts/\(id.uuidString.lowercased())/submit/", method: "POST", body: JSONSerialization.data(withJSONObject: ["answer_id": answerId.uuidString.lowercased()]), key: key)
    }
    func result(_ id: UUID) async throws -> Grading { try await json("attempts/\(id.uuidString.lowercased())/result/") }
    func retryGrading(_ id: UUID, key: UUID) async throws -> Grading { try await json("attempts/\(id.uuidString.lowercased())/grading-retries/", method: "POST", key: key) }
    func asset(_ url: URL, authenticated: Bool, limit: Int) async throws -> Data {
        let accept = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("/scores/main") || url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("/scores/scale") ? "application/vnd.recordare.musicxml" : "image/png"
        return try await execute(request(url, authenticated: authenticated, accept: accept), limit: limit)
    }
}
