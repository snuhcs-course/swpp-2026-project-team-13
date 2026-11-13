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

    func testSignatureLimitIncludesRelativeMajorMinorAndBothSignsCumulatively() {
        let cMajor = KeySignature(tonic:"C",mode:"major",fifths:0)
        let aMinor = KeySignature(tonic:"A",mode:"minor",fifths:0)
        let dMajor = KeySignature(tonic:"D",mode:"major",fifths:2)
        let bFlat = KeySignature(tonic:"Bb",mode:"major",fifths:-2)
        let eFlat = KeySignature(tonic:"Eb",mode:"major",fifths:-3)
        let keys = [cMajor,aMinor,gMajor,fMajor,dMinor,dMajor,bFlat,eFlat,noKey]
        let questions = keys.map { question($0,threeFour) }
        var filter = QuestionFilter()
        filter.keySelection = .maximumAccidentals(0)
        XCTAssertEqual(filter.apply(to:questions).map(\.keySignature),[cMajor,aMinor])
        filter.keySelection = .maximumAccidentals(1)
        XCTAssertEqual(filter.apply(to:questions).map(\.keySignature),Array(keys.prefix(5)))
        filter.keySelection = .maximumAccidentals(2)
        XCTAssertEqual(filter.apply(to:questions).map(\.keySignature),Array(keys.prefix(7)))
        XCTAssertNil(filter.key)
        filter.key = eFlat
        XCTAssertEqual(filter.apply(to:questions).map(\.keySignature),[eFlat])
        filter.key = nil
        XCTAssertFalse(filter.isActive)
    }

    func testIndividualKeysUseOrAndMeterUsesAnd() {
        let a = question(gMajor,threeFour), b = question(dMinor,threeFour)
        var filter = QuestionFilter(meter:threeFour)
        filter.keySelection = .individual([gMajor,dMinor])
        XCTAssertEqual(filter.apply(to:[a,question(gMajor,sixEight),b,question(fMajor,threeFour)]),[a,b])
        filter.keySelection = .individual([])
        XCTAssertTrue(filter.apply(to:[a,b]).isEmpty)
        let groups = QuestionFilter.keyGroups(in:[a,b,question(fMajor,threeFour),question(noKey,threeFour)])
        XCTAssertEqual(groups.map(\.fifths),[0,1,-1])
        XCTAssertEqual(groups.last?.keys,[fMajor,dMinor])
    }

    func testDifficultySortIsStableWithUnknownScoresLastAndCompletionHiddenByDefault() {
        var high = question(gMajor,threeFour), low = question(gMajor,threeFour)
        let unknown = question(gMajor,threeFour)
        high.difficultyScore = 24; low.difficultyScore = 13
        var tied = question(gMajor,threeFour); tied.difficultyScore = 13
        let questions = [high,unknown,low,tied]
        var filter = QuestionFilter()
        XCTAssertFalse(filter.showCompleted)
        XCTAssertEqual(filter.apply(to:questions),[low,tied,high,unknown])
        filter.sortOrder = .descending
        XCTAssertEqual(filter.apply(to:questions),[high,low,tied,unknown])
        XCTAssertEqual(filter.apply(to:questions,completedQuestionIDs:[high.id]),[low,tied,unknown])
        low.practiceCompleted = true
        XCTAssertEqual(filter.apply(to:[high,low]),[high])
        filter.showCompleted = true
        XCTAssertEqual(filter.apply(to:[high,low],completedQuestionIDs:[high.id]),[high,low])
    }
}
