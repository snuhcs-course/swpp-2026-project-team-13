import XCTest
import PencilKit
import SwiftUI
import ImageIO
@testable import IPadApp

@MainActor final class IntegrationTests:XCTestCase {
    func testDemoReferenceAssetRoutesReturnPinnedPNGWithOrWithoutSlash() async throws {
        let api = try DemoExamAPI(outcome:"completed")
        let page = try await api.questions(page:1)
        for summary in page.results {
            let q = try await api.question(summary.id)
            let asset = try XCTUnwrap(q.correctScore)
            let withoutSlash = asset.url.absoluteString.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            for address in [withoutSlash,withoutSlash+"/"] {
                let url = try XCTUnwrap(URL(string:address))
                let bytes = try await api.asset(url,authenticated:true,limit:2_097_152)
                XCTAssertEqual(bytes.prefix(8),Data([137,80,78,71,13,10,26,10]),"Expected PNG for \(address)")
                XCTAssertEqual(bytes.sha256,asset.sha256)
                XCTAssertNotNil(UIImage(data:bytes))
            }
        }
    }
    func testReferenceImagesAndCompactAnswerRenderTogether() async throws {
        let api = try DemoExamAPI(outcome:"completed")
        let questions = try await api.questions(page:1)
        for summary in questions.results {
            let q = try await api.question(summary.id)
            let asset = try XCTUnwrap(q.correctScore)
            let data = try await api.asset(asset.url,authenticated:true,limit:2_097_152)
            XCTAssertEqual(data.sha256,asset.sha256)
            let reference = try XCTUnwrap(UIImage(data:data))
            XCTAssertEqual(reference.cgImage?.width,asset.pixelWidth)
            let template = try AnswerExporter.validateTemplate(Bundled.data(q.sheetLayout.id,ext:"png"),layout:q.sheetLayout)
            let renderer = ImageRenderer(content:VStack(alignment:.leading,spacing:12) {
                Text("정답 악보")
                Image(uiImage:reference).resizable().scaledToFit()
                Text("내 악보")
                CompactAnswerView(image:template,layout:q.sheetLayout,annotation:nil)
            }.padding(20).frame(width:1024).background(.white))
            renderer.scale = 2
            let rendered = try XCTUnwrap(renderer.uiImage)
            XCTAssertLessThan(rendered.size.height,700)
            let attachment = XCTAttachment(image:rendered)
            attachment.name = "comparison-"+q.title; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    func testVoiceSelectionPersistsAndCanPrepareNextProblem() async throws {
        let saved = UserDefaults.standard.string(forKey:"sori.voice")
        defer { UserDefaults.standard.set(saved,forKey:"sori.voice") }
        let model = AppModel(); model.demo = true
        await model.connect(); XCTAssertNil(model.error)
        for voice in model.instrumentVoices {
            model.selectVoice(voice.id)
            await model.choose(try XCTUnwrap(model.questions.first?.id)); await model.begin()
            XCTAssertNil(model.error); XCTAssertTrue(model.prepared)
            XCTAssertEqual(model.player.voiceId,voice.id)
            let restored = AppModel()
            XCTAssertEqual(restored.selectedVoice,voice.id)
            model.player.pause()
        }
    }
    func testPNGExportHasFixedSizeOpaqueSRGBAndCorrectCoordinates() throws {
        let q:Question=try Bundled.decode("question")
        let template=try AnswerExporter.validateTemplate(Bundled.data("staff-8bars-v1",ext:"png"),layout:q.sheetLayout)
        // A short stroke at a known logical position must land at twice those coordinates.
        let points=[PKStrokePoint(location:CGPoint(x:100,y:100),timeOffset:0,size:CGSize(width:4,height:4),opacity:1,force:1,azimuth:0,altitude:.pi/2),PKStrokePoint(location:CGPoint(x:140,y:100),timeOffset:0.1,size:CGSize(width:4,height:4),opacity:1,force:1,azimuth:0,altitude:.pi/2)]
        let drawing=PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date()))])
        let bytes=try AnswerExporter.png(template:template,drawing:drawing,layout:q.sheetLayout)
        let source=try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData,nil)),image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        XCTAssertEqual(image.width,2660);XCTAssertEqual(image.height,1692);XCTAssertEqual(image.bitsPerComponent,8)
        let data=try XCTUnwrap(image.dataProvider?.data) as Data, bpp=image.bitsPerPixel/8
        // Exported top-left stroke is near x=240,y=200, not vertically flipped.
        let position=200*image.bytesPerRow+240*bpp
        XCTAssertLessThan(data[position],80)
        let white=20*image.bytesPerRow+20*bpp;XCTAssertEqual(data[white],255)
        XCTAssertLessThan(bytes.count,10_485_760)
        if image.alphaInfo == .last || image.alphaInfo == .premultipliedLast {
            for y in stride(from:0,to:1692,by:31) { for x in stride(from:0,to:2660,by:31) { XCTAssertEqual(data[y*image.bytesPerRow+x*bpp+3],255) } }
        }
        let attachment=XCTAttachment(data:bytes,uniformTypeIdentifier:"public.png");attachment.name="contract-answer-2660x1692";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testLocalJournalPersistsImmutableSubmissionKeysAndDrawing() throws {
        let store=try LocalStore(scope:"test-journal-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:store.root) }
        var r=SessionRecord(attempt:try Bundled.decode("attempt-started"));r.clientAnswerId=UUID();r.uploadKey=UUID();r.submitKey=UUID();r.frozen=true
        let drawing=PKDrawing().dataRepresentation();try store.write(drawing,name:"drawing.pkdrawing",id:r.id)
        let png=Data([1,2,3,4]);try store.write(png,name:"submission.png",id:r.id);try store.save(r)
        let recovered=try store.load(r.id);XCTAssertEqual(recovered.uploadKey,r.uploadKey);XCTAssertEqual(recovered.submitKey,r.submitKey);XCTAssertTrue(recovered.frozen)
        XCTAssertEqual(try store.read("submission.png",id:r.id),png);XCTAssertEqual(try store.read("drawing.pkdrawing",id:r.id),drawing)
    }
    func testRealAppFlowPrepareStartSubmitAndRestoreResult() async throws {
        let model=AppModel();model.demo=true;model.demoOutcome="completed";await model.connect()
        XCTAssertNil(model.error);XCTAssertTrue(model.connected)
        await model.choose(try XCTUnwrap(model.questions.first?.id));await model.begin()
        XCTAssertNil(model.error);XCTAssertTrue(model.prepared);XCTAssertEqual(model.session?.attempt.status,"ready")
        let id=try XCTUnwrap(model.session?.id)
        await model.start();model.player.pause();XCTAssertNil(model.error);XCTAssertEqual(model.session?.attempt.status,"in_progress")
        await model.submit();XCTAssertNil(model.error);XCTAssertEqual(model.session?.attempt.status,"submitted");XCTAssertEqual(model.screen,.result)
        let submitted=try XCTUnwrap(model.session?.attempt.submittedAnswerId)
        try await Task.sleep(for:.seconds(5));await model.refreshResult()
        XCTAssertNil(model.error);XCTAssertEqual(model.session?.grading?.status,"completed");XCTAssertEqual(model.session?.grading?.answerId,submitted);XCTAssertNotNil(model.submittedImage);XCTAssertNotNil(model.correctScoreImage)
        let restored=AppModel();restored.demo=true;await restored.connect();await restored.open(try XCTUnwrap(restored.history.first(where:{$0.id==id})))
        XCTAssertNil(restored.error);XCTAssertEqual(restored.session?.attempt.submittedAnswerId,submitted);XCTAssertEqual(restored.session?.grading?.status,"completed")
    }
    func testDemoBackendIdempotencyAndOtherTerminalOutcomes() async throws {
        for outcome in ["needs-review","failed"] {
            let api=try DemoExamAPI(outcome:outcome),q:Question=try Bundled.decode("question"),key=UUID()
            let a=try await api.createAttempt(question:q,key:key),same=try await api.createAttempt(question:q,key:key);XCTAssertEqual(a.id,same.id)
            let started=try await api.start(a.id),twice=try await api.start(a.id);XCTAssertEqual(started.startedAt,twice.startedAt)
            let png=try Bundled.data("staff-8bars-v1",ext:"png"),client=UUID(),up=UUID()
            let answer=try await api.upload(a.id,png:png,clientId:client,layout:q.sheetLayout.id,key:up)
            let reupload=try await api.upload(a.id,png:png,clientId:client,layout:q.sheetLayout.id,key:up);XCTAssertEqual(reupload.id,answer.id)
            let g=try await api.submit(a.id,answerId:answer.id,key:UUID())
            let resubmit=try await api.submit(a.id,answerId:answer.id,key:UUID());XCTAssertEqual(resubmit.jobId,g.jobId)
            try await Task.sleep(for:.seconds(4.1));let result=try await api.result(a.id)
            XCTAssertEqual(result.status,outcome == "needs-review" ? "needs_review":"failed");XCTAssertNil(result.score)
            if outcome == "failed" {
                let retryKey=UUID();let retried=try await api.retryGrading(a.id,key:retryKey)
                XCTAssertNotEqual(retried.jobId,g.jobId);XCTAssertEqual(retried.answerId,answer.id)
                let sameRetry=try await api.retryGrading(a.id,key:retryKey);XCTAssertEqual(sameRetry.jobId,retried.jobId)
            }
        }
    }
    func testPianoPlaysScaleAndAllElevenSegmentsWithoutPlaybackFailure() async throws {
        let a:Attempt = try Bundled.decode("attempt-ready")
        let main = try MusicXMLParser.parseMXL(Bundled.data("practice-01-main",ext:"mxl"),asset:a.question.scoreAssets.main,tempo:96)
        let scale = try MusicXMLParser.parseMXL(Bundled.data("practice-01-scale",ext:"mxl"),asset:a.question.scoreAssets.scale,tempo:96)
        var plan = a.playbackPlan
        plan.tempoBpm=200;plan.pauseAfterScaleMs=0
        for i in plan.steps.indices {plan.steps[i].pauseAfterMs=0}
        let player=PianoPlayback()
        var playbackError:Error?
        player.onError={playbackError=$0}
        try player.prepare(main:main,scale:scale,plan:plan)
        player.restore(PlaybackCursor());player.resume()
        let deadline=Date().addingTimeInterval(65)
        while player.isPlaying && Date()<deadline {try await Task.sleep(for:.milliseconds(200))}
        XCTAssertNil(playbackError)
        XCTAssertEqual(player.cursor.index,12)
        XCTAssertFalse(player.isPlaying)
        player.pause()
    }


    func testAllThreeMetersLoadTheCountInClickResource() throws {
        let questions:[Question] = try Bundled.decode("practice-catalog")
        for (index,q) in questions.enumerated() {
            let main = try MusicXMLParser.parseMXL(Bundled.data("excerpt-\(index+1)-v2-main",ext:"mxl"),asset:q.scoreAssets.main,tempo:96)
            let scale = try MusicXMLParser.parseMXL(Bundled.data("excerpt-\(index+1)-v2-scale",ext:"mxl"),asset:q.scoreAssets.scale,tempo:96)
            let player = PianoPlayback()
            try player.prepare(main:main,scale:scale,plan:.exam(meter:q.timeSignature))
            player.pause()
        }
    }
}
