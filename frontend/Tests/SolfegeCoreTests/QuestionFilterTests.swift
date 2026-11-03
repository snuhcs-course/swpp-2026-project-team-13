import XCTest
import Foundation
@testable import SolfegeCore

final class QuestionFilterTests: XCTestCase {
    private let gMajor = KeySignature(tonic:"G",mode:"major",fifths:1)
    private let fMajor = KeySignature(tonic:"F",mode:"major",fifths:-1)
    private let dMinor = KeySignature(tonic:"D",mode:"minor",fifths:-1)
    private let noKey = KeySignature(tonic:"C",mode:"unspecified",fifths:0)
    private let threeFour = TimeSignature(numerator:3,denominator:4)
    private let sixEight = TimeSignature(numerator:6,denominator:8)
    private let twoTwo = TimeSignature(numerator:2,denominator:2)

    private func question(_ key: KeySignature, _ meter: TimeSignature) -> QuestionSummary {
        QuestionSummary(id:UUID(),version:1,title:"문제",source:"test",keySignature:key,timeSignature:meter,measureCount:8,recommendedDurationSeconds:60)
    }

    func testEmptyFilterKeepsEveryQuestionInOrder() {
        let questions = [question(gMajor,sixEight),question(dMinor,threeFour)]
        XCTAssertEqual(QuestionFilter().apply(to:questions),questions)
        XCTAssertFalse(QuestionFilter().isActive)
    }
    func testKeyAndMeterNarrowTogether() {
        let match = question(gMajor,threeFour)
        let questions = [question(gMajor,sixEight),match,question(dMinor,threeFour)]
        XCTAssertEqual(QuestionFilter(key:gMajor).apply(to:questions).count,2)
        XCTAssertEqual(QuestionFilter(meter:threeFour).apply(to:questions).count,2)
        XCTAssertEqual(QuestionFilter(key:gMajor,meter:threeFour).apply(to:questions),[match])
        XCTAssertEqual(QuestionFilter(key:noKey,meter:threeFour).apply(to:questions),[])
        XCTAssertTrue(QuestionFilter(meter:threeFour).isActive)
    }
    func testSameTonicInAnotherModeDoesNotMatch() {
        let cMajor = KeySignature(tonic:"C",mode:"major",fifths:0)
        let questions = [question(noKey,threeFour),question(cMajor,threeFour)]
        XCTAssertEqual(QuestionFilter(key:cMajor).apply(to:questions).map(\.keySignature),[cMajor])
        XCTAssertEqual(QuestionFilter(key:noKey).apply(to:questions).map(\.keySignature),[noKey])
    }
    func testOptionsAreUniqueAndOrdered() {
        let questions = [question(noKey,sixEight),question(dMinor,threeFour),question(gMajor,twoTwo),question(fMajor,threeFour),question(gMajor,sixEight)]
        XCTAssertEqual(QuestionFilter.keyOptions(in:questions),[fMajor,gMajor,dMinor,noKey])
        XCTAssertEqual(QuestionFilter.meterOptions(in:questions),[twoTwo,threeFour,sixEight])
        XCTAssertEqual(QuestionFilter.meterOptions(in:questions).map(\.label),["2/2","3/4","6/8"])
        XCTAssertEqual(QuestionFilter.keyOptions(in:[]),[])
    }
}
