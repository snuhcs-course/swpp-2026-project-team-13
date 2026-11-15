import SwiftUI

@MainActor final class EchoDragonModel: ObservableObject {
    enum Result { case correct, incorrect }
    static let storageKey = "solfege.echo-dragon.progress.v1"
    @Published private(set) var progress = EchoDragonProgress()
    @Published private(set) var challenge: EchoDragonChallenge?
    @Published private(set) var selected: Int?
    @Published private(set) var result: Result?
    @Published private(set) var attempts = 0
    @Published private(set) var usedHint = false
    @Published private(set) var heardCall = false
    @Published private(set) var isPlaying = false
    @Published private(set) var soundLabel = ""
    @Published private(set) var interrupted = false
    @Published private(set) var preview = false
    @Published private(set) var stars = 0
    @Published var error: String?
    let audio: any EchoDragonPlaying
    private let defaults: UserDefaults
    private var storageReadable = true
    private var playback: Task<Void,Never>?
    private var playbackID = UUID()
    var canAnswer: Bool { challenge != nil && heardCall && !isPlaying && !interrupted && result != .correct }

    init(defaults: UserDefaults = .standard, audio: (any EchoDragonPlaying)? = nil) {
        self.defaults = defaults
        self.audio = audio ?? EchoDragonAudio()
        do { progress = try EchoDragonProgress.load(defaults.data(forKey:Self.storageKey)) }
        catch {
            storageReadable = false
            self.error = "진행 기록을 읽지 못했어요. 이번 플레이는 저장하지 않고 기존 기록을 유지해요. 앱을 다시 열어 주세요."
        }
    }
    func open(_ number: Int, preview: Bool = false) {
        guard (1...EchoDragonLevel.count).contains(number), preview || number <= progress.unlocked else { return }
        cancelAudio()
        self.preview = preview
        challenge = .make(number:number,variation:UInt64.random(in:0...UInt64.max))
        selected = nil; result = nil; attempts = 0; usedHint = false
        heardCall = false; interrupted = false; stars = 0
    }
    func listen() {
        guard let challenge else { return }
        interrupted = false
        play(label:"드래곤의 부름을 들어요",marksHeard:true) { audio in
            try await audio.pair(challenge.callRoot,challenge.callEnd)
            try await Task.sleep(for:.milliseconds(450))
            self.soundLabel = "이 소리에서 시작해요"
            try await audio.note(challenge.replyRoot)
        }
    }
    func select(_ midi: Int) {
        guard canAnswer, let challenge, challenge.choices.contains(midi) else { return }
        selected = midi; result = nil
        play(label:"내 대답을 들어요") { try await $0.pair(challenge.replyRoot,midi) }
    }
    func root() {
        guard let challenge, !interrupted else { return }
        play(label:"내 시작음") { try await $0.note(challenge.replyRoot) }
    }
    func replayAnswer() {
        guard let challenge, let selected, !interrupted else { return }
        play(label:"내 대답을 들어요") { try await $0.pair(challenge.replyRoot,selected) }
    }
    func hint() {
        guard canAnswer else { return }
        usedHint = true
    }
    func compare() {
        guard let challenge, let selected, !isPlaying, !interrupted else { return }
        if result != .correct { usedHint = true }
        play(label:"내 대답 → 정답 대답") { audio in
            try await audio.pair(challenge.replyRoot,selected)
            try await Task.sleep(for:.milliseconds(500))
            self.soundLabel = "같은 시작음으로 정답을 들어요"
            try await audio.pair(challenge.replyRoot,challenge.answer)
        }
    }
    func submit() {
        guard canAnswer, let challenge, let selected else { return }
        attempts += 1
        guard challenge.isCorrect(selected) else { result = .incorrect; return }
        result = .correct
        stars = EchoDragonProgress.earnedStars(attempts:attempts,hint:usedHint)
        guard !preview, storageReadable else { return }
        progress.record(level:challenge.level.number,stars:stars)
        do { defaults.set(try JSONEncoder().encode(progress),forKey:Self.storageKey) }
        catch { self.error = "진행 기록을 저장하지 못했어요. 이 화면을 닫기 전에 다시 시도해 주세요." }
    }
    func next() {
        guard result == .correct, let challenge else { return }
        if preview || challenge.level.number == EchoDragonLevel.count { map(); return }
        open(challenge.level.number+1)
    }
    func map() { stop(); challenge = nil }
    func pause() {
        guard challenge != nil else { return }
        cancelAudio(); audio.stop(); interrupted = true
    }
    func stop() { cancelAudio(); audio.stop() }
    private func cancelAudio() {
        playbackID = UUID(); playback?.cancel(); playback = nil
        audio.silence(); isPlaying = false; soundLabel = ""
    }
    private func play(label: String, marksHeard: Bool = false,
                      operation: @escaping @MainActor (any EchoDragonPlaying) async throws -> Void) {
        cancelAudio()
        let id = playbackID
        isPlaying = true; soundLabel = label
        playback = Task { [weak self] in
            guard let self else { return }
            do {
                try self.audio.prepare()
                try await operation(self.audio)
                try Task.checkCancellation()
                guard self.playbackID == id else { return }
                if marksHeard { self.heardCall = true }
                self.isPlaying = false; self.soundLabel = ""
            } catch is CancellationError {
                // The caller already silenced the cancelled sequence. Never stop a newer one.
            } catch {
                guard self.playbackID == id else { return }
                self.audio.stop(); self.isPlaying = false; self.soundLabel = ""
                self.error = "소리를 재생하지 못했어요. 다시 듣기를 눌러 주세요. \(error.localizedDescription)"
            }
        }
    }
}
