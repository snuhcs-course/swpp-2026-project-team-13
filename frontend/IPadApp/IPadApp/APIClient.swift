import Foundation

struct HealthResponse: Decodable {
    let status: String
}

enum APIError: LocalizedError {
    case missingBaseURL
    case httpStatus(Int)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "API 주소를 설정해 주세요."
        case .httpStatus(let code):
            return "서버가 HTTP \(code)로 응답했습니다."
        case .unexpectedResponse:
            return "서버 응답을 확인해 주세요."
        }
    }
}

struct APIClient {
    func checkHealth() async throws -> HealthResponse {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
              let baseURL = URL(string: value),
              let host = baseURL.host, !host.isEmpty,
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? "") else {
            throw APIError.missingBaseURL
        }
        let url = baseURL.appendingPathComponent("api/health/")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw APIError.unexpectedResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.httpStatus(response.statusCode)
        }
        let health = try JSONDecoder().decode(HealthResponse.self, from: data)
        guard health.status == "ok" else {
            throw APIError.unexpectedResponse
        }
        return health
    }
}
