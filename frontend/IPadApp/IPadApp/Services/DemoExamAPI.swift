import Foundation

// Durable mock backend. It never claims to recognize handwriting; every result is marked demo.
@MainActor final class DemoExamAPI: ExamAPI {
    let scope = "sori-local-demo-v3"
    let store: LocalStore
    let outcome: String
    init(outcome: String) throws { store = try LocalStore(scope: "demo-backend-v3"); self.outcome = outcome }
    func profile() async throws -> UserProfile {
        let url = store.root.appendingPathComponent("profile.json")
        if FileManager.default.fileExists(atPath: url.path) { return try ContractJSON.decoder().decode(UserProfile.self, from: Data(contentsOf: url)) }
        return try Bundled.decode("me")
    }
    func updateGoal(_ goal: String) async throws -> UserProfile {
        var value = try await profile(); value.learningGoal = goal
        try ContractJSON.encoder().encode(value).write(to: store.root.appendingPathComponent("profile.json"), options: .atomic); return value
    }
    private func catalog() throws -> [Question] {
        let values: [Question] = try Bundled.decode("practice-catalog")
        return values.map { source in
            var q = source; q.tempo = TempoDefaults.setting(for:q.timeSignature); q.recommendedDurationSeconds = Int(ceil(PlaybackPlan.exam(meter:q.timeSignature,setting:q.tempo,scaleMeasures:q.scoreAssets.scale.measureCount).nominalDurationSeconds(meter:q.timeSignature))); return q
        }
    }
    func questions(page: Int) async throws -> QuestionPage {
        let values = try catalog()
        return QuestionPage(count: values.count, next: nil, previous: nil, results: values.map { q in QuestionSummary(id:q.id,version:q.version,title:q.title,source:q.source,keySignature:q.keySignature,timeSignature:q.timeSignature,measureCount:q.measureCount,recommendedDurationSeconds:q.recommendedDurationSeconds) })
    }
    func question(_ id: UUID) async throws -> Question {
        guard let q = try catalog().first(where: { $0.id == id }) else { throw SORIError.configuration("데모 문제를 찾을 수 없습니다.") }; return q
    }
    func createAttempt(question: Question, key: UUID) async throws -> Attempt {
        let path = store.root.appendingPathComponent("create-\(key).json")
        if FileManager.default.fileExists(atPath: path.path) { return try ContractJSON.decoder().decode(Attempt.self, from: Data(contentsOf: path)) }
        var attempt: Attempt = try Bundled.decode("attempt-ready")
        attempt.playbackPlan = .exam(meter:question.timeSignature,setting:question.tempo,scaleMeasures:question.scoreAssets.scale.measureCount)
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
        let values = try catalog()
        if let index = values.firstIndex(where: { url.path.lowercased().contains($0.id.uuidString.lowercased()) }) {
            let kind = url.path.contains("/scores/scale") ? "scale" : "main"
            let version = url.path.contains("/versions/2/") ? "-v2" : ""
            data = try Bundled.data("excerpt-\(index+1)\(version)-\(kind)", ext:"mxl")
        } else if let q = values.first(where: { $0.sheetLayout.templatePngUrl == url }) {
            data = try Bundled.data(q.sheetLayout.id, ext:"png")
        } else { throw SORIError.configuration("데모 자산을 찾을 수 없습니다.") }
        guard data.count <= limit else { throw SORIError.storage("자산 용량 초과") }; return data
    }
}
