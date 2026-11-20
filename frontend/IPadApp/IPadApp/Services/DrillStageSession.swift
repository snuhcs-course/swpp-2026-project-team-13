import SwiftUI

@MainActor final class DrillStageSession: ObservableObject {
    @Published private(set) var attempt: DrillSetAttempt
    @Published private(set) var summary = false
    @Published private(set) var error: String?
    let set: DrillStageSet
    let echoAudio = MelodyRunAudio()
    private let file: URL
    private var questionStarted = Date()
    private var pausedAt: Date?
    private var pausedSeconds: TimeInterval = 0
    private var history: [DrillSetAttempt] = []
    private struct Journal: Codable { var active: DrillSetAttempt; var history: [DrillSetAttempt] }
    init(set: DrillStageSet, version: String, root: URL) {
        self.set=set; attempt=DrillSetAttempt(set:set,version:version)
        file=root.appendingPathComponent("drill-set-\(version)-\(set.number).json")
        do {
            if FileManager.default.fileExists(atPath:file.path) {
                let saved=try JSONDecoder().decode(Journal.self,from:Data(contentsOf:file))
                guard saved.active.matches(set:set,version:version) else { throw SolfegeError.storage("저장된 스테이지와 문제 버전이 달라요.") }
                attempt=saved.active; history=saved.history; summary=attempt.complete
                if !summary, let next=attempt.results.firstIndex(where:{ $0 == nil }) { attempt.index=next }
            }
        } catch { self.error="진행 기록을 읽지 못했어요. 기존 기록을 보관했어요." }
    }
    var round: DrillStageQuestion { set.questions[attempt.index] }
    func report(_ result: DrillRoundResult) {
        guard error == nil, attempt.results[attempt.index] == nil else { return }
        let elapsed=max(0,Date().timeIntervalSince(questionStarted)-pausedSeconds)
        attempt.results[attempt.index]=DrillRoundResult(accuracy:result.accuracy,revealed:result.revealed,elapsedMs:Int(elapsed*1000))
        save()
    }
    func next() {
        guard attempt.results[attempt.index] != nil, error == nil else { return }
        if attempt.index+1 < set.questions.count { attempt.index+=1; resetClock() }
        else { summary=true }
        save()
    }
    func restart() {
        guard error == nil else { return }
        history.append(attempt)
        attempt=DrillSetAttempt(set:set,version:attempt.courseVersion); summary=false; resetClock(); save()
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
