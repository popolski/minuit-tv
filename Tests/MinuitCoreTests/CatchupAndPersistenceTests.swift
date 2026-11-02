import Foundation
import XCTest
@testable import MinuitCore

final class CatchupTests: XCTestCase {
    let channel = Channel(id: ChannelID(101), name: "TF1", archive: ArchiveCapability(days: 7))
    let now = utc("2026-11-02 15:30")

    func programme(_ start: String, _ end: String, archive: Bool? = nil) -> Programme {
        Programme(channel: ChannelID(101), start: utc(start), end: utc(end), title: "P", archiveFlag: archive, source: .xmltv)
    }

    func testFinishedProgrammeWithinWindow() throws {
        let result = CatchupEvaluator.evaluate(programme: programme("2026-11-02 12:00", "2026-11-02 13:00"), channel: channel, now: now)
        guard case .available(let window, let expiresAt) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(window.requestStart, utc("2026-11-02 11:58"), "marge de 2 min avant")
        XCTAssertEqual(window.durationMinutes, 67, "60 min + 2 avant + 5 après")
        XCTAssertEqual(window.programmeOffset, 120)
        XCTAssertFalse(window.isStartOver)
        XCTAssertEqual(expiresAt, utc("2026-11-09 12:00"))
    }

    func testPaddingAfterNeverExceedsNow() {
        let result = CatchupEvaluator.evaluate(programme: programme("2026-11-02 14:00", "2026-11-02 15:28"), channel: channel, now: now)
        XCTAssertEqual(result.window?.requestEnd, utc("2026-11-02 15:30"))
    }

    func testStartOver() {
        let result = CatchupEvaluator.evaluate(programme: programme("2026-11-02 15:00", "2026-11-02 16:00"), channel: channel, now: now)
        guard case .startOver(let window) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(window.isStartOver)
        XCTAssertEqual(window.requestStart, utc("2026-11-02 14:58"))
    }

    func testUnavailableCases() {
        XCTAssertEqual(CatchupEvaluator.evaluate(programme: programme("2026-11-02 18:00", "2026-11-02 19:00"), channel: channel, now: now), .upcoming)
        XCTAssertEqual(CatchupEvaluator.evaluate(programme: programme("2026-10-20 18:00", "2026-10-20 19:00"), channel: channel, now: now), .expired)
        XCTAssertEqual(CatchupEvaluator.evaluate(programme: programme("2026-11-02 12:00", "2026-11-02 13:00", archive: false), channel: channel, now: now),
                       .notArchivedByProvider)
        let noArchive = Channel(id: ChannelID(102), name: "F2")
        XCTAssertEqual(CatchupEvaluator.evaluate(programme: programme("2026-11-02 12:00", "2026-11-02 13:00"), channel: noArchive, now: now),
                       .channelHasNoArchive)
    }

    func testWindowShiftForSeekByRequest() {
        let window = ArchiveWindow(requestStart: utc("2026-11-02 12:00"), durationMinutes: 60, programmeStart: utc("2026-11-02 12:02"),
                                   programmeEnd: utc("2026-11-02 12:55"), title: "P", isStartOver: false)
        let (shifted, residual) = window.shifted(toStreamOffset: 605)
        XCTAssertEqual(shifted.requestStart, utc("2026-11-02 12:10"))
        XCTAssertEqual(shifted.durationMinutes, 50)
        XCTAssertEqual(residual, 5)
        XCTAssertEqual(window.shifted(toStreamOffset: -30).window.requestStart, window.requestStart)
        XCTAssertEqual(window.shifted(toStreamOffset: 99_999).window.durationMinutes, 1)
    }

    func testProbeClassification() {
        var ts = Data(repeating: 0, count: 188 * 4)
        for i in stride(from: 0, to: ts.count, by: 188) { ts[i] = 0x47 }
        XCTAssertEqual(ArchiveProbe.classify(statusCode: 200, contentType: "video/mp2t", body: ts), .playable(.mpegts))
        var shifted = Data([0x00, 0x00, 0x00]) + ts
        shifted.append(contentsOf: [UInt8](repeating: 0, count: 10))
        XCTAssertEqual(ArchiveProbe.classify(statusCode: 206, contentType: nil, body: shifted), .playable(.mpegts))

        let playlist = Data("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nseg1.ts\n".utf8)
        XCTAssertEqual(ArchiveProbe.classify(statusCode: 200, contentType: "application/vnd.apple.mpegurl", body: playlist), .playable(.hls))
        XCTAssertEqual(ArchiveProbe.classify(statusCode: 200, contentType: nil, body: Data("#EXTM3U\n".utf8)), .notMedia(hint: "playlist vide"))
        XCTAssertEqual(ArchiveProbe.classify(statusCode: 200, contentType: "text/html", body: Data("<html>No archive</html>".utf8)),
                       .notMedia(hint: "page HTML"))
        XCTAssertEqual(ArchiveProbe.classify(statusCode: 200, contentType: "video/mp2t", body: Data("{\"error\":1}".utf8)),
                       .notMedia(hint: "réponse JSON"))
        XCTAssertEqual(ArchiveProbe.classify(statusCode: 404, contentType: nil, body: Data()), .httpError(404))
        XCTAssertEqual(ArchiveProbe.classify(statusCode: 200, contentType: "video/mp2t", body: Data()), .empty)
    }
}

final class PersistenceTests: XCTestCase {
    func testStoredValueRoundTrip() throws {
        let storage = InMemoryStorage()
        let store = StoredValue<LibraryPreferences>(key: "prefs", storage: storage)
        XCTAssertNil(store.load())
        var prefs = LibraryPreferences()
        prefs.toggleFavorite(ChannelID(4))
        prefs.setHidden(true, category: CategoryID("x"))
        prefs.recordWatched(ChannelID(9))
        try store.save(prefs)
        XCTAssertEqual(store.load(), prefs)
        store.clear()
        XCTAssertNil(store.load())
    }

    func testStoredValueRejectsOversizedPayloads() {
        let store = StoredValue<[String]>(key: "big", storage: InMemoryStorage(), maxBytes: 100)
        XCTAssertThrowsError(try store.save(Array(repeating: "0123456789", count: 50))) { error in
            guard case .tooLarge? = error as? StoredValueError else { return XCTFail("\(error)") }
        }
    }

    func testCorruptedDataIsIgnored() {
        let storage = InMemoryStorage()
        storage.set(Data("not json".utf8), forKey: "prefs")
        XCTAssertNil(StoredValue<LibraryPreferences>(key: "prefs", storage: storage).load())
    }

    func testFileCacheRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("minuit-tests-\(UUID().uuidString)")
        let cache = FileCache(directory: directory)
        defer { cache.removeAll() }
        let channels = [Channel(id: ChannelID(1), name: "Un", logoURL: URL(string: "http://x/y.png"), archive: ArchiveCapability(days: 3))]
        try cache.write(channels, name: "channels/v1")
        let read = try XCTUnwrap(cache.read([Channel].self, name: "channels/v1"))
        XCTAssertEqual(read.value, channels)
        XCTAssertGreaterThan(cache.sizeOnDisk(), 0)
        XCTAssertNil(cache.read([Channel].self, name: "absent"))
    }

    func testSettingsDefaultsAreSafe() throws {
        let settings = AppSettings()
        XCTAssertEqual(settings.transportSecurity, .allowHTTP, "HTTP accepté par défaut : la majorité des serveurs Xtream")
        XCTAssertEqual(settings.enginePreference, .automatic)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testPreferencesStayWellUnderTVOSDefaultsBudget() throws {
        var prefs = LibraryPreferences()
        for id in 0..<500 { prefs.toggleFavorite(ChannelID(100_000 + id)) }
        for id in 0..<300 { prefs.setHidden(true, category: CategoryID("category-\(id)")) }
        let size = try JSONEncoder().encode(prefs).count
        XCTAssertLessThan(size, 64 * 1024, "même un usage intensif reste petit")
    }
}
