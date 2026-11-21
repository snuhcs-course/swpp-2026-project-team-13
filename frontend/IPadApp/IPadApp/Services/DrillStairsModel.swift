import SwiftUI

// Lives in the same per-origin/per-user folder as the minigame journals, so account
// deletion's LocalStore.removeAll also removes the climb.
final class DrillStairsStore {
    let root: URL
    // Preserve the old random-round progress; it cannot prove a fixed set solved.
    var file: URL { root.appendingPathComponent("drill-stage-set-progress-v1.json") }
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    func load() throws -> DrillStairsProgress {
        guard FileManager.default.fileExists(atPath:file.path) else { return DrillStairsProgress() }
        return try DrillStairsProgress.load(Data(contentsOf:file))
    }
    func save(_ progress: DrillStairsProgress) throws {
        try JSONEncoder().encode(progress).write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
}

// What a minigame needs to run as one stage of the stairs.
struct DrillStageContext {
    let stage: DrillStage
    let question: DrillStageQuestion
    let index: Int
    let results: [DrillRoundResult?]
    let report: (DrillRoundResult) -> Void
    let next: () -> Void
    // Back to the stairs, from the result or from ✕.
    let exit: () -> Void
    var revealAcknowledged = false
    var acknowledgeReveal: () -> Void = {}
    var nextTitle: String { index+1==results.count ? "결과 보기" : "다음" }
}

@MainActor final class DrillStairsModel: ObservableObject {
    // What the stairs show. A clear is saved at once but shown when the game closes,
    // so the next key lights up while the user is looking.
    @Published private(set) var shown = DrillStairsProgress()
    @Published var error: String?
    @Published private(set) var course: DrillStageCourse?
    @Published private(set) var loading = false
    private(set) var progress = DrillStairsProgress()
    let rhythmAvailable: Bool
    private var store: DrillStairsStore?
    private var readable = true
    private let connection: RhythmConnection?
    var progressRoot: URL? { store?.root }

    init(connection: RhythmConnection?, root: URL? = nil) {
        self.connection = connection
        rhythmAvailable = connection != nil
        do {
            let folder = try root ?? LocalStore(scope:connection?.scope ?? "drill-stairs-guest").root
            let local = try DrillStairsStore(root:folder)
            store = local; progress = try local.load(); shown = progress
        } catch {
            readable = false
            self.error = "계단 진행 기록을 읽지 못했어요. 기존 기록은 그대로 두고, 이번 플레이는 저장하지 않아요."
        }
    }
    func state(_ stage: DrillStage) -> DrillStageState { shown.state(stage.number) }
    // Rhythm puzzle needs the server, as on the old Drill cards.
    func needsConnection(_ stage: DrillStage) -> Bool { stage.game == .rhythmPuzzle && !rhythmAvailable }
    func canStart(_ stage: DrillStage) -> Bool {
        if stage.game == .echoDragon { return readable && EchoIntervalStage.forStair(stage.number) != nil }
        return readable && course?.stages.contains(where:{ $0.number == stage.number }) == true && !needsConnection(stage)
    }
    func prepareCourse() async {
        guard course == nil, !loading else { return }
        loading=true; defer { loading=false }
        do {
            let data: Data
            if let connection, !connection.demo { data = try await TrainingContentProvider(connection:connection).data("drill-stage-sets-v1.json") }
            else { data = try DemoContent.data("drill-stage-sets-v1") }
            let value = try ContractJSON.decoder().decode(DrillStageCourse.self,from:data)
            try value.validate(); try Task.checkCancellation(); course=value
        } catch { if !Task.isCancelled { self.error=error.localizedDescription } }
    }
    func clear(_ number: Int) {
        guard progress.clear(number), readable, let store else { return }
        do { try store.save(progress) }
        catch { self.error = "계단 진행을 기기에 저장하지 못했어요. \(error.localizedDescription)" }
    }
    // Shows what was solved while a game was open; returns those stage numbers, lowest first.
    @discardableResult func reveal() -> [Int] {
        let solved = progress.cleared.subtracting(shown.cleared).sorted()
        if !solved.isEmpty { shown = progress }
        return solved
    }
}
