import XCTest
@testable import SolfegeCore

final class DrillCurriculumV2Tests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("IPadApp/IPadApp/Resources")
    }
    func testTenMemoryKeysHaveTheRequestedCeilingsAndCourseValidates() throws {
        let data=try Data(contentsOf:resources.appendingPathComponent("drill-stage-sets-v2.json"))
        let course=try ContractJSON.decoder().decode(DrillStageCourse.self,from:data)
        try course.validate(); XCTAssertEqual(course.stages.count,20)
        let memory=course.stages.filter { $0.game == .memoryRun }
        XCTAssertEqual(memory.count,10)
        XCTAssertEqual(memory.compactMap { DrillMemoryPolicy.maximumFifths(stair:$0.number) },[0,0,1,1,2,2,3,3,7,7])
        for stage in memory {
            let cap=try XCTUnwrap(DrillMemoryPolicy.maximumFifths(stair:stage.number))
            for q in stage.questions { XCTAssertLessThanOrEqual(abs(try XCTUnwrap(q.keyFifths)),cap) }
        }
        XCTAssertNil(DrillMemoryPolicy.maximumFifths(stair:1))
    }
    func testCurrentMemoryCatalogKeepsClassicalTempoAndGrooveHash() throws {
        let data=try Data(contentsOf:resources.appendingPathComponent("memory-run-v3.json"))
        var bank=try JSONDecoder().decode(MemoryCatalog.self,from:data)
        let policy=try JSONDecoder().decode(MemoryGroovePolicy.self,from:Data(contentsOf:resources.appendingPathComponent("memory-groove-v2.json")))
        try bank.applyGroovePolicy(policy,catalogSha256:data.sha256); try bank.validate()
        for source in bank.sources where source.collection == "classical" { XCTAssertNotNil(source.quarterBpm); XCTAssertNotNil(source.tempoBeatUnit) }
        var settings=MelodySettings(); settings.bpm=200; XCTAssertNoThrow(try settings.validate())
    }
    func testNewRhythmCatalogAndLegacyVersionBothValidate() throws {
        for name in ["rhythm-puzzle-v3.json","rhythm-puzzle-v4.json"] {
            let bank=try ContractJSON.decoder().decode(RhythmCatalog.self,from:Data(contentsOf:resources.appendingPathComponent(name)))
            try bank.validate()
        }
    }
}
