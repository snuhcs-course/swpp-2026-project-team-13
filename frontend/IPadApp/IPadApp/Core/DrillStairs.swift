import Foundation

// Drill: the three minigames mixed into one keyboard staircase (Figma "건반 계단 · E2안").
// One white key is one stage; stages are climbed from C1 (bottom) to D5 (top).
enum DrillGame: String, Codable, CaseIterable, Equatable {
    case echoDragon, memoryRun, rhythmPuzzle
    var title: String {
        switch self {
        case .echoDragon: return "Echo Dragon"
        case .memoryRun: return "Memory run"
        case .rhythmPuzzle: return "Rhythm puzzle"
        }
    }
}

struct DrillStage: Identifiable, Equatable {
    static let letters = ["C","D","E","F","G","A","B"]
    let number: Int
    let game: DrillGame
    // Legacy standalone Echo level; the active interval game uses
    // EchoIntervalStage.forStair instead. Nil for the other games.
    let echoLevel: Int?
    var id: Int { number }
    var letter: String { Self.letters[(number-1) % 7] }
    var octave: Int { (number-1) / 7 + 1 }
    var name: String { "\(letter)\(octave)" }
    // Memory run and Rhythm puzzle have three difficulties; each third of the stairs is one of them.
    var difficulty: MemoryDifficulty {
        number <= 10 ? .beginner : number <= 20 ? .intermediate : .advanced
    }
}

// open: not solved yet. next: the lowest unsolved key, highlighted as the suggested one. done: solved, shown pressed.
enum DrillStageState: Equatable { case open, next, done }

enum DrillStairs {
    static let count = 30
    // E M R E R M M E R, repeated from the bottom key.
    static let pattern: [DrillGame] = [.echoDragon,.memoryRun,.rhythmPuzzle,.echoDragon,.rhythmPuzzle,.memoryRun,.memoryRun,.echoDragon,.rhythmPuzzle]
    // Each Echo Dragon stage opens the next new sound (or the mirror rule at 25).
    static let echoLevels = [1,2,7,13,19,25,31,37,43,49]
    static let stages: [DrillStage] = {
        var echo = 0
        return (1...count).map { number in
            let game = pattern[(number-1) % pattern.count]
            var level: Int?
            if game == .echoDragon {
                level = echoLevels[min(echo,echoLevels.count-1)]
                echo += 1
            }
            return DrillStage(number:number,game:game,echoLevel:level)
        }
    }()
    static func stage(_ number: Int) -> DrillStage? {
        stages.indices.contains(number-1) ? stages[number-1] : nil
    }

    // Geometry from the E2 frame (1180 wide): key 460×72, rows 74 apart, black keys 210×42.
    static let keySize = (width: 460.0, height: 72.0)
    static let rowStep = 74.0
    static let blackSize = (width: 210.0, height: 42.0)
    static let blackInset = 24.0
    static let designWidth = 1180.0
    // Left edge of each key in the design frame. The wave is 362 + 133·sin((n−13)·π/6),
    // nudged by a fixed amount per key so the stairs look hand-placed but never change.
    static let designX: [Double] = [370,415,463,505,486,408,367,310,236,248,222,288,374,412,488,478,500,418,348,314,235,252,225,310,354,450,462,504,458,441]
    static func wave(_ number: Int) -> Double { 362 + 133*sin(Double(number-13) * .pi/6) }
    // Horizontal offset of the key's centre from the screen centre.
    static func centerOffset(_ number: Int) -> Double {
        designX[number-1] + keySize.width/2 - designWidth/2
    }
    // A black key sits between `number` and `number+1`, except E–F and B–C.
    static func hasBlackKey(above number: Int) -> Bool {
        guard (1..<count).contains(number) else { return false }
        return !["E","B"].contains(DrillStage.letters[(number-1) % 7])
    }
    static let sideMargin = 16.0
    // How much of the wave fits: 1 on a landscape iPad, less on portrait or iPad mini,
    // where the wave is squeezed but every key keeps its full size.
    static func spread(width: Double) -> Double {
        let widest = (1...count).map { abs(centerOffset($0)) }.max() ?? 1
        return min(1,max(0,(width/2 - keySize.width/2 - sideMargin)/widest))
    }
    static func keyLeft(_ number: Int, width: Double) -> Double {
        width/2 + centerOffset(number)*spread(width:width) - keySize.width/2
    }
    // Black key's left edge: 24pt inside the more right-hand of the two keys.
    static func blackKeyLeft(above number: Int, width: Double) -> Double {
        max(keyLeft(number,width:width),keyLeft(number+1,width:width)) + blackInset
    }
    static func blackKeyName(above number: Int) -> String {
        let stage = DrillStage(number:number,game:.memoryRun,echoLevel:nil)
        return "\(stage.letter)#\(stage.octave)"
    }
}

// Stages can be solved in any order; a solved key stays pressed.
struct DrillStairsProgress: Codable, Equatable {
    private(set) var cleared: Set<Int> = []
    // The lowest stage not solved yet; `count+1` once every stage is solved.
    var next: Int { (1...DrillStairs.count).first { !cleared.contains($0) } ?? DrillStairs.count+1 }
    var isComplete: Bool { next > DrillStairs.count }
    func state(_ number: Int) -> DrillStageState {
        cleared.contains(number) ? .done : number == next ? .next : .open
    }
    // The black key above a solved stage goes down with it.
    func blackKeyPressed(above number: Int) -> Bool { cleared.contains(number) }
    // Returns false when the stage was already solved (or does not exist).
    @discardableResult mutating func clear(_ number: Int) -> Bool {
        guard (1...DrillStairs.count).contains(number) else { return false }
        return cleared.insert(number).inserted
    }
    static func load(_ data: Data?) throws -> Self {
        guard let data else { return Self() }
        var progress = try JSONDecoder().decode(Self.self,from:data)
        progress.cleared = progress.cleared.filter { (1...DrillStairs.count).contains($0) }
        return progress
    }
}
