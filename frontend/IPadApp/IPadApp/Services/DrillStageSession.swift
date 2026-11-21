import SwiftUI

@MainActor final class DrillStageSession: ObservableObject {
    @Published private(set) var attempt: DrillSetAttempt
    @Published private(set) var summary = false
    @Published private(set) var error: String?
    @Published private(set) var prepared = false
    @Published var revealAcknowledged = false
    let stageSet: DrillStageSet
    let echoAudio = MelodyRunAudio()
    let memoryGame: MelodyRunModel?
    let rhythmGame: RhythmPuzzleModel?
    private let file: URL
    private var questionStarted = Date()
    private var pausedAt: Date?
    private var pausedSeconds: TimeInterval = 0
    private var history: [DrillSetAttempt] = []
    private struct Journal: Codable { var active: DrillSetAttempt; var history: [DrillSetAttempt] }
    init(set: DrillStageSet, version: String, root: URL, connection: RhythmConnection? = nil) {
        self.stageSet=set; attempt=DrillSetAttempt(set:set,version:version)
        memoryGame = set.game == .memoryRun ? MelodyRunModel(connection:connection,stageMode:true) : nil
        rhythmGame = set.game == .rhythmPuzzle ? RhythmPuzzleModel(connection:connection,stageMode:true) : nil
        file=root.appendingPathComponent("drill-set-\(version)-\(set.number).json")
        do {
            if FileManager.default.fileExists(atPath:file.path) {
                let saved=try JSONDecoder().decode(Journal.self,from:Data(contentsOf:file))
                guard saved.active.matches(set:set,version:version) else { throw SolfegeError.storage("저장된 스테이지와 문제 버전이 달라요.") }
                history=saved.history
                if saved.active.complete { attempt=saved.active; summary=true }
            }
        } catch { self.error="진행 기록을 읽지 못했어요. 기존 기록을 보관했어요." }
    }
    func prepare() async {
        guard !prepared, error == nil else { return }
        do {
            if let memoryGame { try await memoryGame.prepareStage(stageSet.questions) }
            if let rhythmGame { try await rhythmGame.prepareStage(stageSet.questions) }
            if stageSet.game == .echoDragon { try echoAudio.prepare() }
            try Task.checkCancellation(); resetClock(); prepared=true
        } catch { if !Task.isCancelled { self.error=error.localizedDescription } }
    }
    var round: DrillStageQuestion { stageSet.questions[attempt.index] }
    func report(_ result: DrillRoundResult) {
        guard error == nil, attempt.results[attempt.index] == nil else { return }
        let elapsed=max(0,Date().timeIntervalSince(questionStarted)-pausedSeconds)
        attempt.results[attempt.index]=DrillRoundResult(accuracy:result.accuracy,revealed:result.revealed,elapsedMs:Int(elapsed*1000))
    }
    func next() {
        guard attempt.results[attempt.index] != nil, error == nil else { return }
        if attempt.index+1 < stageSet.questions.count { attempt.index+=1; resetClock() }
        else {
            do { try memoryGame?.commitStage(); try rhythmGame?.commitStage() }
            catch { self.error="진행을 저장하지 못했어요. 저장 공간을 확인해 주세요."; return }
            save(); if error == nil { summary=true }
        }
    }
    func restart() {
        guard error == nil else { return }
        history.append(attempt)
        attempt=DrillSetAttempt(set:stageSet,version:attempt.courseVersion); summary=false; revealAcknowledged=false; resetClock()
    }
    func active(_ active: Bool) {
        if active { if let pausedAt { pausedSeconds+=Date().timeIntervalSince(pausedAt); self.pausedAt=nil } }
        else if pausedAt == nil { pausedAt=Date() }
    }
    private func resetClock() { questionStarted=Date(); pausedSeconds=0; pausedAt=nil }
    private func save() {
        do { try JSONEncoder().encode(Journal(active:attempt,history:history)).write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication]) }
        catch { self.error="진행을 저장하지 못했어요. 화면을 닫기 전에 저장 공간을 확인해 주세요." }
    }
}
