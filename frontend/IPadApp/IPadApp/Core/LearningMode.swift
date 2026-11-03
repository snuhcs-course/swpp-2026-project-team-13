import Foundation

enum StudyMode: String, Codable, CaseIterable, Identifiable {
    case practice, exam
    var id: String { rawValue }
    var title: String { self == .practice ? "Practice" : "Exam" }
    var detail: String { self == .practice ? "정답과 비교하며 마디별로 직접 채점해요" : "추천 문제로 시험을 보고 AI 채점과 피드백을 받아요" }
}

enum SelfAssessmentErrorType: String, CaseIterable, Identifiable {
    case pitch, rhythm, other
    var id: String { rawValue }
    var title: String { ["pitch":"음정", "rhythm":"리듬", "other":"기타"][rawValue] ?? rawValue }
}

struct MeasureError: Codable, Equatable, Identifiable {
    var measure: Int
    var types: [String]
    var id: Int { measure }
    var label: String { types.map { SelfAssessmentErrorType(rawValue:$0)?.title ?? $0 }.joined(separator:" · ") }
}

enum SelfAssessmentEdits {
    static func normalized(_ errors: [MeasureError], measureCount: Int) throws -> [MeasureError] {
        var seen = Set<Int>()
        let order = SelfAssessmentErrorType.allCases.map(\.rawValue)
        guard measureCount > 0, errors.count <= measureCount else { throw SolfegeError.configuration("마디별 오류 기록을 확인해 주세요.") }
        return try errors.map { error in
            guard (1...measureCount).contains(error.measure), seen.insert(error.measure).inserted,
                  !error.types.isEmpty, Set(error.types).count == error.types.count,
                  error.types.allSatisfy({ order.contains($0) }) else {
                throw SolfegeError.configuration("마디 번호와 음정·리듬·기타 항목을 확인해 주세요.")
            }
            return MeasureError(measure:error.measure, types:order.filter { error.types.contains($0) })
        }.sorted { $0.measure < $1.measure }
    }

    static func toggling(_ errors: [MeasureError], measure: Int, type: SelfAssessmentErrorType, measureCount: Int) throws -> [MeasureError] {
        guard measureCount > 0, (1...measureCount).contains(measure) else { throw SolfegeError.configuration("마디 번호를 확인해 주세요.") }
        var values = try normalized(errors,measureCount:measureCount)
        if let index = values.firstIndex(where: { $0.measure == measure }) {
            if values[index].types.contains(type.rawValue) { values[index].types.removeAll { $0 == type.rawValue } }
            else { values[index].types.append(type.rawValue) }
            if values[index].types.isEmpty { values.remove(at:index) }
        } else { values.append(MeasureError(measure:measure,types:[type.rawValue])) }
        return try normalized(values,measureCount:measureCount)
    }
}

struct PracticeAssessment: Codable, Equatable {
    var attemptId: UUID; var answerId: UUID
    var mode: String; var gradingMode: String; var source: String
    var featureAnalysisId: UUID?
    var status: String; var revision: Int; var errors: [MeasureError]
    var completedAt: Date?; var updatedAt: Date; var serverTime: Date
    var isCompleted: Bool { status == "completed" }

    func validate(attemptId: UUID, answerId: UUID, measureCount: Int) throws {
        guard self.attemptId == attemptId, self.answerId == answerId,
              mode == "practice", gradingMode == "self", source == "self", revision >= 0,
              ["pending","completed"].contains(status), isCompleted == (completedAt != nil) else {
            throw SolfegeError.transport("자기채점 기록이 제출 답안과 일치하지 않습니다.")
        }
        _ = try SelfAssessmentEdits.normalized(errors,measureCount:measureCount)
    }
}

struct SelfAssessmentWrite: Codable, Equatable {
    var expectedRevision: Int
    var errors: [MeasureError]
    var completed: Bool
}

struct PendingSelfAssessment: Codable {
    var key: UUID
    var request: SelfAssessmentWrite
}
