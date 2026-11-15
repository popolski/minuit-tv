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
                       .providerMessage(hint: "page HTML"))
        XCTAssertEqual(ArchiveProbe.classify(statusCode: 200, contentType: "video/mp2t", body: Data("{\"error\":1}".utf8)),
                       .providerMessage(hint: "réponse JSON"))
        XCTAssertEqual(ArchiveProbe.classify(statusCode: 200, contentType: "text/html; charset=utf-8", body: Data("\u{FEFF}Account expired".utf8)),
                       .providerMessage(hint: "page HTML"))
        XCTAssertEqual(ArchiveProbe.classify(statusCode: 404, contentType: nil, body: Data()), .httpError(404))
        XCTAssertEqual(ArchiveProbe.classify(statusCode: 200, contentType: "video/mp2t", body: Data()), .empty)
    }

    func testLiveFailureRefinedByProbe() {
        let generic = PlaybackFailure.unknown("AVFoundation -11800")
        XCTAssertEqual(generic.refined(by: .providerMessage(hint: "page HTML")), .providerMessage)
        XCTAssertEqual(PlaybackFailure.health(.startupTimeout).refined(by: .httpError(403)), .http(403))
        XCTAssertEqual(PlaybackFailure.network.refined(by: .httpError(458)), .connectionLimit)
        // Code ambigu (réponse à l'en-tête Range), erreur réseau du sondage, flux sain : inchangé.
        XCTAssertEqual(generic.refined(by: .httpError(416)), generic)
        XCTAssertEqual(generic.refined(by: .unreachable(.cannotConnect)), generic)
        XCTAssertEqual(generic.refined(by: .playable(.mpegts)), generic)
        // Une cause déjà précise n'est pas remplacée.
        XCTAssertEqual(PlaybackFailure.certificateRejected.refined(by: .providerMessage(hint: "page HTML")), .certificateRejected)
        XCTAssertFalse(PlaybackFailure.providerMessage.userMessage.contains("http"))
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

    func testSettingsDecodingIsTolerant() throws {
        // Réglages d'une version antérieure : clé de reprise ancienne (ignorée), champ inconnu, champ manquant.
        let old = Data(#"{"resumeLastChannelOnLaunch":true,"enginePreference":"preferAVPlayerHLS","futureField":42,"epgDaysAhead":"x"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertFalse(settings.resumeLastChannelOnLaunch, "reprise automatique désactivée par défaut")
        XCTAssertEqual(settings.enginePreference, .preferAVPlayerHLS, "les réglages valides sont conservés")
        XCTAssertEqual(settings.epgDaysAhead, 2, "valeur illisible → défaut")
        XCTAssertTrue(settings.acceptInvalidStreamCertificates, "réglage absent des anciennes versions → défaut")
        var changed = AppSettings()
        changed.resumeLastChannelOnLaunch = true
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed)), changed)
    }

    func testPreferencesSurviveSchemaChanges() throws {
        let stored = Data(#"{"favorites":[101,102],"recents":[5],"lastChannel":5,"unknown":{"a":1},"hiddenCategories":"bad"}"#.utf8)
        let prefs = try JSONDecoder().decode(LibraryPreferences.self, from: stored)
        XCTAssertEqual(prefs.favorites, [ChannelID(101), ChannelID(102)], "les favoris ne doivent jamais être perdus")
        XCTAssertEqual(prefs.lastChannel, ChannelID(5))
        XCTAssertTrue(prefs.hiddenCategories.isEmpty)
        XCTAssertTrue(prefs.hideAdultContent)
    }

    func testPreferencesStayWellUnderTVOSDefaultsBudget() throws {
        var prefs = LibraryPreferences()
        for id in 0..<500 { prefs.toggleFavorite(ChannelID(100_000 + id)) }
        for id in 0..<300 { prefs.setHidden(true, category: CategoryID("category-\(id)")) }
        let size = try JSONEncoder().encode(prefs).count
        XCTAssertLessThan(size, 64 * 1024, "même un usage intensif reste petit")
    }
}

final class ArchiveProbeRequestTests: XCTestCase {
    /// Le sondage ne demande pas de plage d'octets (réponses vides de certains scripts de timeshift)
    /// et reconnaît le MPEG-TS dans les premiers octets.
    func testProbeSendsNoRangeAndDetectsTransportStream() async {
        var packets = Data(repeating: 0xFF, count: 188 * 4)
        for offset in stride(from: 0, to: packets.count, by: 188) { packets[offset] = 0x47 }
        let http = MockHTTPClient(sequence: [ok(packets)])
        let verdict = await ArchiveProbe.probe(URL(string: "http://example.tv/timeshift/a/b/60/2026-11-14:20-00/1.ts")!, using: http)
        XCTAssertEqual(verdict, .playable(.mpegts))
        XCTAssertNil(http.requests.first?.byteRange)
    }

    func testEmptyBodyIsEmptyVerdict() async {
        let http = MockHTTPClient(sequence: [ok(Data())])
        let verdict = await ArchiveProbe.probe(URL(string: "http://example.tv/timeshift/a/b/60/2026-11-14:20-00/1.ts")!, using: http)
        XCTAssertEqual(verdict, .empty)
    }
}

final class ArchiveProbeTransportTests: XCTestCase {
    /// Une coupure réseau (après redirection, par exemple) n'est ni un refus ni une réponse vide.
    func testTransportFailureIsUnreachable() async {
        let http = MockHTTPClient(sequence: [.failure(.secureConnectionFailed)])
        let verdict = await ArchiveProbe.probe(URL(string: "http://example.tv/timeshift/a/b/60/2026-11-14:20-00/1.ts")!, using: http)
        XCTAssertEqual(verdict, .unreachable(.secureConnectionFailed))
    }
}

final class RedirectRepairTests: XCTestCase {
    private let origin = URL(string: "http://example.tv:8080/timeshift/a/b/32/2026-11-14:17-13/12059.ts")!

    /// Constaté chez un fournisseur : 302 vers « https://…:8080 », port qui ne parle que HTTP.
    func testHTTPSOnNonTLSPortFromHTTPOriginIsDowngraded() {
        let target = URL(string: "https://g9amt9rd.lb21.example.dad:8080/timeshift/x/y/32/2026-11-14:17-13/12059.ts?token=abc&id=12059")!
        XCTAssertEqual(RedirectRepair.repaired(target, from: origin).absoluteString,
                       "http://g9amt9rd.lb21.example.dad:8080/timeshift/x/y/32/2026-11-14:17-13/12059.ts?token=abc&id=12059")
    }

    func testRegularRedirectsAreKept() {
        let standard = URL(string: "https://cdn.example.dad/a.ts")!
        XCTAssertEqual(RedirectRepair.repaired(standard, from: origin), standard, "HTTPS sans port explicite : inchangé")
        let tls = URL(string: "https://cdn.example.dad:8443/a.ts")!
        XCTAssertEqual(RedirectRepair.repaired(tls, from: origin), tls, "port TLS usuel : inchangé")
        let plain = URL(string: "http://cdn.example.dad:8080/a.ts")!
        XCTAssertEqual(RedirectRepair.repaired(plain, from: origin), plain)
        let secureOrigin = URL(string: "https://example.tv/a.ts")!
        let target = URL(string: "https://cdn.example.dad:8080/a.ts")!
        XCTAssertEqual(RedirectRepair.repaired(target, from: secureOrigin), target, "origine HTTPS : jamais de rétrogradation")
    }

    func testPlayableURLWithoutRedirectKeepsOriginal() async {
        let http = MockHTTPClient(sequence: [ok(Data())])
        let url = await RedirectRepair.playableURL(for: origin, using: http)
        XCTAssertEqual(url, origin)
    }
}
