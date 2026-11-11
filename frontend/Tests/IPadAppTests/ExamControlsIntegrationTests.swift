import XCTest
import PencilKit
import SwiftUI
import ImageIO
@testable import IPadApp

@MainActor final class ExamControlsIntegrationTests: XCTestCase {
    func testRapidSkippingDuringAudioAndLeadStartsOnlyTheLastChosenSegment() async throws {
        let api = try DemoExamAPI(outcome:"completed")
        let list = try await api.questions(page:1)
        let q = try await api.question(try XCTUnwrap(list.results.first?.id))
        let mainData = try await api.asset(q.scoreAssets.main.url,authenticated:true,limit:1_048_576)
        let scaleData = try await api.asset(q.scoreAssets.scale.url,authenticated:true,limit:1_048_576)
        let main = try MusicXMLParser.parseMXL(mainData,asset:q.scoreAssets.main)
        let scale = try MusicXMLParser.parseMXL(scaleData,asset:q.scoreAssets.scale)
        let player = PianoPlayback(); defer { player.pause() }
        try player.prepare(main:main,scale:scale,plan:.exam(meter:q.timeSignature,scaleMeasures:scale.measures))
        player.restore(PlaybackCursor(index:1,phase:"segment"))
        let next = expectation(description:"Next segment starts")
        var nextStarted: TimeInterval?, advances = 0
        player.onCursor = { cursor in
            if cursor.index == 4 && cursor.phase == "segment" && nextStarted == nil {
                nextStarted = ProcessInfo.processInfo.systemUptime; advances += 1; next.fulfill()
            }
        }
        player.resume()
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertTrue(player.canSkipWritingWait)
        let began = ProcessInfo.processInfo.systemUptime
        player.skipWritingWait(); player.skipWritingWait(); player.skipWritingWait()
        XCTAssertEqual(player.cursor.index,3); XCTAssertEqual(player.cursor.shortenedGap,true)
        XCTAssertTrue(player.canSkipWritingWait)
        await fulfillment(of:[next],timeout:5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(nextStarted)-began,1.4)
        XCTAssertLessThan(try XCTUnwrap(nextStarted)-began,3.5)
        XCTAssertEqual(advances,1)
        XCTAssertEqual(player.cursor.index,4)
        // Skip once more after real audio has begun, then pause/restart while
        // the lead is pending. The target and remaining lead must survive.
        player.skipWritingWait()
        XCTAssertEqual(player.cursor.nextSegmentIndex,5)
        try await Task.sleep(for:.milliseconds(200))
        player.pause()
        let saved = player.cursor
        XCTAssertLessThan(try XCTUnwrap(saved.remainingWaitMs),1500)
        player.restore(saved); player.resume()
        XCTAssertEqual(player.cursor.nextSegmentIndex,5)
    }
    func testUndoAndRedoAvailabilityFollowsTheUndoStack() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene:scene), drawing = DrawingController()
        window.addSubview(drawing.canvas); window.isHidden = false
        defer { drawing.canvas.removeFromSuperview(); window.isHidden = true }
        let manager = try XCTUnwrap(drawing.canvas.undoManager)
        manager.removeAllActions(); drawing.syncUndoState()
        XCTAssertFalse(drawing.canUndo); XCTAssertFalse(drawing.canRedo)
        func registerChange() {
            manager.registerUndo(withTarget:drawing) { target in
                manager.registerUndo(withTarget:target) { _ in }
            }
        }
        // A change made outside the buttons, as a Pencil stroke is, has to reach the state on its own.
        manager.beginUndoGrouping(); registerChange(); manager.endUndoGrouping()
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertTrue(drawing.canUndo); XCTAssertFalse(drawing.canRedo)
        drawing.undo()
        XCTAssertFalse(drawing.canUndo); XCTAssertTrue(drawing.canRedo)
        drawing.redo()
        XCTAssertTrue(drawing.canUndo); XCTAssertFalse(drawing.canRedo)
        drawing.load(PKDrawing())
        XCTAssertFalse(drawing.canUndo); XCTAssertFalse(drawing.canRedo)
    }
    func testDemoRecommendationNeverOffersClassical() async throws {
        let api = try DemoExamAPI(outcome:"completed")
        var seen = Set<UUID>()
        for _ in 0..<200 {
            let q = try await api.recommendedQuestion()
            XCTAssertNotEqual(q.collection,"classical"); seen.insert(q.id)
        }
        XCTAssertEqual(seen.count,1)
    }
    func testRecommendedExamHoldsItsQuestionUntilTheAttemptExists() async throws {
        let model = AppModel(); model.demo = true; model.demoOutcome = "completed"; await model.connect()
        let started = ContinuousClock.now
        let loading = Task { await model.startRecommendedExam() }
        while model.screen == .main { await Task.yield() }
        XCTAssertEqual(model.screen,.recommendingExam)
        await loading.value
        XCTAssertGreaterThanOrEqual(ContinuousClock.now-started,AppModel.recommendationMinimum)
        XCTAssertNil(model.error); XCTAssertEqual(model.screen,.examSelection)
        let offer = try XCTUnwrap(model.examOffer)
        await model.startRecommendedExam()
        XCTAssertEqual(model.examOffer,offer)
        let choice = try XCTUnwrap(offer.choices.first { $0.category == "matched" && $0.questionId != nil })
        await model.chooseExam(choice)
        XCTAssertEqual(model.screen,.question); XCTAssertEqual(model.questionLibraryScreen,.examSelection)
        await model.begin()
        XCTAssertNil(model.error); XCTAssertEqual(model.session?.attempt.question.id,choice.questionId)
        await model.startRecommendedExam()
        XCTAssertFalse(try XCTUnwrap(model.examOffer).choices.contains { $0.questionId == choice.questionId })
    }
    func testRecommendedExamRecoversPendingCreationInsteadOfReplacingIt() async throws {
        let model = AppModel(); model.demo = true; model.demoOutcome = "completed"; await model.connect()
        let q = try await DemoExamAPI(outcome:"completed").recommendedQuestion()
        let store = try LocalStore(scope:"sori-local-demo-v3:" + (try XCTUnwrap(model.profile)).id.uuidString)
        try store.savePending(PendingCreation(question:q,key:UUID(),mode:.exam))
        XCTAssertTrue(model.pendingCreation)
        await model.startRecommendedExam()
        XCTAssertNil(model.error); XCTAssertFalse(model.pendingCreation)
        XCTAssertEqual(model.session?.attempt.question.id,q.id); XCTAssertEqual(model.screen,.exam)
    }
    func testClassicalIsPracticeOnlyAndReturnsToItsLibrary() async throws {
        let model = AppModel(); model.demo = true; model.demoOutcome = "completed"; await model.connect(); await model.loadClassical()
        let q = try XCTUnwrap(model.classicalQuestions.first)
        model.selectedMode = .exam; model.navigate(.classical)
        XCTAssertEqual(model.selectedMode,.practice)
        await model.choose(q.id,mode:.practice)
        XCTAssertEqual(model.questionLibraryScreen,.classical)
        await model.choose(q.id,mode:.exam)
        XCTAssertEqual(model.questionLibraryScreen,.classical)
        await model.begin(); await model.start(); model.player.pause(); await model.submit()
        XCTAssertNil(model.error); XCTAssertEqual(model.screen,.result)
        XCTAssertEqual(model.resultLibraryScreen,.classical)
    }
    func testScaleNoticeUsesActualScaleKeyAndRendersBeforePlayback() async throws {
        let model = AppModel(); model.demo = true
        await model.connect(); await model.loadClassical()
        let q = try XCTUnwrap(model.classicalQuestions.first(where: { $0.composer == "브람스" && $0.keySignature.mode == "minor" }))
        await model.choose(q.id,mode:.practice); await model.begin()
        XCTAssertNil(model.error); XCTAssertTrue(model.player.showsScaleNotice)
        XCTAssertEqual(model.player.scaleKey,q.keySignature)
        XCTAssertEqual(model.player.scaleKey?.mode,"minor")
        let renderer = ImageRenderer(content:ExamView(model:model,drawing:model.drawing,player:model.player).frame(width:1194,height:834))
        renderer.scale = 2
        let attachment = XCTAttachment(image:try XCTUnwrap(renderer.uiImage)); attachment.name = "exam-scale-notice"; attachment.lifetime = .keepAlways; add(attachment)
        model.player.restore(PlaybackCursor(index:1,phase:"segment"))
        XCTAssertFalse(model.player.showsScaleNotice)
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
        await restored.startRecommendedExam(); await restored.chooseExam(try XCTUnwrap(restored.examOffer?.choices.first { $0.category == "matched" && $0.questionId != nil })); await restored.begin()
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
