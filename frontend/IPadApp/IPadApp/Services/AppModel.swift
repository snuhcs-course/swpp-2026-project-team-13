import SwiftUI
import PencilKit

@MainActor final class AppModel: ObservableObject {
    enum Screen: String { case main, home, practiceLevels, practiceQuestions, recommendingExam, examSelection, question, exam, result, history, settings, minigames, classical }
    @Published var screen: Screen = .main
    @Published var profile: UserProfile?
    @Published var questions: [QuestionSummary] = []
    // Each level has its own keys and meters, so a filter never carries over to another level.
    @Published var selectedPracticeLevel: PracticeLevel? { didSet { if oldValue != selectedPracticeLevel { practiceFilter = QuestionFilter() } } }
    @Published var practiceFilter = QuestionFilter()
    // Held until the attempt exists, so backing out cannot re-roll the question.
    private var recommendedExam: Question?
    @Published var examOffer: ExamOffer?
    @Published var classicalQuestions: [QuestionSummary] = []
    @Published var classicalLoaded = false
    @Published var classicalHasNextPage = false
    private var classicalPage = 0
    @Published var selectedComposer: String?
    @Published var selectedQuestion: Question?
    @Published var selectedMode: StudyMode = .practice
    @Published var session: SessionRecord?
    @Published var history: [SessionRecord] = []
    @Published private(set) var practiceResumeId: UUID?
    @Published var busy = false
    @Published var busyText = "준비 중"
    @Published var error: String?
    @Published var template: UIImage?
    @Published var submittedImage: UIImage?
    @Published var correctScoreImage: UIImage?
    @Published var correctScoreError: String?
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
    @Published var authenticating = false
    @Published var loginRetryUntil: Date?
    @Published var loginMessage: String?
    @Published var showingSignup = false
    @Published var signupEnabled = true
    @Published var signupRetryUntil: Date?
    @Published var signupFieldErrors: [FieldError] = []
    @Published private var checkedUsername: (server: String, username: String, status: UsernameStatus)?
    @Published var loginPrefill: String?
    @Published var logoutNeedsConfirmation = false
    @Published var logoutFailure: String?
    @Published private(set) var instrumentVoices: [InstrumentVoice] = []
    @Published private(set) var selectedVoice = "grand-piano"
    let drawing = DrawingController()
    let player = PianoPlayback()
    private var api: (any ExamAPI)?
    private let authentication = AuthenticationState()
    var rhythmConnection: RhythmConnection? {
        guard connected, !authenticating, let api, let profile, let ticket = authentication.ticket else { return nil }
        return RhythmConnection(api:api,profileId:profile.id,demo:demo,generation:ticket.generation)
    }
    private let httpSession: URLSession?
    private let demoScope: String?
    private var operationGeneration = UUID()
    private var loginDeadlines: [String: Date] = [:]
    private var signupDeadlines: [String: Date] = [:]
    private var usernameCheckDeadlines: [String: Date] = [:]
    // A signup whose outcome is unknown: it may have created the account.
    private var uncertainSignup: (origin: String, username: String)?
    private var pendingLocalLogout: (base: URL, token: String, ticket: AuthenticationTicket)?
    // A login without "로그인 상태 유지" lives only for this launch, but settings can still reconnect with it.
    private var sessionOnlyToken: (origin: String, token: String)?
    private static let accountUsedKey = "sori.accountUsed"
    private var store: LocalStore?
    private var clock = AdvisoryClock()
    @Published private var saveFailed = false
    var isLocked: Bool { !connected || authenticating || session?.frozen == true || session?.attempt.status != "in_progress" || drawingMissing || saveFailed }
    var remaining: Int { clock.remaining() }
    var pendingCreation: Bool { (try? store?.pending()) != nil }
    var pendingPracticeCreation: Bool { (try? store?.pending())?.studyMode == .practice }
    var needsAuthentication: Bool { !demo && !connected }
    var needsGoalSelection: Bool { connected && profile != nil && profile?.learningGoal == nil }
    // Exam uses a dedicated pool and a three-choice screen instead of a library.
    var libraryScreen: Screen { selectedMode == .practice ? .home : .examSelection }
    // Classical stays Practice-only; legacy exam attempts remain resumable.
    var questionLibraryScreen: Screen {
        guard selectedMode == .practice else { return libraryScreen }
        return selectedQuestion?.collection == "classical" ? .classical : .practiceQuestions
    }
    var resultLibraryScreen: Screen { session?.attempt.studyMode != .practice ? .main : session?.attempt.question.collection == "classical" ? .classical : .home }
    var canChooseNextExam: Bool {
        session?.attempt.studyMode == .exam && session?.attempt.status == "submitted" && session?.grading?.status == "completed"
    }
    func isUnfinished(_ record: SessionRecord) -> Bool {
        record.attempt.studyMode == .practice ? record.canResumePractice : record.attempt.status != "submitted"
    }
    var resumablePractice: SessionRecord? {
        history.first { $0.id == practiceResumeId && $0.canResumePractice }
    }
    func canOpenHistoryRecord(_ record: SessionRecord) -> Bool {
        !record.canResumePractice || record.id == practiceResumeId
    }
    func selectPracticeLevel(_ level: PracticeLevel) {
        selectedPracticeLevel = level
        navigate(.practiceQuestions)
    }
    var practiceErrors: [MeasureError] { session?.practiceEdits ?? session?.selfAssessment?.errors ?? [] }
    var practiceHasConflict: Bool {
        guard let base = session?.practiceBaseRevision, let current = session?.selfAssessment?.revision else { return false }
        return base != current
    }
    var practiceComparisonReady: Bool {
        submittedImage != nil && (correctScoreImage != nil || (session?.attempt.question.correctScore == nil && mainScore != nil))
    }

    init(httpSession: URLSession? = nil, demoScope: String? = nil) {
        self.httpSession = httpSession; self.demoScope = demoScope
        let d = UserDefaults.standard
        // First launch starts at signup; a build with no server has only the demo to offer.
        demo = d.object(forKey: "sori.demo") as? Bool ?? !Self.hasConfiguredServer
        let savedServer = d.string(forKey: "sori.server") ?? Self.defaultServer
        server = savedServer
        demoOutcome = d.string(forKey: "sori.demoOutcome") ?? "completed"
        // Returning users land on login. Older builds never set the flag, so a stored token counts too.
        showingSignup = !d.bool(forKey: Self.accountUsedKey) && (try? TokenVault.read(server: savedServer))?.isEmpty != false
        TokenVault.removeLegacyPlaintextCopies()
        if let choices: InstrumentChoices = try? Bundled.decode("instruments") {
            instrumentVoices = choices.voices
            let saved = d.string(forKey:"sori.voice") ?? choices.defaultVoice
            selectedVoice = choices.voices.contains(where: { $0.id == saved }) ? saved : choices.defaultVoice
            player.voiceId = selectedVoice
        }
        player.onCursor = { [weak self] cursor in
            guard let self, var record = session else { return }; record.cursor = cursor; try persist(record)
        }
        player.onError = { [weak self] error in self?.error = error.localizedDescription }
        drawing.onChange = { [weak self] value in self?.saveDrawing(value) }
    }
    private static let demoBase = "https://demo.invalid/api/v1/"
    private static var hasConfiguredServer: Bool { !(Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String ?? "").isEmpty }
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
        guard !busy, !authenticating else { return }; busy = true; busyText = label
        let generation = UUID(); operationGeneration = generation
        defer { if operationGeneration == generation { busy = false } }
        do { try await operation() } catch { if operationGeneration == generation { report(error) } }
    }
    private func clearUserState() {
        if !isLocked { saveDrawing(drawing.canvas.drawing) }
        player.stopForPreparation(); drawing.freeze(true)
        operationGeneration = UUID(); busy = false; pollGeneration = UUID()
        api = nil; store = nil; profile = nil; questions = []; history = []; session = nil; practiceResumeId = nil
        classicalQuestions = []; classicalLoaded = false; classicalPage = 0; classicalHasNextPage = false; selectedComposer = nil; selectedPracticeLevel = nil; recommendedExam = nil
        examOffer = nil; selectedQuestion = nil; template = nil; submittedImage = nil; mainScore = nil
        correctScoreImage = nil; correctScoreError = nil; prepared = false; connected = false
        waitingSince = nil; error = nil; screen = .main
        authenticating = false; logoutNeedsConfirmation = false; logoutFailure = nil; pendingLocalLogout = nil
    }
    private func saveConnection() {
        let defaults = UserDefaults.standard
        defaults.set(demo, forKey: "sori.demo"); defaults.set(server, forKey: "sori.server"); defaults.set(demoOutcome, forKey: "sori.demoOutcome")
    }
    private func securedAPI(base: URL, token: String, ticket: AuthenticationTicket) throws -> HTTPExamAPI {
        let candidate = try HTTPExamAPI(base: base, token: token, session: httpSession)
        candidate.isCurrent = { [weak self] in self?.authentication.matches(ticket, token: token) == true }
        candidate.onUnauthorized = { [weak self] in
            guard let self, self.authentication.matches(ticket, token: token) else { return }
            self.sessionOnlyToken = nil
            do {
                if try TokenVault.read(server: base.absoluteString) == token { try TokenVault.delete(server: base.absoluteString) }
            } catch { self.report(error) }
            self.authentication.invalidate(ticket, token: token)
            self.clearUserState()
        }
        return candidate
    }
    private func activateUser(_ user: UserProfile, candidate: any ExamAPI, destination: Screen = .main, current: () -> Bool) async throws {
        let local = try LocalStore(scope: candidate.scope + ":" + user.id.uuidString)
        let records = try local.all()
        let resumeId = try local.practiceResume(records: records)
        // Keep valid credentials after network/5xx failures so recovery is explicit.
        guard current() else { throw CancellationError() }
        api = candidate; store = local; profile = user; history = records; practiceResumeId = resumeId; connected = true
        examOffer = try? local.examOffer()
        if !demo { UserDefaults.standard.set(true, forKey: Self.accountUsedKey); showingSignup = false }
        let list = try await PracticeQuestionList.load { try await candidate.questions(page:$0) }
        guard current() else { throw CancellationError() }
        questions = list.questions; page = list.lastPage; hasNextPage = false; screen = destination
    }
    func connect(token: String? = nil, destination: Screen = .main) async {
        authentication.cancel(); clearUserState(); saveConnection()
        screen = destination
        // The demo never contacts the saved address, so an invalid one must not block it.
        guard let base = URL(string: demo ? Self.demoBase : server), Origin(base) != nil else { report(SolfegeError.configuration("API 주소를 확인해 주세요.")); return }
        let ticket = authentication.begin(base: base)
        authenticating = true; busyText = "학습 공간을 불러오는 중"
        defer { if authentication.matches(ticket) { authenticating = false } }
        do {
            if demo {
                let candidate = try DemoExamAPI(outcome: demoOutcome, storageScope:demoScope)
                let user = try await candidate.profile()
                try await activateUser(user, candidate: candidate, destination: destination, current: { self.authentication.matches(ticket) })
            } else {
                _ = try HTTPExamAPI(base: base) // Validate HTTPS and base path before Keychain lookup.
                loginRetryUntil = loginDeadlines[Origin(base)!.key]
                signupRetryUntil = signupDeadlines[Origin(base)!.key]
                let sessionOnly = sessionOnlyToken?.origin == Origin(base)!.key ? sessionOnlyToken?.token : nil
                let value = try token ?? sessionOnly ?? TokenVault.read(server: server)
                guard !value.isEmpty else { return }
                authentication.accept(value, for: ticket)
                let candidate = try securedAPI(base: base, token: value, ticket: ticket)
                let user = try await candidate.profile()
                guard authentication.matches(ticket, token: value) else { return }
                if let token { try TokenVault.save(token, server: server) }
                try await activateUser(user, candidate: candidate, destination: destination, current: { self.authentication.matches(ticket, token: value) })
            }
        } catch { if authentication.matches(ticket) { report(error) } }
        if !authentication.matches(ticket), authentication.ticket == nil { authenticating = false }
    }
    func login(username: String, password: String, keepSignedIn: Bool = true) async {
        guard let base = URL(string: server), let origin = Origin(base) else { report(SolfegeError.configuration("API 주소를 확인해 주세요.")); return }
        if let deadline = loginDeadlines[origin.key], deadline > Date() { loginRetryUntil = deadline; return }
        authentication.cancel(); clearUserState(); demo = false; saveConnection()
        let ticket = authentication.begin(base: base)
        authenticating = true; busyText = "로그인 확인 중"; loginMessage = nil
        defer { if authentication.matches(ticket) { authenticating = false } }
        do {
            let client = try HTTPExamAPI(base: base, session: httpSession)
            client.isCurrent = { [weak self] in self?.authentication.matches(ticket) == true }
            let result = try await client.login(username: username, password: password)
            guard authentication.accept(result.accessToken, for: ticket) else { return }
            if keepSignedIn {
                try TokenVault.save(result.accessToken, server: base.absoluteString); sessionOnlyToken = nil
            } else {
                // Another account's stored token must not come back on the next launch.
                try TokenVault.delete(server: base.absoluteString); sessionOnlyToken = (origin.key, result.accessToken)
            }
            loginDeadlines[origin.key] = nil; loginRetryUntil = nil
            let candidate = try securedAPI(base: base, token: result.accessToken, ticket: ticket)
            try await activateUser(result.user, candidate: candidate, current: { self.authentication.matches(ticket, token: result.accessToken) })
        } catch {
            guard authentication.matches(ticket) else { return }
            if let deadline = Self.rateLimitDeadline(error) {
                loginDeadlines[origin.key] = deadline; loginRetryUntil = deadline
                loginMessage = "로그인 시도가 많아 잠시 기다려야 해요."
            } else if case SolfegeError.server(401, let envelope?, _) = error, envelope.error.code == "INVALID_CREDENTIALS" {
                loginMessage = "아이디 또는 비밀번호가 맞지 않아요."
            } else { report(error) }
        }
    }
    private static func rateLimitDeadline(_ error: Error) -> Date? {
        guard case SolfegeError.server(429, let envelope, let header) = error else { return nil }
        let seconds = max(header ?? 0, Double(envelope?.error.retryAfterMs ?? 0) / 1000)
        return Date().addingTimeInterval(max(1, seconds))
    }
    // Advisory only: a failed lookup keeps the entry visible, and signup's 403 has the final say.
    func refreshSignupAvailability() async {
        let requested = server
        guard !demo, let base = URL(string: requested), let client = try? HTTPExamAPI(base: base, session: httpSession) else { return }
        let enabled = (try? await client.signupAvailability().signupEnabled) ?? true
        guard !Task.isCancelled, server == requested else { return }
        signupEnabled = enabled
    }
    func openSignup() { signupFieldErrors = []; checkedUsername = nil; loginMessage = nil; showingSignup = true }
    func closeSignup() { signupFieldErrors = []; checkedUsername = nil; showingSignup = false }
    func clearSignupError(_ field: String) { signupFieldErrors.removeAll { $0.field == field } }
    // nil until a check of this username on this server has finished.
    func usernameStatus(_ username: String) -> UsernameStatus? {
        guard let checkedUsername, checkedUsername.server == server, checkedUsername.username == username else { return nil }
        return checkedUsername.status
    }
    // Advisory only: anything but a clear "taken" lets the form go on, and signup's 409 has the final say.
    func checkUsername(_ username: String) async {
        let requested = server
        var status = UsernameStatus.unknown
        if !demo, let base = URL(string: requested), let origin = Origin(base), (usernameCheckDeadlines[origin.key] ?? .distantPast) <= Date(),
           let client = try? HTTPExamAPI(base: base, session: httpSession) {
            do { status = try await client.usernameCheck(username).available ? .available : .taken }
            catch { if let deadline = Self.rateLimitDeadline(error) { usernameCheckDeadlines[origin.key] = deadline } }
        }
        // The form cancels a check when the username changes, so a late answer never replaces a newer one.
        guard !Task.isCancelled, server == requested else { return }
        checkedUsername = (requested, username, status)
    }
    func signup(username: String, displayName: String, password: String) async {
        guard let base = URL(string: server), let origin = Origin(base) else { report(SolfegeError.configuration("API 주소를 확인해 주세요.")); return }
        if let deadline = signupDeadlines[origin.key], deadline > Date() { signupRetryUntil = deadline; return }
        authentication.cancel(); clearUserState(); demo = false; saveConnection()
        let ticket = authentication.begin(base: base)
        authenticating = true; busyText = "계정을 만드는 중"; signupFieldErrors = []
        defer { if authentication.matches(ticket) { authenticating = false } }
        let retried = uncertainSignup?.origin == origin.key && uncertainSignup?.username == username
        uncertainSignup = (origin.key, username)
        do {
            let client = try HTTPExamAPI(base: base, session: httpSession)
            client.isCurrent = { [weak self] in self?.authentication.matches(ticket) == true }
            let result = try await client.signup(username: username, displayName: displayName, password: password)
            guard authentication.accept(result.accessToken, for: ticket) else { return }
            uncertainSignup = nil; signupDeadlines[origin.key] = nil; signupRetryUntil = nil; showingSignup = false
            try TokenVault.save(result.accessToken, server: base.absoluteString); sessionOnlyToken = nil
            let candidate = try securedAPI(base: base, token: result.accessToken, ticket: ticket)
            try await activateUser(result.user, candidate: candidate, current: { self.authentication.matches(ticket, token: result.accessToken) })
        } catch {
            guard authentication.matches(ticket) else { return }
            signupFailed(error, origin: origin, username: username, retried: retried)
        }
    }
    private func signupFailed(_ error: Error, origin: Origin, username: String, retried: Bool) {
        if let deadline = Self.rateLimitDeadline(error) { signupDeadlines[origin.key] = deadline; signupRetryUntil = deadline }
        // Without a contract error the server may still have created the account.
        guard case SolfegeError.server(let status, let envelope?, _) = error, status < 500 else { report(error); return }
        if !retried { uncertainSignup = nil }
        switch envelope.error.code {
        case "USERNAME_TAKEN" where retried:
            uncertainSignup = nil; loginPrefill = username; showingSignup = false
            self.error = "직전 가입이 이미 완료되었을 수 있어요. 같은 아이디와 비밀번호로 로그인해 보세요."
        case "USERNAME_TAKEN", "VALIDATION_ERROR":
            signupFieldErrors = envelope.error.fields
            if envelope.error.fields.isEmpty { report(error) }
        case "SIGNUP_DISABLED":
            signupEnabled = false; showingSignup = false
            self.error = "현재 회원가입을 제공하지 않습니다. 계정이 있다면 로그인해 주세요."
        case "RATE_LIMITED" where retried:
            loginPrefill = username
            let wait = max(1, Int(ceil(signupRetryUntil?.timeIntervalSinceNow ?? 1)))
            self.error = "\(wait)초 후 다시 시도할 수 있어요. 직전 가입이 이미 완료되었을 수 있으니 같은 아이디로 로그인을 먼저 시도해 보세요."
        default: report(error)
        }
    }
    func cancelLogin() {
        sessionOnlyToken = nil
        authentication.cancel(); authenticating = false; clearUserState()
    }
    func switchAccount() {
        // Preserve the server token until a new login replaces it. The new
        // operation generation immediately hides this user's local records.
        cancelLogin()
    }
    func logout() async {
        guard let base = URL(string: server), Origin(base) != nil, let token = authentication.token else { return }
        if !isLocked { saveDrawing(drawing.canvas.drawing) }
        player.pause(); drawing.freeze(true)
        operationGeneration = UUID(); busy = false; pollGeneration = UUID()
        logoutNeedsConfirmation = false; logoutFailure = nil; pendingLocalLogout = nil
        let ticket = authentication.begin(base: base)
        authentication.accept(token, for: ticket); authenticating = true; busyText = "로그아웃 중"
        defer { if authentication.matches(ticket) { authenticating = false; drawing.freeze(isLocked) } }
        do {
            let candidate = try securedAPI(base: base, token: token, ticket: ticket)
            api = candidate
            // 401 also confirms that this token can no longer authenticate.
            do { try await candidate.logout() }
            catch SolfegeError.server(401, _, _) { }
            guard authentication.matches(ticket, token: token) else { authenticating = false; return }
            if try TokenVault.read(server: base.absoluteString) == token { try TokenVault.delete(server: base.absoluteString) }
            cancelLogin()
        } catch {
            guard authentication.matches(ticket, token: token) else { return }
            logoutFailure = "서버에서 로그아웃을 확인하지 못했습니다. 기기에서만 로그아웃하면 서버 토큰이 남아 있을 수 있습니다.\n" + error.localizedDescription
            pendingLocalLogout = (base, token, ticket)
            logoutNeedsConfirmation = true
        }
    }
    func localLogout() {
        guard let pending = pendingLocalLogout, authentication.matches(pending.ticket, token: pending.token) else { return }
        do {
            if try TokenVault.read(server: pending.base.absoluteString) == pending.token { try TokenVault.delete(server: pending.base.absoluteString) }
            cancelLogin()
        }
        catch { report(error) }
    }
    func deleteAccount() async {
        guard let base = URL(string: server), Origin(base) != nil, let token = authentication.token else { return }
        let local = store
        player.pause(); drawing.freeze(true)
        operationGeneration = UUID(); busy = false; pollGeneration = UUID()
        logoutNeedsConfirmation = false; logoutFailure = nil; pendingLocalLogout = nil
        let ticket = authentication.begin(base: base)
        authentication.accept(token, for: ticket); authenticating = true; busyText = "계정을 삭제하는 중"
        defer { if authentication.matches(ticket) { authenticating = false; drawing.freeze(isLocked) } }
        do {
            let candidate = try securedAPI(base: base, token: token, ticket: ticket)
            let expire = candidate.onUnauthorized
            candidate.onUnauthorized = { [weak self] in
                guard let self, self.authentication.matches(ticket, token: token) else { return }
                expire()
                self.error = "계정이 이미 삭제됐거나 다른 기기에서 로그아웃했을 수 있어요. 같은 아이디로 다시 로그인되면 계정이 남아 있는 거예요."
            }
            api = candidate
            try await candidate.deleteAccount()
            guard authentication.matches(ticket, token: token) else { authenticating = false; return }
            // The account is gone, so local failures must not keep this user signed in.
            var cleaned = true
            do { if try TokenVault.read(server: base.absoluteString) == token { try TokenVault.delete(server: base.absoluteString) } } catch { cleaned = false }
            // Remove the records last: leaving the session saves its drawing into this store.
            cancelLogin()
            do { try local?.removeAll() } catch { cleaned = false }
            if !cleaned { self.error = "계정은 삭제했지만 이 기기에 저장된 정보 일부를 지우지 못했어요." }
        } catch {
            guard authentication.matches(ticket, token: token), !(error is CancellationError) else { return }
            if case SolfegeError.server(403, let envelope?, _) = error, envelope.error.code == "ACCOUNT_DELETION_NOT_ALLOWED" {
                self.error = "관리자 계정은 앱에서 삭제할 수 없어요."
            } else {
                self.error = "계정이 삭제됐는지 확인하지 못했어요. 연결을 확인한 뒤 다시 시도해 주세요.\n" + error.localizedDescription
            }
        }
    }
    func setDemoMode(_ enabled: Bool) async {
        guard !busy, enabled != demo else { return }
        if !isLocked { saveDrawing(drawing.canvas.drawing) }
        demo = enabled
        // Persist the actual selection immediately, including when a live
        // connection still needs a server/token. Never keep the old API active.
        UserDefaults.standard.set(enabled,forKey:"sori.demo")
        await connect(destination:.settings)
    }
    // Reconnecting would clear the signed-in state and show the login gate mid-refresh.
    func refreshLibrary(destination: Screen) async {
        guard connected, let api else { await connect(destination:destination); return }
        await run("문제 목록을 불러오는 중") {
            let list = try await PracticeQuestionList.load { try await api.questions(page:$0) }
            self.questions = list.questions; self.page = list.lastPage; self.hasNextPage = false
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
    func selectVoice(_ id: String) {
        guard instrumentVoices.contains(where: { $0.id == id }), id != selectedVoice else { return }
        player.stopForPreparation(); prepared = false
        selectedVoice = id; player.voiceId = id
        UserDefaults.standard.set(id,forKey:"sori.voice")
    }
    func loadClassical(reset: Bool = false) async {
        await run("클래식 문제를 불러오는 중") {
            guard let api = self.api else { return }
            if self.classicalLoaded && !self.classicalHasNextPage && !reset { return }
            let number = reset ? 1 : self.classicalPage+1
            let value = try await api.classicalQuestions(page:number)
            if reset { self.classicalQuestions = [] }
            self.classicalQuestions.append(contentsOf:value.results.filter { q in !self.classicalQuestions.contains(where: { $0.id == q.id }) })
            self.classicalPage = number; self.classicalHasNextPage = value.next != nil; self.classicalLoaded = true
        }
    }
    func updateGoal(_ goal: String) async {
        await run("목표를 저장하는 중") { guard let api = self.api else { return }; self.profile = try await api.updateGoal(goal) }
    }
    func choose(_ id: UUID, mode: StudyMode = .exam) async {
        await run("문제 안내를 불러오는 중") {
            guard let api = self.api else { return }; let question = try await api.question(id)
            try question.validate(); self.selectedQuestion = question; self.selectedMode = question.collection == "classical" ? .practice : mode; self.screen = .question
        }
    }
    func startRecommendedExam() async {
        guard !busy, !authenticating else { return }
        if pendingCreation { await recoverPending(); return }
        if let active = history.filter({ $0.blocksNewExam }).last {
            await open(active); return
        }
        if examOffer != nil {
            selectedMode = .exam; selectedQuestion = nil; screen = .examSelection
            if let offer = examOffer { revalidateExamOffer(offer) }
            return
        }
        await run("시험을 불러오는 중이에요") {
            guard let api = self.api, let store = self.store else { return }
            self.selectedMode = .exam; self.screen = .recommendingExam
            let offer = try await api.examRecommendations(); try offer.validate()
            guard self.store === store, self.screen == .recommendingExam else { return }
            if let active = offer.activeAttemptId {
                try await self.restoreExam(active)
            } else {
                try self.store?.saveExamOffer(offer)
                self.examOffer = offer; self.selectedQuestion = nil; self.recommendedExam = nil; self.screen = .examSelection
            }
        }
        if screen == .recommendingExam { screen = .main }
    }
    private func revalidateExamOffer(_ cached: ExamOffer) {
        guard let api, let store else { return }
        Task {
            do {
                let fresh = try await api.examRecommendations(); try fresh.validate()
                guard self.store === store, self.screen == .examSelection, !self.busy,
                      self.examOffer?.id == cached.id else { return }
                if let active = fresh.activeAttemptId {
                    await self.run("진행 중인 시험을 불러오는 중") { try await self.restoreExam(active) }
                } else { try store.saveExamOffer(fresh); self.examOffer = fresh }
            } catch {
                // Keep the already-visible offer on a transient network failure.
                // Selection still goes through the server's single-active-exam check.
            }
        }
    }
    func chooseExam(_ choice: ExamChoice) async {
        guard let id = choice.questionId else { return }
        if pendingCreation { await recoverPending(); return }
        if let active = history.filter({ $0.blocksNewExam }).last { await open(active); return }
        await run("시험을 준비하는 중이에요") {
            guard let api = self.api, let store = self.store else { return }
            let question = try await api.question(id); try question.validate()
            guard self.store === store else { throw CancellationError() }
            guard question.version == choice.questionVersion,
                  let score = question.difficultyScore, let offeredScore = choice.difficultyScore,
                  abs(score-offeredScore) < 0.00001 else {
                self.examOffer = nil
                try self.store?.saveExamOffer(nil)
                throw SolfegeError.transport("시험 정보가 변경되었어요. 문제를 다시 추천받아 주세요.")
            }
            self.recommendedExam = question; self.selectedQuestion = question
            self.selectedMode = .exam
            do {
                let record = try await self.createSelectedAttempt()
                self.selectedQuestion = record.attempt.question; self.screen = .question
            } catch let error as SolfegeError where ["EXAM_ALREADY_ACTIVE","EXAM_QUESTION_ALREADY_SEEN"].contains(error.code ?? "") {
                try await self.reconcileExamSelection()
            }
        }
    }
    private func reconcileExamSelection() async throws {
        // The server has definitively rejected this creation. Another device may
        // have selected or completed the question while our old offer was visible.
        guard let api, let store else { return }
        let current = try await api.examRecommendations(); try current.validate()
        guard self.store === store else { throw CancellationError() }
        try store.savePending(nil); try store.saveExamOffer(nil); examOffer = nil
        if let active = current.activeAttemptId { try await restoreExam(active) }
        else {
            try store.saveExamOffer(current); examOffer = current
            selectedMode = .exam; selectedQuestion = nil; screen = .examSelection
        }
    }
    private func restoreExam(_ id: UUID) async throws {
        guard let api, let store else { return }
        let attempt = try await api.attempt(id)
        guard self.store === store else { throw CancellationError() }
        var record = SessionRecord(attempt:attempt)
        if store.exists("session.json",id:id) { record = try store.load(id) }
        record.attempt = attempt
        // A never-started exam has no handwriting yet. Never invent missing in-progress strokes.
        if attempt.status == "ready", !store.exists("drawing.pkdrawing",id:id) {
            try store.write(PKDrawing().dataRepresentation(),name:"drawing.pkdrawing",id:id)
        }
        try persist(record); try await presentExam(record)
    }
    private func presentExam(_ record: SessionRecord) async throws {
        if record.attempt.studyMode == .exam, record.attempt.status == "ready" {
            player.stopForPreparation(); prepared = false
            selectedMode = .exam; selectedQuestion = record.attempt.question; screen = .question
        } else { try await activate(record) }
    }
    private func persist(_ record: SessionRecord) throws {
        guard let store else { throw SolfegeError.storage("로컬 저장소가 준비되지 않았습니다.") }
        try store.save(record); self.session = record; history = try store.all()
        if record.id == practiceResumeId, !record.canResumePractice {
            try store.savePracticeResume(nil); practiceResumeId = nil
        }
    }
    func begin() async {
        await run("새 연습을 준비하는 중") {
            if self.selectedMode == .exam, let selected = self.selectedQuestion,
               let record = self.history.first(where: {
                   $0.attempt.studyMode == .exam && $0.attempt.question.id == selected.id &&
                       ($0.blocksNewExam || $0.attempt.status != "submitted")
               }) {
                guard let api = self.api else { return }
                var current = record; current.attempt = try await api.attempt(record.id)
                try self.persist(current); try await self.activate(current); return
            }
            let record = try await self.createSelectedAttempt()
            try await self.activate(record)
        }
    }
    private func createSelectedAttempt() async throws -> SessionRecord {
        guard let api = self.api, let store = self.store, let selected = self.selectedQuestion else { throw SolfegeError.storage("선택한 문제를 먼저 확인해 주세요.") }
        var pending = try store.pending() ?? PendingCreation(question: selected, key: UUID(), mode:self.selectedMode)
        guard pending.question.id == selected.id, pending.studyMode == self.selectedMode else {
            throw SolfegeError.storage("이전 문제의 생성 요청을 먼저 복구해 주세요. 연습 기록과 필기는 보관되어 있습니다.")
        }
        try store.savePending(pending)
        let attempt: Attempt
        do { attempt = try await api.createAttempt(question: pending.question, mode:pending.studyMode, key: pending.key) }
        catch let error as SolfegeError where error.code == "QUESTION_VERSION_MISMATCH" {
            let fresh = try await api.question(pending.question.id); try fresh.validate()
            pending = PendingCreation(question: fresh, key: UUID(), mode:pending.studyMode); try store.savePending(pending)
            attempt = try await api.createAttempt(question: fresh, mode:pending.studyMode, key: pending.key)
        }
        guard self.store === store else { throw CancellationError() }
        guard attempt.studyMode == pending.studyMode, attempt.question.id == pending.question.id, attempt.question.version == pending.question.version else {
            throw SolfegeError.transport("생성된 문제의 모드가 요청과 다릅니다. 앱과 서버의 버전을 확인해 주세요.")
        }
        var record = SessionRecord(attempt: attempt)
        if store.exists("session.json", id: attempt.id) { record = try store.load(attempt.id); record.attempt = attempt }
        else { try store.write(PKDrawing().dataRepresentation(), name: "drawing.pkdrawing", id: attempt.id) }
        try self.persist(record); try store.savePending(nil)
        if pending.studyMode == .exam { self.recommendedExam = nil; self.examOffer = nil; try store.saveExamOffer(nil) }
        return record
    }
    func recoverPending() async {
        await run("선택한 문제를 확인하는 중") {
            guard let pending = try self.store?.pending() else { return }
            self.selectedQuestion = pending.question; self.selectedMode = pending.studyMode
            do {
                let record = try await self.createSelectedAttempt()
                try await self.presentExam(record)
            } catch let error as SolfegeError where ["EXAM_ALREADY_ACTIVE","EXAM_QUESTION_ALREADY_SEEN"].contains(error.code ?? "") {
                try await self.reconcileExamSelection()
            }
        }
    }
    func open(_ record: SessionRecord) async {
        await run("저장한 연습을 복구하는 중") {
            guard let api = self.api, let store = self.store else { return }
            var current = try store.load(record.id)
            guard self.canOpenHistoryRecord(current) ||
                    (self.session?.id == current.id && (self.screen == .exam || self.screen == .result)) else {
                throw SolfegeError.configuration("새 연습으로 교체된 문제예요. Practice에서 풀던 문제를 이어서 할 수 있어요.")
            }
            current.attempt = try await api.attempt(record.id)
            guard self.store === store else { throw CancellationError() }
            try self.persist(current); try await self.presentExam(current)
        }
    }
    private func activate(_ record: SessionRecord) async throws {
        selectedQuestion = record.attempt.question
        selectedMode = record.attempt.studyMode
        if record.attempt.question.collection == "classical" { selectedComposer = record.attempt.question.composer }
        else { selectedPracticeLevel = record.attempt.question.practiceLevel }
        player.stopForPreparation(); prepared = false; drawingMissing = false; saveFailed = false; mainScore = nil; submittedImage = nil; template = nil; correctScoreImage = nil; correctScoreError = nil; waitingSince = nil
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
        default: throw SolfegeError.unsupported("지원하지 않는 응시 상태입니다: \(record.attempt.status)")
        }
    }
    private func cached(_ name: String, url: URL, authenticated: Bool, sha: String, limit: Int, id: UUID) async throws -> Data {
        guard let store, let api else { throw SolfegeError.storage("저장소가 준비되지 않았습니다.") }
        if store.exists(name, id: id) { let data = try store.read(name, id: id); if data.sha256 == sha { return data } }
        let data = try await api.asset(url, authenticated: authenticated, limit: limit)
        guard data.sha256 == sha else { throw SolfegeError.invalidScore("SCORE_HASH_MISMATCH: \(name) 파일의 해시가 다릅니다.") }
        try store.write(data, name: name, id: id); return data
    }
    private func prepareAssets() async throws {
        guard let record = session else { return }
        let q = record.attempt.question, plan = record.attempt.playbackPlan
        try q.validate(); try plan.validate()
        let imageData = try await cached("template.png", url: q.sheetLayout.templatePngUrl, authenticated: false, sha: q.sheetLayout.templateSha256, limit: 10_485_760, id: record.id)
        let mainData = try await cached("main.mxl", url: q.scoreAssets.main.url, authenticated: true, sha: q.scoreAssets.main.sha256, limit: 1_048_576, id: record.id)
        let scaleData = try await cached("scale.mxl", url: q.scoreAssets.scale.url, authenticated: true, sha: q.scoreAssets.scale.sha256, limit: 1_048_576, id: record.id)
        let main = try MusicXMLParser.parseMXL(mainData, asset: q.scoreAssets.main)
        let scale = try MusicXMLParser.parseMXL(scaleData, asset: q.scoreAssets.scale)
        guard main.timeSignature == q.timeSignature, scale.timeSignature == q.timeSignature,
              main.keySignature == q.keySignature,
              scale.keySignature.fifths == q.keySignature.fifths,
              q.keySignature.mode == "unspecified" || scale.keySignature == q.keySignature
        else { throw SolfegeError.invalidScore("문제 안내·선율·음계의 조성이나 박자가 다릅니다.") }
        self.template = try AnswerExporter.validateTemplate(imageData, layout: q.sheetLayout); self.mainScore = main
        try player.prepare(main: main, scale: scale, plan: plan); player.restore(record.cursor)
        self.prepared = true
    }
    func retryPrepare() async { await run("악보와 피아노를 준비하는 중") { try await self.prepareAssets() } }
    func start() async {
        await run("연습을 시작하는 중") {
            guard self.prepared, let api = self.api, let store = self.store, var record = self.session else { return }
            record.attempt = try await api.start(record.id)
            guard self.store === store else { throw CancellationError() }
            if record.attempt.studyMode == .practice {
                // Browsing and preparation leave the previous slot intact. Replace
                // it only after the server acknowledges that the new practice began.
                try store.savePracticeResume(record.id); self.practiceResumeId = record.id
            }
            self.clock.sync(record.attempt); try self.persist(record)
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
            guard record.attempt.status == "in_progress", !self.drawingMissing, !self.saveFailed else { throw SolfegeError.storage("필기 원본과 응시 상태를 먼저 복구해 주세요.") }
            if !record.frozen {
                guard let template = self.template else { throw SolfegeError.storage("오선 템플릿이 준비되지 않았습니다.") }
                try store.write(self.drawing.canvas.drawing.dataRepresentation(), name: "drawing.pkdrawing", id: record.id)
                let png = try AnswerExporter.png(template: template, drawing: self.drawing.canvas.drawing, layout: record.attempt.question.sheetLayout)
                try store.write(png, name: "submission.png", id: record.id)
                record.clientAnswerId = UUID(); record.uploadKey = UUID(); record.submitKey = UUID(); record.frozen = true
                try self.persist(record)
            }
            let png = try store.read("submission.png", id: record.id)
            guard let client = record.clientAnswerId, let uploadKey = record.uploadKey, let submitKey = record.submitKey else { throw SolfegeError.storage("제출 복구 정보가 손상되었습니다.") }
            if record.uploaded == nil {
                let answer = try await api.upload(record.id, png: png, clientId: client, layout: record.attempt.question.sheetLayout.id, key: uploadKey)
                guard answer.attemptId == record.id, answer.clientAnswerId == client, answer.sha256 == png.sha256, answer.sizeBytes == png.count,
                      answer.imageWidth == 2660, answer.imageHeight == 1692, answer.answerFormatVersion == 1,
                      answer.sheetLayoutId == record.attempt.question.sheetLayout.id, answer.contentType == "image/png" else { throw SolfegeError.transport("서버의 업로드 영수증이 제출 파일과 다릅니다.") }
                record.uploaded = answer; try self.persist(record)
            }
            guard let answer = record.uploaded else { return }
            if record.attempt.studyMode == .practice {
                let review = try await api.submitPractice(record.id,answerId:answer.id,key:submitKey)
                try review.validate(attemptId:record.id,answerId:answer.id,measureCount:record.attempt.question.measureCount)
                record.selfAssessment = review; record.grading = nil
            } else {
                let grading = try await api.submit(record.id, answerId: answer.id, key: submitKey)
                guard grading.attemptId == record.id, grading.answerId == answer.id else { throw SolfegeError.transport("제출 결과의 답안 ID가 다릅니다.") }
                record.grading = grading
            }
            record.attempt = try await api.attempt(record.id); try self.persist(record)
            self.screen = .result; self.waitingSince = Date(); try await self.loadResult()
        }
        drawing.freeze(isLocked)
    }
    private func loadResult() async throws {
        guard let api, let store, var record = session else { return }
        guard let answerId = record.attempt.submittedAnswerId else { throw SolfegeError.transport("제출한 답안이 없습니다.") }
        if record.attempt.studyMode == .practice {
            let review = try await api.practiceAssessment(record.id)
            try review.validate(attemptId:record.id,answerId:answerId,measureCount:record.attempt.question.measureCount)
            guard review.featureAnalysisId == record.attempt.featureAnalysisId else { throw SolfegeError.transport("문제 분석 버전이 응시와 다릅니다.") }
            record.selfAssessment = review; record.grading = nil; waitingSince = nil
        } else {
            let grading = try await api.result(record.id)
            guard self.store === store, self.session?.id == record.id else { throw CancellationError() }
            guard grading.attemptId == record.id, grading.answerId == answerId else { throw SolfegeError.transport("결과가 제출한 답안과 일치하지 않습니다.") }
            record.grading = grading
            if grading.status == "completed", let change = grading.ratingChange,
               let offer = self.examOffer, offer.rating.completed <= change.completedBefore {
                // No new offer is fetched until the user explicitly asks for another exam.
                self.examOffer = nil; try store.saveExamOffer(nil)
            }
            if grading.isPending && waitingSince == nil { waitingSince = Date() }
        }
        try persist(record)
        if let answer = [record.uploaded, record.attempt.latestAnswer].compactMap({ $0 }).first(where: { $0.id == answerId }) {
            for name in ["submitted.png","submission.png"] where submittedImage == nil && store.exists(name,id:record.id) {
                let data = try store.read(name,id:record.id)
                if data.sha256 == answer.sha256 { submittedImage = UIImage(data:data) }
            }
            if submittedImage == nil {
                let data = try await api.answerImage(answer)
                guard self.store === store, self.session?.id == record.id else { throw CancellationError() }
                guard data.sha256 == answer.sha256, data.count == answer.sizeBytes, let image = UIImage(data: data), image.cgImage?.width == 2660, image.cgImage?.height == 1692 else { throw SolfegeError.transport("제출 이미지의 해시·크기가 일치하지 않습니다.") }
                try store.write(data, name: "submitted.png", id: record.id); submittedImage = image
            }
        } else {
            // latest_answer is not necessarily the submitted answer: address the pinned answer directly.
            if let id = record.attempt.submittedAnswerId {
                let url = record.attempt.question.scoreAssets.main.url
                guard let base = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = base.scheme, let host = base.host else { throw SolfegeError.transport("이미지 주소 오류") }
                var components = URLComponents(); components.scheme = scheme; components.host = host; components.port = base.port
                components.path = "/api/v1/attempts/\(record.id.uuidString.lowercased())/answers/\(id.uuidString.lowercased())/image/"
                let bytes = try await api.asset(components.url!, authenticated: true, limit: 10_485_760)
                guard self.store === store, self.session?.id == record.id else { throw CancellationError() }
                guard let image = UIImage(data: bytes), image.cgImage?.width == 2660, image.cgImage?.height == 1692 else { throw SolfegeError.transport("제출 이미지 형식 오류") }; submittedImage = image
            }
        }
        await loadReferenceImage()
        guard self.store === store, self.session?.id == record.id else { throw CancellationError() }
        if mainScore == nil {
            let asset = record.attempt.question.scoreAssets.main
            let data = try await cached("main.mxl", url: asset.url, authenticated: true, sha: asset.sha256, limit: 1_048_576, id: record.id)
            guard self.store === store, self.session?.id == record.id else { throw CancellationError() }
            mainScore = try MusicXMLParser.parseMXL(data, asset: asset)
        }
    }
    private func loadReferenceImage() async {
        guard correctScoreImage == nil, let record = session, let asset = record.attempt.question.correctScore else { return }
        do {
            guard asset.contentType == "image/png", asset.sizeBytes > 0, asset.sizeBytes <= 2_097_152,
                  asset.pixelWidth > 0, asset.pixelWidth <= 4096, asset.pixelHeight > 0, asset.pixelHeight <= 2048 else { throw SolfegeError.invalidScore("정답 이미지 규격을 확인해 주세요.") }
            let data = try await cached("correct-score.png", url:asset.url, authenticated:true, sha:asset.sha256, limit:2_097_152, id:record.id)
            guard data.count == asset.sizeBytes, let image = UIImage(data:data), image.cgImage?.width == asset.pixelWidth,
                  image.cgImage?.height == asset.pixelHeight else { throw SolfegeError.invalidScore("정답 이미지의 크기가 일치하지 않습니다.") }
            guard session?.id == record.id else { return }
            correctScoreImage = image; correctScoreError = nil
        } catch { if session?.id == record.id { correctScoreError = error.localizedDescription } }
    }
    func refreshResult() async { await run("결과를 확인하는 중") { try await self.loadResult() }; pollGeneration = UUID() }
    func poll() async {
        while !Task.isCancelled, foreground, screen == .result, session?.attempt.studyMode == .exam, session?.grading?.isPending == true {
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
            guard let api = self.api, var record = self.session, record.attempt.studyMode == .exam, record.grading?.canRetry == true else { return }
            if record.gradingRetryKey == nil { record.gradingRetryKey = UUID(); try self.persist(record) }
            do {
                let grading = try await api.retryGrading(record.id, key: record.gradingRetryKey!)
                record.grading = grading; record.gradingRetryKey = nil; try self.persist(record)
            } catch let error as SolfegeError where ["GRADING_IN_PROGRESS", "GRADING_NOT_RETRYABLE"].contains(error.code ?? "") {
                record.gradingRetryKey = nil; try self.persist(record); try await self.loadResult()
            }
            self.waitingSince = Date(); self.pollGeneration = UUID()
        }
    }
    func togglePracticeError(measure: Int, type: SelfAssessmentErrorType) {
        guard !busy, var record = session, record.attempt.studyMode == .practice, record.selfAssessmentSave == nil,
              record.attempt.status == "submitted", let review = record.selfAssessment else { return }
        do {
            record.practiceEdits = try SelfAssessmentEdits.toggling(practiceErrors,measure:measure,type:type,measureCount:record.attempt.question.measureCount)
            record.practiceBaseRevision = record.practiceBaseRevision ?? review.revision
            try persist(record)
        } catch { report(error) }
    }
    func savePracticeAssessment(completed: Bool) async {
        await run("자기채점 기록을 저장하는 중") {
            guard let api = self.api, var record = self.session, record.attempt.studyMode == .practice,
                  let review = record.selfAssessment, let answerId = record.attempt.submittedAnswerId else { return }
            guard self.practiceComparisonReady else { throw SolfegeError.configuration("정답과 내 악보를 불러온 뒤 채점을 완료해 주세요.") }
            if record.selfAssessmentSave == nil {
                guard !self.practiceHasConflict else { throw SolfegeError.configuration("변경된 채점 기록을 먼저 확인해 주세요.") }
                let request = SelfAssessmentWrite(expectedRevision:record.practiceBaseRevision ?? review.revision,
                    errors:try SelfAssessmentEdits.normalized(self.practiceErrors,measureCount:record.attempt.question.measureCount),completed:completed)
                record.practiceBaseRevision = request.expectedRevision
                record.practiceEdits = request.errors
                record.selfAssessmentSave = PendingSelfAssessment(key:UUID(),request:request)
                try self.persist(record)
            }
            guard let pending = record.selfAssessmentSave else { return }
            do {
                let saved = try await api.saveSelfAssessment(record.id,request:pending.request,key:pending.key)
                try saved.validate(attemptId:record.id,answerId:answerId,measureCount:record.attempt.question.measureCount)
                guard saved.revision == pending.request.expectedRevision+1, saved.featureAnalysisId == record.attempt.featureAnalysisId,
                      saved.errors == pending.request.errors, saved.isCompleted == pending.request.completed else {
                    throw SolfegeError.transport("저장된 자기채점 버전이 요청과 다릅니다.")
                }
                record.selfAssessment = saved; record.selfAssessmentSave = nil
                record.practiceEdits = nil; record.practiceBaseRevision = nil
                try self.persist(record)
            } catch let error as SolfegeError where error.code == "SELF_ASSESSMENT_REVISION_CONFLICT" {
                let latest = try await api.practiceAssessment(record.id)
                try latest.validate(attemptId:record.id,answerId:answerId,measureCount:record.attempt.question.measureCount)
                record.selfAssessment = latest; record.selfAssessmentSave = nil
                try self.persist(record)
                throw error
            }
        }
    }
    func useServerPracticeAssessment() {
        guard !busy, var record = session, record.selfAssessmentSave == nil else { return }
        record.practiceEdits = nil; record.practiceBaseRevision = nil
        do { try persist(record) } catch { report(error) }
    }
    func keepLocalPracticeEdits() {
        guard !busy, var record = session, record.selfAssessmentSave == nil, let review = record.selfAssessment else { return }
        record.practiceBaseRevision = review.revision
        do { try persist(record) } catch { report(error) }
    }
    func background() { foreground = false; player.pause(); if !isLocked { saveDrawing(drawing.canvas.drawing) } }
    func foregroundAgain() async {
        foreground = true; pollGeneration = UUID()
        guard !busy, let record = session, screen == .exam || screen == .result else { return }
        // Explicit user input is still required to resume sound.
        await open(record)
    }
    func navigate(_ target: Screen) {
        if target != .exam { player.pause() }
        if target == .examSelection {
            Task { await self.startRecommendedExam() }; return
        }
        if [.home, .practiceLevels, .practiceQuestions, .classical].contains(target) { selectedMode = .practice }
        screen = target
    }
}
