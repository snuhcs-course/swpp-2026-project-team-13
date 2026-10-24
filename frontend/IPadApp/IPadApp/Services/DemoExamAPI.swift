import Foundation

// Durable mock backend. It never claims to recognize handwriting; every result is marked demo.
@MainActor final class DemoExamAPI: ExamAPI {
    let scope = "sori-local-demo-v1"
    let store: LocalStore
    let outcome: String
    init(outcome: String) throws { store = try LocalStore(scope: "demo-backend-v1"); self.outcome = outcome }
    func profile() async throws -> UserProfile {
        let url = store.root.appendingPathComponent("profile.json")
        if FileManager.default.fileExists(atPath: url.path) { return try ContractJSON.decoder().decode(UserProfile.self, from: Data(contentsOf: url)) }
        return try Bundled.decode("me")
    }
    func updateGoal(_ goal: String) async throws -> UserProfile {
        var value = try await profile(); value.learningGoal = goal
        try ContractJSON.encoder().encode(value).write(to: store.root.appendingPathComponent("profile.json"), options: .atomic); return value
    }
    func questions(page: Int) async throws -> QuestionPage { try Bundled.decode("questions") }
    func question(_ id: UUID) async throws -> Question { try Bundled.decode("question") }
    func createAttempt(question: Question, key: UUID) async throws -> Attempt {
        let path = store.root.appendingPathComponent("create-\(key).json")
        if FileManager.default.fileExists(atPath: path.path) { return try ContractJSON.decoder().decode(Attempt.self, from: Data(contentsOf: path)) }
        var attempt: Attempt = try Bundled.decode("attempt-ready")
        attempt.id = UUID(); attempt.question = question; attempt.createdAt = Date(); attempt.serverTime = Date()
        try store.save(SessionRecord(attempt: attempt))
        try ContractJSON.encoder().encode(attempt).write(to: path, options: .atomic); return attempt
    }
    func attempt(_ id: UUID) async throws -> Attempt { var a = try store.load(id).attempt; a.serverTime = Date(); return a }
    func start(_ id: UUID) async throws -> Attempt {
        var r = try store.load(id)
        if r.attempt.status == "ready" {
            r.attempt.status = "in_progress"; r.attempt.startedAt = Date()
            r.attempt.recommendedEndAt = Date().addingTimeInterval(Double(r.attempt.question.recommendedDurationSeconds)); try store.save(r)
        }
        return try await attempt(id)
    }
    func upload(_ id: UUID, png: Data, clientId: UUID, layout: String, key: UUID) async throws -> Answer {
        var r = try store.load(id)
        if let a = r.uploaded, a.clientAnswerId == clientId {
            guard a.sha256 == png.sha256 else { throw SORIError.configuration("ANSWER_ID_REUSED") }; return a
        }
        guard r.attempt.status == "in_progress" else { throw SORIError.configuration("ATTEMPT_ALREADY_SUBMITTED") }
        var a: Answer = try Bundled.decode("answer-upload")
        a.id = UUID(); a.attemptId = id; a.clientAnswerId = clientId; a.sheetLayoutId = layout; a.sha256 = png.sha256; a.sizeBytes = png.count; a.createdAt = Date()
        try store.write(png, name: "answer.png", id: id)
        r.uploaded = a; r.attempt.latestAnswer = a; try store.save(r); return a
    }
    func answerImage(_ answer: Answer) async throws -> Data { try store.read("answer.png", id: answer.attemptId) }
    func submit(_ id: UUID, answerId: UUID, key: UUID) async throws -> Grading {
        var r = try store.load(id)
        if let g = r.grading { guard g.answerId == answerId else { throw SORIError.configuration("ATTEMPT_ALREADY_SUBMITTED") }; return g }
        guard r.uploaded?.id == answerId else { throw SORIError.configuration("RESOURCE_NOT_FOUND") }
        r.attempt.status = "submitted"; r.attempt.submittedAnswerId = answerId; r.attempt.submittedAt = Date()
        var g: Grading = try Bundled.decode("grading-queued")
        g.attemptId = id; g.answerId = answerId; g.jobId = UUID(); g.createdAt = Date(); g.updatedAt = Date(); g.serverTime = Date()
        r.grading = g; try store.save(r); return g
    }
    func result(_ id: UUID) async throws -> Grading {
        var r = try store.load(id)
        guard let old = r.grading else { throw SORIError.configuration("NOT_SUBMITTED") }
        guard old.isPending else { return old }
        let name = Date().timeIntervalSince(old.createdAt) < 4 ? "grading-processing" : "grading-\(outcome)"
        var g: Grading = try Bundled.decode(name)
        g.attemptId = id; g.answerId = old.answerId; g.jobId = old.jobId; g.createdAt = old.createdAt; g.updatedAt = Date(); g.serverTime = Date()
        r.grading = g; try store.save(r); return g
    }
    func retryGrading(_ id: UUID, key: UUID) async throws -> Grading {
        var r = try store.load(id)
        if r.gradingRetryKey == key, let grading = r.grading { return grading }
        guard r.grading?.canRetry == true else { throw SORIError.configuration("GRADING_NOT_RETRYABLE") }
        var g: Grading = try Bundled.decode("grading-queued")
        g.attemptId = id; g.answerId = r.attempt.submittedAnswerId!; g.jobId = UUID(); g.createdAt = Date(); g.updatedAt = Date(); g.serverTime = Date()
        r.gradingRetryKey = key; r.grading = g; try store.save(r); return g
    }
    func asset(_ url: URL, authenticated: Bool, limit: Int) async throws -> Data {
        let data: Data
        if url.path.contains("/scores/main") { data = try Bundled.data("practice-01-main", ext: "mxl") }
        else if url.path.contains("/scores/scale") { data = try Bundled.data("practice-01-scale", ext: "mxl") }
        else { data = try Bundled.data("staff-8bars-v1", ext: "png") }
        guard data.count <= limit else { throw SORIError.storage("자산 용량 초과") }; return data
    }
}
