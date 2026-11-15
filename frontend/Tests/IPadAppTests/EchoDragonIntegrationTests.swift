import XCTest
import SwiftUI
@testable import IPadApp

@MainActor final class EchoDragonIntegrationTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUp() async throws {
        suite = "echo-dragon-tests-"+UUID().uuidString
        defaults = UserDefaults(suiteName:suite)!
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName:suite) }
    private func settled(_ game: EchoDragonModel) async throws {
        for _ in 0..<400 where game.isPlaying { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertFalse(game.isPlaying)
        XCTAssertNil(game.error)
    }
    func testListenSelectSubmitAndReloadUnlockExactlyOneLevel() async throws {
        let audio = SilentDragonAudio()
        let game = EchoDragonModel(defaults:defaults,audio:audio)
        game.open(1)
        let challenge = try XCTUnwrap(game.challenge)
        game.select(challenge.answer); game.submit()
        XCTAssertNil(game.selected); XCTAssertEqual(game.progress.unlocked,1)
        game.listen(); try await settled(game)
        XCTAssertEqual(audio.notes,[challenge.callRoot,challenge.callEnd,challenge.replyRoot])
        game.select(challenge.answer); try await settled(game); game.submit()
        XCTAssertEqual(game.result,.correct); XCTAssertEqual(game.stars,3)
        XCTAssertEqual(game.progress.unlocked,2)
        game.submit(); XCTAssertEqual(game.attempts,1,"Duplicate submit is ignored")
        let restored = EchoDragonModel(defaults:defaults,audio:SilentDragonAudio())
        XCTAssertEqual(restored.progress.stars[1],3)
        XCTAssertEqual(restored.progress.unlocked,2)
        game.next(); XCTAssertEqual(game.challenge?.level.number,2)
    }
    func testWrongAnswerHintAndComparisonKeepTheSamePuzzleAndStoreAssistedStar() async throws {
        let game = EchoDragonModel(defaults:defaults,audio:SilentDragonAudio())
        game.open(1); let challenge = try XCTUnwrap(game.challenge)
        game.listen(); try await settled(game)
        let wrong = try XCTUnwrap(challenge.choices.first { $0 != challenge.answer })
        game.select(wrong); try await settled(game); game.submit()
        XCTAssertEqual(game.result,.incorrect); XCTAssertEqual(game.progress.unlocked,1)
        XCTAssertEqual(game.challenge,challenge)
        game.hint(); XCTAssertTrue(game.usedHint)
        game.select(challenge.answer); try await settled(game); game.submit()
        XCTAssertEqual(game.stars,1); XCTAssertEqual(game.progress.unlocked,2)
    }
    func testPreviewCannotUnlockOrWriteAndMapIsFlat() async throws {
        let game = EchoDragonModel(defaults:defaults,audio:SilentDragonAudio())
        game.open(25); XCTAssertNil(game.challenge,"Locked level is inaccessible")
        game.open(25,preview:true)
        let challenge = try XCTUnwrap(game.challenge)
        XCTAssertEqual(challenge.level.rule,.mirror)
        game.listen(); try await settled(game)
        game.select(challenge.answer); try await settled(game); game.submit()
        XCTAssertEqual(game.result,.correct)
        XCTAssertEqual(game.progress.unlocked,1)
        XCTAssertNil(defaults.data(forKey:EchoDragonModel.storageKey))
        game.next(); XCTAssertNil(game.challenge)
    }
    func testPauseDuringCallCancelsTheSequenceAndRequiresListeningAgain() async throws {
        let audio = SilentDragonAudio(); audio.suspend = true
        let game = EchoDragonModel(defaults:defaults,audio:audio)
        game.open(1); game.listen()
        await Task.yield()
        game.pause(); audio.suspend = false
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertFalse(game.heardCall); XCTAssertFalse(game.canAnswer); XCTAssertFalse(game.isPlaying)
        game.listen(); try await settled(game)
        XCTAssertTrue(game.heardCall); XCTAssertTrue(game.canAnswer)
        game.map(); XCTAssertNil(game.challenge); XCTAssertFalse(game.isPlaying)
    }
    func testUnreadableProgressIsNotOverwrittenByANewGame() async throws {
        let bytes = Data("corrupt-existing-record".utf8)
        defaults.set(bytes,forKey:EchoDragonModel.storageKey)
        let game = EchoDragonModel(defaults:defaults,audio:SilentDragonAudio())
        XCTAssertNotNil(game.error); game.error = nil
        game.open(1); game.listen(); try await settled(game)
        game.select(try XCTUnwrap(game.challenge?.answer)); try await settled(game); game.submit()
        XCTAssertEqual(defaults.data(forKey:EchoDragonModel.storageKey),bytes)
    }
    func testNativeMapAndMirrorPuzzleRenderWithoutServer() async throws {
        let game = EchoDragonModel(defaults:defaults,audio:SilentDragonAudio())
        let host = UIHostingController(rootView:EchoDragonView(model:game))
        let window = UIWindow(frame:CGRect(x:0,y:0,width:1180,height:820))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for name in ["echo-dragon-map","echo-dragon-mirror"] {
            if name.hasSuffix("mirror") { game.open(25,preview:true) }
            try await Task.sleep(for:.milliseconds(150))
            host.view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds:host.view.bounds)
            let image = renderer.image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
            let attachment = XCTAttachment(image:image)
            attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(host.view.bounds.width,500)
        }
    }
    func testBundledPianoPlaysAndRestartsAfterStopping() async throws {
        let audio = EchoDragonAudio()
        defer { audio.stop() }
        try audio.prepare()
        try await audio.pair(60,61)
        audio.stop()
        try audio.prepare()
        try await audio.pair(67,65)
    }
}

@MainActor private final class SilentDragonAudio: EchoDragonPlaying {
    var notes: [Int] = []
    var suspend = false
    func prepare() throws { }
    func note(_ midi: Int) async throws {
        try Task.checkCancellation()
        notes.append(midi)
        if suspend { try await Task.sleep(for:.seconds(10)) }
    }
    func pair(_ first: Int, _ second: Int) async throws { try await note(first); try await note(second) }
    func silence() { }
    func stop() { }
    func needsRecovery(_ notification: Notification) -> Bool { false }
}
