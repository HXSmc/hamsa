import Foundation
import XCTest
@testable import HamsaKit

/// T08: pure parts of the live STT path (run on Linux too). The Dictation engine itself is checked by
/// `hamsa-cli transcribe --replay ... --kill-after N` (needs macOS 26 + audio).
final class STTStoreTests: XCTestCase {
    func testPartialRowIsUpdatedThenClosedPerChannel() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try LiveStore(path: path)
        try await store.startMeeting(id: "m1")
        let a = try await store.write(STTUpdate(channel: "them", text: "كم", startMs: 0, endMs: 300, isFinal: false, lang: "ar", arrivalMs: 400), meeting: "m1")
        let b = try await store.write(STTUpdate(channel: "them", text: "كم السعر", startMs: 0, endMs: 700, isFinal: false, lang: "ar", arrivalMs: 800), meeting: "m1")
        let me = try await store.write(STTUpdate(channel: "me", text: "hi", startMs: 100, endMs: 500, isFinal: false, lang: "en", arrivalMs: 600), meeting: "m1")
        let c = try await store.write(STTUpdate(channel: "them", text: "كم السعر؟", startMs: 0, endMs: 900, isFinal: true, lang: "ar", arrivalMs: 1000), meeting: "m1")
        let d = try await store.write(STTUpdate(channel: "them", text: "و", startMs: 2000, endMs: 2100, isFinal: false, lang: "ar", arrivalMs: 2200), meeting: "m1")
        XCTAssertEqual(a, b); XCTAssertEqual(b, c); XCTAssertNotEqual(c, d); XCTAssertNotEqual(a, me)
        let counts = try await store.counts(meeting: "m1")
        XCTAssertEqual(counts["them"]?.final, 1); XCTAssertEqual(counts["them"]?.partial, 1)
        XCTAssertEqual(counts["me"]?.partial, 1)
        let text = try await store.finalText(meeting: "m1", channel: "them")
        XCTAssertEqual(text, "كم السعر؟")
        // A restarted worker must not overwrite the dead worker's open row.
        await store.closeOpen(meeting: "m1", channel: "them")
        let e = try await store.write(STTUpdate(channel: "them", text: "x", startMs: 3000, endMs: 3100, isFinal: true, lang: "ar", arrivalMs: 3200), meeting: "m1")
        XCTAssertNotEqual(d, e)
        try await store.endMeeting(id: "m1")
    }

    func testSchemaRejectsUnknownChannel() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try LiveStore(path: path)
        try await store.startMeeting(id: "m1")
        do {
            try await store.write(STTUpdate(channel: "bot", text: "x", startMs: 0, endMs: 1, isFinal: true, lang: "en", arrivalMs: 1), meeting: "m1")
            XCTFail("CHECK(channel IN ('me','them')) not enforced")
        } catch {}
    }
}

final class STTLabelsTests: XCTestCase {
    func testRoundTripAndSnakeCaseKeys() throws {
        let json = """
        {"audio": {"them": "call-01.wav", "me": "call-01.me.wav"}, "provisional": true, "items": [
         {"channel": "them", "start": 0.5, "end": 3.9, "text": "متى تطلقون", "is_question": true, "tech": false, "verbatim": true, "lang": "ar"},
         {"channel": "me", "start": 4.0, "end": 6.0, "text": "In January", "is_question": false, "tech": false, "verbatim": false}]}
        """
        let l = try JSONDecoder().decode(CallLabels.self, from: Data(json.utf8))
        XCTAssertEqual(l.questions.count, 1)
        XCTAssertEqual(l.items[1].lang, nil)
        XCTAssertEqual(l.reference(channel: "me"), "In January")
        let back = try JSONDecoder().decode(CallLabels.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(l), as: UTF8.self).contains("\"is_question\""))
    }
}

final class STTRestartTests: XCTestCase {
    /// Fake worker: drains its relay stream, counts chunks per generation; throws on cancel like the real one.
    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var perGen: [Int: Int] = [:]
        func add(_ g: Int) { lock.lock(); perGen[g, default: 0] += 1; lock.unlock() }
        func get(_ g: Int) -> Int { lock.lock(); defer { lock.unlock() }; return perGen[g] ?? 0 }
    }

    func testKilledWorkerRestartsWithin2sAndGetsAudio() async throws {
        let relay = LiveRelay<Int>()
        let counter = Counter()
        let sup = STTSupervisor(name: "them") { g in
            for await _ in relay.attach().stream { counter.add(g) }
            try Task.checkCancellation()
        }
        await sup.start()
        let feeder = Task { for i in 0..<100 { relay.push(i, frames: 1600); try? await Task.sleep(for: .milliseconds(20)) }; relay.finish() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(counter.get(1), 0)
        let killed = ContinuousClock.now
        await sup.kill()
        while await sup.generation < 2, killed.duration(to: .now) < .seconds(3) { try await Task.sleep(for: .milliseconds(10)) }
        let gen = await sup.generation
        XCTAssertEqual(gen, 2)
        let lats = await sup.restartLatencies
        let lat = try XCTUnwrap(lats.first)
        XCTAssertLessThanOrEqual(lat, .seconds(2), "restart took \(lat)")
        await feeder.value
        await sup.wait()  // relay finished → worker returns → no further restart
        XCTAssertGreaterThan(counter.get(2), 0, "restarted worker got no audio")
        let final = await sup.generation
        XCTAssertEqual(final, 2)
    }

    func testCrashingWorkerIsRestartedAndStopEndsLoop() async throws {
        let counter = Counter()
        let sup = STTSupervisor(name: "me", backoff: .milliseconds(50)) { g in
            counter.add(g)
            if g < 3 { throw NSError(domain: "engine", code: 1) }  // e.g. speech daemon died
            try await Task.sleep(for: .seconds(30))
        }
        await sup.start()
        let t0 = ContinuousClock.now
        while await sup.generation < 3, t0.duration(to: .now) < .seconds(2) { try await Task.sleep(for: .milliseconds(10)) }
        let gen = await sup.generation
        XCTAssertEqual(gen, 3)
        await sup.stop()
        await sup.wait()
        let after = await sup.generation
        XCTAssertEqual(after, 3)
        let err = await sup.lastError
        XCTAssertNotNil(err)
    }
}
