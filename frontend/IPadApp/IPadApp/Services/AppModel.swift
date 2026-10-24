import SwiftUI
import PencilKit

@MainActor final class AppModel: ObservableObject {
    enum Screen: String { case home, question, exam, result, history, settings }
    @Published var screen: Screen = .home
    @Published var profile: UserProfile?
    @Published var questions: [QuestionSummary] = []
    @Published var selectedQuestion: Question?
    @Published var session: SessionRecord?
    @Published var history: [SessionRecord] = []
    @Published var busy = false
    @Published var busyText = "준비 중"
    @Published var error: String?
    @Published var template: UIImage?
    @Published var submittedImage: UIImage?
    @Published var mainScore: MusicScore?
    @Published var prepared = false
    @Published var foreground = true
    @Published var connected = false
    @Published var drawingMissing = false
    @Published var page = 1
    @Published var hasNextPage = false
    @Published var waitingSince: Date?
    @Published var pollGeneration = UUID()
    @Published var demo: Bool
    @Published var server: String
    @Published var demoOutcome: String
    let drawing = DrawingController()
    let player = PianoPlayback()
    private var api: (any ExamAPI)?
    private var store: LocalStore?
    private var clock = AdvisoryClock()
    @Published private var saveFailed = false
    var isLocked: Bool { session?.frozen == true || session?.attempt.status != "in_progress" || drawingMissing || saveFailed }
    var remaining: Int { clock.remaining() }
    var pendingCreation: Bool { (try? store?.pending()) != nil }

    init() {
        let d = UserDefaults.standard
        demo = d.object(forKey: "sori.demo") as? Bool ?? true
        server = d.string(forKey: "sori.server") ?? Self.defaultServer
        demoOutcome = d.string(forKey: "sori.demoOutcome") ?? "completed"
        player.onCursor = { [weak self] cursor in
            guard let self, var record = session else { return }; record.cursor = cursor; try persist(record)
        }
        player.onError = { [weak self] error in self?.error = error.localizedDescription }
        drawing.onChange = { [weak self] value in self?.saveDrawing(value) }
    }
    static var defaultServer: String {
        let configured = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String ?? ""
        if configured.isEmpty { return "https://your-server.example/api/v1/" }
        return configured.hasSuffix("/api/v1/") ? configured : configured.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/"
    }
    func report(_ error: Error) {
        if error is CancellationError { return }
        self.error = error.localizedDescription
    }
    func run(_ label: String, operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; busyText = label
        defer { busy = false }
        do { try await operation() } catch { report(error) }
    }
    func connect(token: String? = nil) async {
        await run("학습 공간을 불러오는 중") {
            self.player.pause(); self.prepared = false; self.connected = false
            self.api = nil; self.store = nil; self.profile = nil; self.questions = []; self.history = []; self.session = nil
            let candidate: any ExamAPI
            if self.demo { candidate = try DemoExamAPI(outcome: self.demoOutcome) }
            else {
                guard let url = URL(string: self.server) else { throw SORIError.configuration("API 주소를 확인해 주세요.") }
                let value = try token ?? TokenVault.read(server: self.server)
                candidate = try HTTPExamAPI(base: url, token: value)
            }
            let user = try await candidate.profile()
            if !self.demo, let token { try TokenVault.save(token, server: self.server) }
            let local = try LocalStore(scope: candidate.scope + ":" + user.id.uuidString)
            let records = try local.all()
            let page = try await candidate.questions(page: 1)
            self.api = candidate; self.store = local; self.profile = user; self.history = records
            self.questions = page.results; self.page = 1; self.hasNextPage = page.next != nil
            self.session = nil; self.template = nil; self.submittedImage = nil; self.mainScore = nil
            self.connected = true; self.screen = .home
            let defaults = UserDefaults.standard
            defaults.set(self.demo, forKey: "sori.demo"); defaults.set(self.server, forKey: "sori.server"); defaults.set(self.demoOutcome, forKey: "sori.demoOutcome")
        }
    }
    func loadMore() async {
        await run("문제 목록을 불러오는 중") {
            guard let api = self.api else { return }
            let value = try await api.questions(page: self.page+1)
            self.questions.append(contentsOf: value.results.filter { q in !self.questions.contains(where: { $0.id == q.id }) })
            self.page += 1; self.hasNextPage = value.next != nil
        }
    }
    func updateGoal(_ goal: String) async {
        await run("목표를 저장하는 중") { guard let api = self.api else { return }; self.profile = try await api.updateGoal(goal) }
    }
    func choose(_ id: UUID) async {
        await run("문제 안내를 불러오는 중") {
            guard let api = self.api else { return }; let question = try await api.question(id)
            try question.validate(); self.selectedQuestion = question; self.screen = .question
        }
    }
    private func persist(_ record: SessionRecord) throws {
        guard let store else { throw SORIError.storage("로컬 저장소가 준비되지 않았습니다.") }
        try store.save(record); self.session = record; history = try store.all()
    }
    func begin() async {
        await run("새 연습을 준비하는 중") {
            guard let api = self.api, let store = self.store, let selected = self.selectedQuestion else { return }
            var pending = try store.pending() ?? PendingCreation(question: selected, key: UUID())
            try store.savePending(pending)
            let attempt: Attempt
            do { attempt = try await api.createAttempt(question: pending.question, key: pending.key) }
            catch let error as SORIError where error.code == "QUESTION_VERSION_MISMATCH" {
                let fresh = try await api.question(pending.question.id); try fresh.validate()
                pending = PendingCreation(question: fresh, key: UUID()); try store.savePending(pending)
                attempt = try await api.createAttempt(question: fresh, key: pending.key)
            }
            var record = SessionRecord(attempt: attempt)
            if store.exists("session.json", id: attempt.id) { record = try store.load(attempt.id); record.attempt = attempt }
            else { try store.write(PKDrawing().dataRepresentation(), name: "drawing.pkdrawing", id: attempt.id) }
            try self.persist(record); try store.savePending(nil)
            try await self.activate(record)
        }
    }
    func recoverPending() async {
        do { guard let pending = try store?.pending() else { return }; selectedQuestion = pending.question; await begin() } catch { report(error) }
    }
    func open(_ record: SessionRecord) async {
        await run("저장한 연습을 복구하는 중") {
            guard let api = self.api, let store = self.store else { return }
            var current = try store.load(record.id); current.attempt = try await api.attempt(record.id)
            try self.persist(current); try await self.activate(current)
        }
    }
    private func activate(_ record: SessionRecord) async throws {
        player.pause(); prepared = false; drawingMissing = false; saveFailed = false; mainScore = nil; submittedImage = nil; template = nil
        guard let store else { return }
        clock.sync(record.attempt)
        switch record.attempt.status {
        case "ready", "in_progress":
            screen = .exam
            if store.exists("drawing.pkdrawing", id: record.id) { drawing.load(try PKDrawing(data: store.read("drawing.pkdrawing", id: record.id))) }
            else { drawingMissing = true; drawing.load(PKDrawing()) }
            drawing.freeze(isLocked)
            try await prepareAssets()
        case "submitted": screen = .result; drawing.freeze(true); try await loadResult()
        default: throw SORIError.unsupported("지원하지 않는 응시 상태입니다: \(record.attempt.status)")
        }
    }
    private func cached(_ name: String, url: URL, authenticated: Bool, sha: String, limit: Int, id: UUID) async throws -> Data {
        guard let store, let api else { throw SORIError.storage("저장소가 준비되지 않았습니다.") }
        if store.exists(name, id: id) { let data = try store.read(name, id: id); if data.sha256 == sha { return data } }
        let data = try await api.asset(url, authenticated: authenticated, limit: limit)
        guard data.sha256 == sha else { throw SORIError.invalidScore("SCORE_HASH_MISMATCH: \(name) 파일의 해시가 다릅니다.") }
        try store.write(data, name: name, id: id); return data
    }
    private func prepareAssets() async throws {
        guard let record = session else { return }
        let q = record.attempt.question, plan = record.attempt.playbackPlan
        try q.validate(); try plan.validate()
        let imageData = try await cached("template.png", url: q.sheetLayout.templatePngUrl, authenticated: false, sha: q.sheetLayout.templateSha256, limit: 10_485_760, id: record.id)
        let mainData = try await cached("main.mxl", url: q.scoreAssets.main.url, authenticated: true, sha: q.scoreAssets.main.sha256, limit: 1_048_576, id: record.id)
        let scaleData = try await cached("scale.mxl", url: q.scoreAssets.scale.url, authenticated: true, sha: q.scoreAssets.scale.sha256, limit: 1_048_576, id: record.id)
        let main = try MusicXMLParser.parseMXL(mainData, asset: q.scoreAssets.main, tempo: plan.tempoBpm)
        let scale = try MusicXMLParser.parseMXL(scaleData, asset: q.scoreAssets.scale, tempo: plan.tempoBpm)
        guard main.timeSignature == q.timeSignature else { throw SORIError.invalidScore("문제 안내와 악보의 박자가 다릅니다.") }
        self.template = try AnswerExporter.validateTemplate(imageData, layout: q.sheetLayout); self.mainScore = main
        try player.prepare(main: main, scale: scale, plan: plan); player.restore(record.cursor)
        self.prepared = true
    }
    func retryPrepare() async { await run("악보와 피아노를 준비하는 중") { try await self.prepareAssets() } }
    func start() async {
        await run("연습을 시작하는 중") {
            guard self.prepared, let api = self.api, var record = self.session else { return }
            record.attempt = try await api.start(record.id); self.clock.sync(record.attempt); try self.persist(record)
            self.drawing.freeze(self.isLocked); self.player.resume()
        }
    }
    func saveDrawing(_ value: PKDrawing) {
        guard !isLocked, var record = session, let store else { return }
        do {
            try store.write(value.dataRepresentation(), name: "drawing.pkdrawing", id: record.id)
            record.hasDrawing = !value.strokes.isEmpty; try persist(record)
        } catch {
            saveFailed = true; drawing.freeze(true); player.pause(); self.error = "필기를 저장하지 못해 편집을 잠시 멈췄습니다. 저장 재시도로 복구해 주세요.\n" + error.localizedDescription
        }
    }
    func retryDrawingSave() {
        guard let store, var record = session else { return }
        do { try store.write(drawing.canvas.drawing.dataRepresentation(), name: "drawing.pkdrawing", id: record.id); record.hasDrawing = !drawing.canvas.drawing.strokes.isEmpty; try persist(record); saveFailed = false; drawing.freeze(isLocked) } catch { report(error) }
    }
    func submit() async {
        await run("답안을 안전하게 제출하는 중") {
            guard let api = self.api, let store = self.store, var record = self.session else { return }
            self.player.pause(); self.drawing.freeze(true)
            // Reconcile before any write: a timed-out submit may already have committed.
            record.attempt = try await api.attempt(record.id); try self.persist(record)
            if record.attempt.status == "submitted" { self.screen = .result; try await self.loadResult(); return }
            guard record.attempt.status == "in_progress", !self.drawingMissing, !self.saveFailed else { throw SORIError.storage("필기 원본과 응시 상태를 먼저 복구해 주세요.") }
            if !record.frozen {
                guard let template = self.template else { throw SORIError.storage("오선 템플릿이 준비되지 않았습니다.") }
                try store.write(self.drawing.canvas.drawing.dataRepresentation(), name: "drawing.pkdrawing", id: record.id)
                let png = try AnswerExporter.png(template: template, drawing: self.drawing.canvas.drawing, layout: record.attempt.question.sheetLayout)
                try store.write(png, name: "submission.png", id: record.id)
                record.clientAnswerId = UUID(); record.uploadKey = UUID(); record.submitKey = UUID(); record.frozen = true
                try self.persist(record)
            }
            let png = try store.read("submission.png", id: record.id)
            guard let client = record.clientAnswerId, let uploadKey = record.uploadKey, let submitKey = record.submitKey else { throw SORIError.storage("제출 복구 정보가 손상되었습니다.") }
            if record.uploaded == nil {
                let answer = try await api.upload(record.id, png: png, clientId: client, layout: record.attempt.question.sheetLayout.id, key: uploadKey)
                guard answer.attemptId == record.id, answer.clientAnswerId == client, answer.sha256 == png.sha256, answer.sizeBytes == png.count,
                      answer.imageWidth == 2660, answer.imageHeight == 1692, answer.answerFormatVersion == 1,
                      answer.sheetLayoutId == record.attempt.question.sheetLayout.id, answer.contentType == "image/png" else { throw SORIError.transport("서버의 업로드 영수증이 제출 파일과 다릅니다.") }
                record.uploaded = answer; try self.persist(record)
            }
            guard let answer = record.uploaded else { return }
            let grading = try await api.submit(record.id, answerId: answer.id, key: submitKey)
            guard grading.attemptId == record.id, grading.answerId == answer.id else { throw SORIError.transport("제출 결과의 답안 ID가 다릅니다.") }
            record.grading = grading; record.attempt = try await api.attempt(record.id); try self.persist(record)
            self.screen = .result; self.waitingSince = Date(); try await self.loadResult()
        }
        drawing.freeze(isLocked)
    }
    private func loadResult() async throws {
        guard let api, let store, var record = session else { return }
        let grading = try await api.result(record.id)
        guard grading.attemptId == record.id, grading.answerId == record.attempt.submittedAnswerId else { throw SORIError.transport("결과가 제출한 답안과 일치하지 않습니다.") }
        record.grading = grading; try persist(record)
        if grading.isPending && waitingSince == nil { waitingSince = Date() }
        if let answer = [record.uploaded, record.attempt.latestAnswer].compactMap({ $0 }).first(where: { $0.id == grading.answerId }) {
            if store.exists("submitted.png", id: record.id) {
                let data = try store.read("submitted.png", id: record.id)
                if data.sha256 == answer.sha256 { submittedImage = UIImage(data: data) }
            }
            if submittedImage == nil {
                let data = try await api.answerImage(answer)
                guard data.sha256 == answer.sha256, data.count == answer.sizeBytes, let image = UIImage(data: data), image.cgImage?.width == 2660, image.cgImage?.height == 1692 else { throw SORIError.transport("제출 이미지의 해시·크기가 일치하지 않습니다.") }
                try store.write(data, name: "submitted.png", id: record.id); submittedImage = image
            }
        } else {
            // latest_answer is not necessarily the submitted answer: address the pinned answer directly.
            if let id = record.attempt.submittedAnswerId {
                let url = record.attempt.question.scoreAssets.main.url
                guard let base = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = base.scheme, let host = base.host else { throw SORIError.transport("이미지 주소 오류") }
                var components = URLComponents(); components.scheme = scheme; components.host = host; components.port = base.port
                components.path = "/api/v1/attempts/\(record.id.uuidString.lowercased())/answers/\(id.uuidString.lowercased())/image/"
                let bytes = try await api.asset(components.url!, authenticated: true, limit: 10_485_760)
                guard let image = UIImage(data: bytes), image.cgImage?.width == 2660, image.cgImage?.height == 1692 else { throw SORIError.transport("제출 이미지 형식 오류") }; submittedImage = image
            }
        }
        if mainScore == nil {
            let asset = record.attempt.question.scoreAssets.main
            let data = try await cached("main.mxl", url: asset.url, authenticated: true, sha: asset.sha256, limit: 1_048_576, id: record.id)
            mainScore = try MusicXMLParser.parseMXL(data, asset: asset, tempo: record.attempt.playbackPlan.tempoBpm)
        }
    }
    func refreshResult() async { await run("결과를 확인하는 중") { try await self.loadResult() }; pollGeneration = UUID() }
    func poll() async {
        while !Task.isCancelled, foreground, screen == .result, session?.grading?.isPending == true {
            do {
                let ms = max(500, session?.grading?.pollAfterMs ?? 2000)
                try await Task.sleep(for: .milliseconds(ms)); try Task.checkCancellation()
                guard foreground, screen == .result else { return }
                try await loadResult()
            } catch is CancellationError { return }
            catch { report(error); return }
        }
    }
    func retryGrading() async {
        await run("채점을 다시 요청하는 중") {
            guard let api = self.api, var record = self.session, record.grading?.canRetry == true else { return }
            if record.gradingRetryKey == nil { record.gradingRetryKey = UUID(); try self.persist(record) }
            do {
                let grading = try await api.retryGrading(record.id, key: record.gradingRetryKey!)
                record.grading = grading; record.gradingRetryKey = nil; try self.persist(record)
            } catch let error as SORIError where ["GRADING_IN_PROGRESS", "GRADING_NOT_RETRYABLE"].contains(error.code ?? "") {
                record.gradingRetryKey = nil; try self.persist(record); try await self.loadResult()
            }
            self.waitingSince = Date(); self.pollGeneration = UUID()
        }
    }
    func background() { foreground = false; player.pause(); if !isLocked { saveDrawing(drawing.canvas.drawing) } }
    func foregroundAgain() async {
        foreground = true; pollGeneration = UUID()
        guard !busy, let record = session, screen == .exam || screen == .result else { return }
        // Explicit user input is still required to resume sound.
        await open(record)
    }
    func navigate(_ target: Screen) { if target != .exam { player.pause() }; screen = target }
}
