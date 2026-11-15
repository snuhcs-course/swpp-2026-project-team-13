import Foundation

// Durable mock backend. It never claims to recognize handwriting; every result is marked demo.
@MainActor final class DemoExamAPI: ExamAPI {
    let scope: String
    let store: LocalStore
    let outcome: String
    init(outcome: String, storageScope: String? = nil) throws {
        scope = storageScope.map { "demo-client-"+$0 } ?? "sori-local-demo-v3"
        store = try LocalStore(scope:storageScope ?? "demo-backend-v3"); self.outcome = outcome
    }
    func profile() async throws -> UserProfile {
        let url = store.root.appendingPathComponent("profile.json")
        if FileManager.default.fileExists(atPath: url.path) { return try ContractJSON.decoder().decode(UserProfile.self, from: Data(contentsOf: url)) }
        return try Bundled.decode("me")
    }
    func updateGoal(_ goal: String) async throws -> UserProfile {
        var value = try await profile(); value.learningGoal = goal
        try ContractJSON.encoder().encode(value).write(to: store.root.appendingPathComponent("profile.json"), options: .atomic); return value
    }
    // The demo has no accounts, so nothing can be taken.
    func usernameCheck(_ username: String) async throws -> UsernameCheck { UsernameCheck(available: true) }
    private struct EngravingManifest: Decodable { var scores: [String: ImageEntry] }
    private struct ImageEntry: Decodable { var resource:String; var contentType:String; var sha256:String; var sizeBytes:Int; var pixelWidth:Int; var pixelHeight:Int; var renderer:String }
    private var cachedCatalog: [Question]?
    private struct DemoRating: Codable {
        var state = ExamRatingState()
        var offer: ExamOffer? = nil
        var changes: [String:ExamRatingChange] = [:]
    }
    private func ratingLedger() throws -> DemoRating {
        let url = store.root.appendingPathComponent("exam-rating-v1.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return DemoRating() }
        return try ContractJSON.decoder().decode(DemoRating.self,from:Data(contentsOf:url))
    }
    private func saveRating(_ ledger: DemoRating) throws {
        try ContractJSON.encoder().encode(ledger).write(to:store.root.appendingPathComponent("exam-rating-v1.json"),options:.atomic)
    }
    private func pools() throws -> QuestionPoolManifest { try Bundled.decode("question-pools") }
    private func activeExam() throws -> SessionRecord? {
        try store.all().last(where: { $0.blocksNewExam })
    }
    func examRecommendations() async throws -> ExamOffer {
        var ledger = try ratingLedger()
        if let active = try activeExam() {
            return ExamOffer(id:active.id,poolVersion:try pools().version,rating:ledger.state,choices:[],activeAttemptId:active.id)
        }
        let taken = Set(try store.all().map { $0.attempt.question.id })
        let pool = try pools()
        let candidates = try catalog().filter { pool.contains($0.id,in:"exam") && !taken.contains($0.id) }
        if let offer = ledger.offer, offer.choices.allSatisfy({ choice in
            choice.questionId == nil || candidates.contains(where: { $0.id == choice.questionId && $0.version == choice.questionVersion })
        }) { return offer }
        let offer = ExamOffer(id:UUID(),poolVersion:pool.version,rating:ledger.state,
            choices:ExamRatingModel.choices(rating:ledger.state.value,questions:candidates))
        try offer.validate(); ledger.offer = offer; try saveRating(ledger)
        return offer
    }
    private func withRating(_ grading: Grading, record: SessionRecord) throws -> Grading {
        guard record.attempt.studyMode == .exam, grading.status == "completed", let score = grading.score,
              let snapshot = record.attempt.examRatingSnapshot else { return grading }
        var ledger = try ratingLedger(), value = grading
        let id = record.id.uuidString.lowercased()
        if let existing = ledger.changes[id] { value.ratingChange = existing; return value }
        let change = try ExamRatingModel.update(ledger.state,difficulty:snapshot.difficultyScore,grade:score,
            difficultyVersion:snapshot.difficultyVersion,poolVersion:snapshot.poolVersion)
        ledger.changes[id] = change; ledger.state.value = change.after; ledger.state.completed += 1
        ledger.offer = nil; try saveRating(ledger)
        value.ratingChange = change; return value
    }
    private var difficultyManifest: PracticeDifficultyManifest?
    private var cachedEngraving: EngravingManifest?
    private func catalog() throws -> [Question] {
        if let cachedCatalog { return cachedCatalog }
        let practice: [Question] = try Bundled.decode("practice-catalog")
        let classical: [Question] = try Bundled.decode("classical-catalog")
        let brahms: [Question] = try Bundled.decode("brahms-catalog")
        let mahler: [Question] = try Bundled.decode("mahler-catalog")
        let additional: [Question] = try Bundled.decode("additional-practice-catalog")
        let bank: [Question] = try Bundled.decode("practice-bank-catalog")
        let difficulty: PracticeDifficultyManifest = try Bundled.decode("practice-difficulty")
        try difficulty.validate(); difficultyManifest = difficulty
        let revisions: [Question] = try Bundled.decode("sheet-revisions")
        let tempoRevisions: [Question] = try Bundled.decode("classical-tempo-revisions")
        let current = Dictionary(uniqueKeysWithValues:(revisions + tempoRevisions).map { ($0.id,$0) })
        let values = (practice + classical + brahms + mahler + additional + bank).map { current[$0.id] ?? $0 }
        let engraving: EngravingManifest = try Bundled.decode("engraving-manifest")
        cachedEngraving = engraving
        let resolved: [Question] = values.map { source in
            var q = source
            if let image = engraving.scores[q.scoreAssets.main.sha256] {
                q.correctScore = ReferenceImage(url:q.scoreAssets.main.url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("display",isDirectory:true),contentType:image.contentType,sha256:image.sha256,sizeBytes:image.sizeBytes,pixelWidth:image.pixelWidth,pixelHeight:image.pixelHeight,renderer:image.renderer)
            }
            q.tempo = q.tempo ?? TempoDefaults.setting(for:q.timeSignature); q.recommendedDurationSeconds = Int(ceil(PlaybackPlan.exam(meter:q.timeSignature,setting:q.tempo,scaleMeasures:q.scoreAssets.scale.measureCount).nominalDurationSeconds(meter:q.timeSignature))); return difficulty.annotating(q)
        }
        cachedCatalog = resolved; return resolved
    }
    func questions(page: Int) async throws -> QuestionPage {
        let pool = try pools()
        let completed = Set(try store.all().filter { $0.attempt.studyMode == .practice && $0.selfAssessment?.isCompleted == true }.map { $0.attempt.question.id })
        let values = try catalog().filter { $0.collection != "classical" && pool.contains($0.id,in:"practice") && difficultyManifest?.records[$0.id.uuidString.lowercased()] != nil }
        return QuestionPage(count: values.count, next: nil, previous: nil, results: values.map { q in QuestionSummary(id:q.id,version:q.version,title:q.title,source:q.source,keySignature:q.keySignature,timeSignature:q.timeSignature,measureCount:q.measureCount,recommendedDurationSeconds:q.recommendedDurationSeconds,tempo:q.tempo,difficulty:q.difficulty,practiceLevelNumber:q.practiceLevelNumber,difficultyScore:q.difficultyScore,difficultyVersion:q.difficultyVersion,practiceCompleted:completed.contains(q.id)) })
    }
    func classicalQuestions(page: Int) async throws -> QuestionPage {
        let order: [UUID] = try Bundled.decode("classical-question-order")
        let ranks = Dictionary(uniqueKeysWithValues:order.enumerated().map { ($0.element,$0.offset) })
        let values = try catalog().filter { $0.collection == "classical" }.sorted { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
        return QuestionPage(count:values.count,next:nil,previous:nil,results:values.map { q in
            QuestionSummary(id:q.id,version:q.version,title:q.title,source:q.source,keySignature:q.keySignature,timeSignature:q.timeSignature,measureCount:q.measureCount,recommendedDurationSeconds:q.recommendedDurationSeconds,tempo:q.tempo,collection:q.collection,composer:q.composer)
        })
    }
    func recommendedQuestion() async throws -> Question {
        let offer = try await examRecommendations()
        let choice = offer.choices.first(where: { $0.category == "matched" && $0.questionId != nil }) ?? offer.choices.first(where: { $0.questionId != nil })
        guard let id = choice?.questionId else { throw SolfegeError.configuration("아직 풀지 않은 시험 문제가 없습니다.") }
        return try await question(id)
    }
    func question(_ id: UUID) async throws -> Question {
        guard let q = try catalog().first(where: { $0.id == id }) else { throw SolfegeError.configuration("데모 문제를 찾을 수 없습니다.") }; return q
    }
    func createAttempt(question: Question, key: UUID) async throws -> Attempt {
        try await createAttempt(question:question,mode:.exam,key:key)
    }
    func createAttempt(question: Question, mode: StudyMode, key: UUID) async throws -> Attempt {
        let path = store.root.appendingPathComponent("create-\(key).json")
        if FileManager.default.fileExists(atPath: path.path) {
            let existing = try ContractJSON.decoder().decode(Attempt.self, from:Data(contentsOf:path))
            guard existing.question.id == question.id, existing.question.version == question.version, existing.studyMode == mode else { throw SolfegeError.configuration("IDEMPOTENCY_KEY_REUSED") }
            return existing
        }
        // Recover a crash between the durable reservation and its key receipt.
        if let record = try store.all().first(where: { $0.creationKey == key }) {
            guard record.attempt.question.id == question.id, record.attempt.question.version == question.version,
                  record.attempt.studyMode == mode else { throw SolfegeError.configuration("IDEMPOTENCY_KEY_REUSED") }
            try ContractJSON.encoder().encode(record.attempt).write(to:path,options:.atomic)
            return record.attempt
        }
        var attempt: Attempt = try Bundled.decode("attempt-ready")
        let pool = try pools()
        guard question.collection == "classical" && mode == .practice || pool.contains(question.id,in:mode.rawValue) else {
            throw SolfegeError.configuration("이 문제는 선택한 모드의 전용 문제가 아닙니다.")
        }
        if mode == .exam {
            guard !(try store.all()).contains(where: { $0.attempt.question.id == question.id }) else {
                let detail = ErrorDetail(code:"EXAM_QUESTION_ALREADY_SEEN",message:"이미 선택한 시험 문제입니다. 진행 중인 시험은 이어서 풀어 주세요.",fields:[],retryAfterMs:nil)
                throw SolfegeError.server(409,ErrorEnvelope(error:detail,requestId:UUID().uuidString),retryAfter:nil)
            }
            guard try activeExam() == nil else {
                let detail = ErrorDetail(code:"EXAM_ALREADY_ACTIVE",message:"진행 중인 시험이나 채점 결과를 먼저 확인해 주세요.",fields:[],retryAfterMs:nil)
                throw SolfegeError.server(409,ErrorEnvelope(error:detail,requestId:UUID().uuidString),retryAfter:nil)
            }
            guard let difficulty = question.difficultyScore, let version = question.difficultyVersion else {
                throw SolfegeError.configuration("시험 난이도 정보를 확인해 주세요.")
            }
            attempt.examRatingSnapshot = ExamRatingSnapshot(modelVersion:ExamRatingModel.version,poolVersion:pool.version,difficultyVersion:version,difficultyScore:difficulty)
        }
        attempt.playbackPlan = .exam(meter:question.timeSignature,setting:question.tempo,scaleMeasures:question.scoreAssets.scale.measureCount)
        attempt.id = UUID(); attempt.question = question; attempt.createdAt = Date(); attempt.serverTime = Date()
        attempt.mode = mode.rawValue; attempt.gradingMode = mode == .practice ? "self" : "demo"
        var record = SessionRecord(attempt:attempt); record.creationKey = key
        try store.save(record)
        try ContractJSON.encoder().encode(attempt).write(to: path, options: .atomic); return attempt
    }
    func attempt(_ id: UUID) async throws -> Attempt {
        var a = try store.load(id).attempt; a.serverTime = Date()
        if a.question.correctScore == nil,
           let current = try catalog().first(where: { $0.id == a.question.id && $0.scoreAssets.main.sha256 == a.question.scoreAssets.main.sha256 }) {
            a.question.correctScore = current.correctScore
        }
        return a
    }
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
            guard a.sha256 == png.sha256 else { throw SolfegeError.configuration("ANSWER_ID_REUSED") }; return a
        }
        guard r.attempt.status == "in_progress" else { throw SolfegeError.configuration("ATTEMPT_ALREADY_SUBMITTED") }
        var a: Answer = try Bundled.decode("answer-upload")
        a.id = UUID(); a.attemptId = id; a.clientAnswerId = clientId; a.sheetLayoutId = layout; a.sha256 = png.sha256; a.sizeBytes = png.count; a.createdAt = Date()
        try store.write(png, name: "answer.png", id: id)
        r.uploaded = a; r.attempt.latestAnswer = a; try store.save(r); return a
    }
    func answerImage(_ answer: Answer) async throws -> Data { try store.read("answer.png", id: answer.attemptId) }
    func submit(_ id: UUID, answerId: UUID, key: UUID) async throws -> Grading {
        var r = try store.load(id)
        guard r.attempt.studyMode == .exam else { throw SolfegeError.configuration("Practice는 자기채점으로 진행합니다.") }
        if let g = r.grading { guard g.answerId == answerId else { throw SolfegeError.configuration("ATTEMPT_ALREADY_SUBMITTED") }; return g }
        guard r.uploaded?.id == answerId else { throw SolfegeError.configuration("RESOURCE_NOT_FOUND") }
        r.attempt.status = "submitted"; r.attempt.submittedAnswerId = answerId; r.attempt.submittedAt = Date()
        var g: Grading = try Bundled.decode("grading-queued")
        g.attemptId = id; g.answerId = answerId; g.jobId = UUID(); g.createdAt = Date(); g.updatedAt = Date(); g.serverTime = Date()
        r.grading = g; try store.save(r); return g
    }
    func result(_ id: UUID) async throws -> Grading {
        var r = try store.load(id)
        guard let old = r.grading else { throw SolfegeError.configuration("NOT_SUBMITTED") }
        guard old.isPending else {
            let value = try withRating(old,record:r); r.grading = value; try store.save(r); return value
        }
        let name = Date().timeIntervalSince(old.createdAt) < 4 ? "grading-processing" : "grading-\(outcome)"
        var g: Grading = try Bundled.decode(name)
        g.attemptId = id; g.answerId = old.answerId; g.jobId = old.jobId; g.createdAt = old.createdAt; g.updatedAt = Date(); g.serverTime = Date()
        g = try withRating(g,record:r)
        r.grading = g; try store.save(r); return g
    }
    func retryGrading(_ id: UUID, key: UUID) async throws -> Grading {
        var r = try store.load(id)
        guard r.attempt.studyMode == .exam else { throw SolfegeError.configuration("Practice는 자기채점으로 진행합니다.") }
        if r.gradingRetryKey == key, let grading = r.grading { return grading }
        guard r.grading?.canRetry == true else { throw SolfegeError.configuration("GRADING_NOT_RETRYABLE") }
        var g: Grading = try Bundled.decode("grading-queued")
        g.attemptId = id; g.answerId = r.attempt.submittedAnswerId!; g.jobId = UUID(); g.createdAt = Date(); g.updatedAt = Date(); g.serverTime = Date()
        r.gradingRetryKey = key; r.grading = g; try store.save(r); return g
    }
    func submitPractice(_ id: UUID, answerId: UUID, key: UUID) async throws -> PracticeAssessment {
        var r = try store.load(id)
        guard r.attempt.studyMode == .practice else { throw SolfegeError.configuration("Exam은 AI 채점으로 진행합니다.") }
        if let existing = r.selfAssessment {
            guard existing.answerId == answerId else { throw SolfegeError.configuration("ATTEMPT_ALREADY_SUBMITTED") }
            return existing
        }
        guard r.attempt.status == "in_progress", r.uploaded?.id == answerId else { throw SolfegeError.configuration("답안을 먼저 업로드해 주세요.") }
        let now = Date()
        r.attempt.status = "submitted"; r.attempt.submittedAnswerId = answerId; r.attempt.submittedAt = now
        let review = try serializedReview(PracticeAssessment(attemptId:id,answerId:answerId,mode:"practice",gradingMode:"self",source:"self",
            featureAnalysisId:r.attempt.featureAnalysisId,status:"pending",revision:0,errors:[],completedAt:nil,updatedAt:now,serverTime:now))
        r.selfAssessment = review; r.grading = nil; try store.save(r)
        return review
    }
    func practiceAssessment(_ id: UUID) async throws -> PracticeAssessment {
        let r = try store.load(id)
        guard r.attempt.studyMode == .practice, r.attempt.status == "submitted", var review = r.selfAssessment else { throw SolfegeError.configuration("자기채점할 제출 답안이 없습니다.") }
        review.serverTime = Date()
        return review
    }
    private struct ReviewReceipt: Codable {
        var request: SelfAssessmentWrite
        var review: PracticeAssessment
    }
    private func serializedReview(_ review: PracticeAssessment) throws -> PracticeAssessment {
        try ContractJSON.decoder().decode(PracticeAssessment.self,from:ContractJSON.encoder().encode(review))
    }
    func saveSelfAssessment(_ id: UUID, request: SelfAssessmentWrite, key: UUID) async throws -> PracticeAssessment {
        var r = try store.load(id)
        guard r.attempt.studyMode == .practice, r.attempt.status == "submitted", let current = r.selfAssessment else { throw SolfegeError.configuration("자기채점할 제출 답안이 없습니다.") }
        guard request.expectedRevision >= 0 else { throw SolfegeError.configuration("자기채점 버전을 확인해 주세요.") }
        let normalized = SelfAssessmentWrite(expectedRevision:request.expectedRevision,
            errors:try SelfAssessmentEdits.normalized(request.errors,measureCount:r.attempt.question.measureCount),completed:request.completed)
        let name = "self-review-\(key.uuidString.lowercased()).json"
        if store.exists(name,id:id) {
            let receipt = try ContractJSON.decoder().decode(ReviewReceipt.self,from:store.read(name,id:id))
            guard receipt.request == normalized else { throw SolfegeError.configuration("IDEMPOTENCY_KEY_REUSED") }
            // A journal receipt is written before the head. Replay repairs a crash
            // between those two writes without replacing a later revision.
            if current.revision < receipt.review.revision { r.selfAssessment = receipt.review; try store.save(r) }
            return receipt.review
        }
        guard current.revision == request.expectedRevision else {
            let detail = ErrorDetail(code:"SELF_ASSESSMENT_REVISION_CONFLICT",message:"채점 기록이 변경됐습니다. 최신 기록을 확인해 주세요.",fields:[],retryAfterMs:nil)
            throw SolfegeError.server(409,ErrorEnvelope(error:detail,requestId:"demo-"+UUID().uuidString),retryAfter:nil)
        }
        var review = current
        review.revision += 1; review.errors = normalized.errors
        review.status = request.completed ? "completed" : "pending"
        review.updatedAt = Date(); review.serverTime = review.updatedAt
        review.completedAt = request.completed ? review.updatedAt : nil
        let receipt = ReviewReceipt(request:normalized,review:try serializedReview(review))
        try store.write(ContractJSON.encoder().encode(receipt),name:name,id:id)
        r.selfAssessment = receipt.review; try store.save(r)
        return receipt.review
    }
    func asset(_ url: URL, authenticated: Bool, limit: Int) async throws -> Data {
        let data: Data
        let values = try catalog()
        if let index = values.firstIndex(where: { url.path.lowercased().contains($0.id.uuidString.lowercased()) }) {
            // Foundation URL.path strips a trailing slash on Apple platforms.
            if url.lastPathComponent == "display" {
                let manifest = try cachedEngraving ?? Bundled.decode("engraving-manifest")
                guard let item = manifest.scores[values[index].scoreAssets.main.sha256] else { throw SolfegeError.configuration("정답 이미지가 없습니다.") }
                let image = try Bundled.data(item.resource,ext:"png")
                guard image.count <= limit else { throw SolfegeError.storage("정답 이미지 용량 초과") }
                return image
            }
            let kind = url.path.contains("/scores/scale") ? "scale" : "main"
            if values[index].collection == "classical" {
                data = try Bundled.data("classical-\(values[index].id.uuidString.lowercased())-\(kind)",ext:"mxl")
            } else if values[index].difficulty != nil {
                data = try Bundled.data("practice-\(values[index].id.uuidString.lowercased())-\(kind)",ext:"mxl")
            } else {
                let version = url.path.contains("/versions/1/") && index < 3 ? "" : "-v2"
                data = try Bundled.data("excerpt-\(index+1)\(version)-\(kind)", ext:"mxl")
            }
        } else if let q = values.first(where: { $0.sheetLayout.templatePngUrl == url }) {
            data = try Bundled.data(q.sheetLayout.id, ext:"png")
        } else if url.path.hasPrefix("/assets/sheets/") && SheetLayout.supports(url.deletingPathExtension().lastPathComponent) {
            // Previous immutable attempt snapshots may still need an old sheet.
            data = try Bundled.data(url.deletingPathExtension().lastPathComponent,ext:"png")
        } else { throw SolfegeError.configuration("데모 자산을 찾을 수 없습니다.") }
        guard data.count <= limit else { throw SolfegeError.storage("자산 용량 초과") }; return data
    }
}
