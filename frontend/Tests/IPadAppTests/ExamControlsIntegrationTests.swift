import XCTest
import PencilKit
import SwiftUI
import ImageIO
@testable import IPadApp

@MainActor final class ExamControlsIntegrationTests: XCTestCase {
    func testSkipWritingWaitStartsNextSegmentAfterLeadWithoutReplayingCurrentSegment() async throws {
        let api = try DemoExamAPI(outcome:"completed")
        let list = try await api.questions(page:1)
        let q = try await api.question(try XCTUnwrap(list.results.first?.id))
        let mainData = try await api.asset(q.scoreAssets.main.url,authenticated:true,limit:1_048_576)
        let scaleData = try await api.asset(q.scoreAssets.scale.url,authenticated:true,limit:1_048_576)
        let main = try MusicXMLParser.parseMXL(mainData,asset:q.scoreAssets.main)
        let scale = try MusicXMLParser.parseMXL(scaleData,asset:q.scoreAssets.scale)
        let player = PianoPlayback(); defer { player.pause() }
        try player.prepare(main:main,scale:scale,plan:.exam(meter:q.timeSignature,scaleMeasures:scale.measures))
        player.restore(PlaybackCursor(index:1,phase:"gap",remainingWaitMs:20000))
        let next = expectation(description:"Next segment starts")
        var nextStarted: TimeInterval?, advances = 0
        player.onCursor = { cursor in
            if cursor.index == 2 && cursor.phase == "segment" && nextStarted == nil {
                nextStarted = ProcessInfo.processInfo.systemUptime; advances += 1; next.fulfill()
            }
        }
        player.resume()
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertTrue(player.canSkipWritingWait)
        let began = ProcessInfo.processInfo.systemUptime
        player.skipWritingWait(); player.skipWritingWait()
        XCTAssertEqual(player.cursor.index,1); XCTAssertEqual(player.cursor.shortenedGap,true)
        XCTAssertFalse(player.canSkipWritingWait)
        await fulfillment(of:[next],timeout:7)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(nextStarted)-began,2.8)
        XCTAssertEqual(advances,1)
        XCTAssertEqual(player.cursor.index,2)
    }
    func testDemoToggleAppliesImmediatelyAndPersistsAcrossTabsAndAppModels() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey:"sori.demo")
        defer { if let saved { defaults.set(saved,forKey:"sori.demo") } else { defaults.removeObject(forKey:"sori.demo") } }
        let model = AppModel(); model.demo = false; model.screen = .settings
        await model.setDemoMode(true)
        XCTAssertNil(model.error); XCTAssertTrue(model.connected); XCTAssertTrue(model.demo)
        XCTAssertEqual(model.screen,.settings)
        model.navigate(.home); model.navigate(.settings)
        XCTAssertTrue(model.demo); XCTAssertTrue(defaults.bool(forKey:"sori.demo"))
        let restored = AppModel(); XCTAssertTrue(restored.demo)
        await restored.connect()
        await restored.choose(try XCTUnwrap(restored.questions.first?.id)); await restored.begin()
        XCTAssertNil(restored.error); XCTAssertEqual(restored.session?.attempt.gradingMode,"demo")
        restored.player.pause()
        // A failed live connection must still remember the chosen mode and must
        // not leave the old demo API active under a live-mode setting.
        model.server = "invalid-server"; await model.setDemoMode(false)
        XCTAssertFalse(model.demo); XCTAssertFalse(model.connected)
        XCTAssertFalse(defaults.bool(forKey:"sori.demo")); XCTAssertFalse(AppModel().demo)
    }
    func testCompactSheetExportsSecondSystemStrokesAtCanonicalCoordinates() async throws {
        let api = try DemoExamAPI(outcome:"completed")
        let list = try await api.questions(page:1)
        let q = try await api.question(try XCTUnwrap(list.results.first?.id))
        XCTAssertEqual(q.sheetLayout.displayHeight,620)
        let templateData = try await api.asset(q.sheetLayout.templatePngUrl,authenticated:false,limit:10_485_760)
        let template = try AnswerExporter.validateTemplate(templateData,layout:q.sheetLayout)
        let points = [PKStrokePoint(location:CGPoint(x:200,y:450),timeOffset:0,size:CGSize(width:4,height:4),opacity:1,force:1,azimuth:0,altitude:.pi/2),PKStrokePoint(location:CGPoint(x:240,y:450),timeOffset:0.1,size:CGSize(width:4,height:4),opacity:1,force:1,azimuth:0,altitude:.pi/2)]
        let drawing = PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date()))])
        let data = try AnswerExporter.png(template:template,drawing:drawing,layout:q.sheetLayout)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        XCTAssertEqual(image.width,2660); XCTAssertEqual(image.height,1692)
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertLessThan(bytes[900*image.bytesPerRow+440*(image.bitsPerPixel/8)],80)
        let attachment = XCTAttachment(data:data,uniformTypeIdentifier:"public.png"); attachment.name = "compact-sheet-canonical-export"; attachment.lifetime = .keepAlways; add(attachment)
        // All previous sheets remain routable for old snapshot restoration.
        let old: [Question] = try Bundled.decode("practice-catalog")
        let oldTemplate = try await api.asset(old[0].sheetLayout.templatePngUrl,authenticated:false,limit:10_485_760)
        XCTAssertEqual(oldTemplate.sha256,old[0].sheetLayout.templateSha256)
    }
}
