import Foundation
import XCTest
@testable import MinuitCore

final class LibraryTests: XCTestCase {
    func makeLibrary() throws -> ChannelLibrary {
        let categories = try JSONDecoder().decode(LossyArray<LiveCategoryDTO>.self, from: Fixture.data("live_categories.json"))
            .elements.enumerated().map { ChannelCategory(id: CategoryID($1.id), name: $1.name, serverOrder: $0) }
        return ChannelLibrary(categories: categories, channels: try XtreamClient.decodeChannels(Fixture.data("live_streams.json")))
    }

    func testNormalizationAndPrefixes() {
        XCTAssertEqual(SearchNormalizer.normalize("  Équipe — FRANCE 2 HD!! "), "equipe france 2 hd")
        XCTAssertEqual(SearchNormalizer.stripProviderPrefix("FR: TF1 HD"), "TF1 HD")
        XCTAssertEqual(SearchNormalizer.stripProviderPrefix("FR | France 2"), "France 2")
        XCTAssertEqual(SearchNormalizer.stripProviderPrefix("|FR| Arte"), "Arte")
        XCTAssertEqual(SearchNormalizer.stripProviderPrefix("[UK] BBC One"), "BBC One")
        XCTAssertEqual(SearchNormalizer.stripProviderPrefix("M6"), "M6")
    }

    func testSearch() throws {
        let library = try makeLibrary()
        let prefs = LibraryPreferences()
        XCTAssertEqual(library.search("france", preferences: prefs).map(\.id.rawValue), [102])
        XCTAssertEqual(library.search("FRANCÉ 2", preferences: prefs).map(\.id.rawValue), [102])
        XCTAssertEqual(library.search("bein 1", preferences: prefs).map(\.id.rawValue), [104])
        XCTAssertEqual(library.search("3", preferences: prefs).first?.id.rawValue, 103, "numéro de chaîne")
        XCTAssertTrue(library.search("adulte", preferences: prefs).isEmpty, "contenu adulte masqué par défaut")
        XCTAssertTrue(library.search("   ", preferences: prefs).isEmpty)
    }

    func testCategoriesVisibilityAndOrder() throws {
        let library = try makeLibrary()
        var prefs = LibraryPreferences()
        XCTAssertEqual(library.visibleCategories(preferences: prefs).map(\.id.rawValue), ["1", "2"])
        prefs.hideAdultContent = false
        XCTAssertEqual(library.visibleCategories(preferences: prefs).map(\.id.rawValue), ["1", "2", "9"])
        prefs.moveCategory(CategoryID("9"), by: -2, allCategories: library.categories)
        XCTAssertEqual(library.visibleCategories(preferences: prefs).map(\.id.rawValue), ["9", "1", "2"])
        prefs.setHidden(true, category: CategoryID("1"))
        XCTAssertEqual(library.visibleCategories(preferences: prefs).map(\.id.rawValue), ["9", "2"])
        // Une chaîne présente aussi dans une catégorie visible reste zappable.
        XCTAssertEqual(library.channels(in: .all, preferences: prefs).map(\.id.rawValue), [105, 104])
    }

    func testAllChannelsOrderWithoutDuplicates() throws {
        let library = try makeLibrary()
        XCTAssertEqual(library.channels(in: .all, preferences: LibraryPreferences()).map(\.id.rawValue), [101, 102, 103, 104])
    }

    func testFavoritesRecentsAndPrune() {
        var prefs = LibraryPreferences()
        prefs.toggleFavorite(ChannelID(1))
        prefs.toggleFavorite(ChannelID(2))
        prefs.toggleFavorite(ChannelID(3))
        prefs.moveFavorite(ChannelID(3), by: -5)
        XCTAssertEqual(prefs.favorites, [ChannelID(3), ChannelID(1), ChannelID(2)])
        prefs.toggleFavorite(ChannelID(1))
        XCTAssertEqual(prefs.favorites, [ChannelID(3), ChannelID(2)])

        for id in 1...25 { prefs.recordWatched(ChannelID(id)) }
        prefs.recordWatched(ChannelID(10))
        XCTAssertEqual(prefs.recents.count, LibraryPreferences.maxRecents)
        XCTAssertEqual(prefs.recents.first, ChannelID(10))
        XCTAssertEqual(prefs.lastChannel, ChannelID(10))

        prefs.prune(validChannels: [ChannelID(2), ChannelID(10)], validCategories: [])
        XCTAssertEqual(prefs.favorites, [ChannelID(2)])
        XCTAssertEqual(prefs.recents, [ChannelID(10)])
    }
}

final class NavigatorTests: XCTestCase {
    let ids = [1, 2, 3, 4].map(ChannelID.init)

    func testWrapAroundAndRecall() {
        var nav = ChannelNavigator(list: ids, context: .all, current: ChannelID(4))
        XCTAssertEqual(nav.step(1), ChannelID(1))
        XCTAssertEqual(nav.step(-1), ChannelID(4))
        XCTAssertEqual(nav.step(-1), ChannelID(3))
        XCTAssertEqual(nav.recall(), ChannelID(4))
        XCTAssertEqual(nav.recall(), ChannelID(3))
        XCTAssertEqual(nav.neighbour(offset: 9), ChannelID(4))
    }

    func testCurrentOutsideList() {
        let nav = ChannelNavigator(list: ids, context: .favorites, current: ChannelID(99))
        XCTAssertEqual(nav.neighbour(offset: 1), ChannelID(1))
        XCTAssertEqual(nav.neighbour(offset: -1), ChannelID(4))
        XCTAssertNil(ChannelNavigator(list: [], context: .all).neighbour(offset: 1))
    }

    func testNumericResolution() {
        let channels = [Channel(id: ChannelID(10), name: "A", number: 5), Channel(id: ChannelID(11), name: "B")]
        XCTAssertEqual(ChannelNavigator.resolve(number: 5, in: channels), ChannelID(10))
        XCTAssertEqual(ChannelNavigator.resolve(number: 2, in: channels), ChannelID(11))
        XCTAssertNil(ChannelNavigator.resolve(number: 7, in: channels))
    }
}

final class PlaybackPlanningTests: XCTestCase {
    func testLadders() {
        let both = PlaybackPlanner(availableEngines: [.aether, .avPlayer], preference: .automatic)
        XCTAssertEqual(both.ladder(allowedFormats: [.hls, .mpegts]).map(\.description),
                       ["AetherEngine/ts", "AVPlayer/m3u8", "AetherEngine/m3u8"])
        XCTAssertEqual(both.ladder(allowedFormats: [.mpegts]).map(\.description), ["AetherEngine/ts"])
        XCTAssertEqual(both.ladder(allowedFormats: [.hls]).map(\.description), ["AVPlayer/m3u8", "AetherEngine/m3u8"])

        let avOnly = PlaybackPlanner(availableEngines: [.avPlayer], preference: .automatic)
        XCTAssertTrue(avOnly.ladder(allowedFormats: [.mpegts]).isEmpty, "TS seul sans AetherEngine : aucune option honnête")

        let remembered = PlaybackAttempt(engine: .avPlayer, format: .hls)
        XCTAssertEqual(both.ladder(allowedFormats: [.hls, .mpegts], remembered: remembered).first, remembered)

        let preferHLS = PlaybackPlanner(availableEngines: [.aether, .avPlayer], preference: .preferAVPlayerHLS)
        XCTAssertEqual(preferHLS.ladder(allowedFormats: []).first, remembered)
    }

    func testMemoryIsBounded() {
        var memory = PlaybackMemory(capacity: 2)
        let a = PlaybackAttempt(engine: .aether, format: .mpegts)
        memory.remember(a, for: ChannelID(1))
        memory.remember(a, for: ChannelID(2))
        memory.remember(a, for: ChannelID(3))
        XCTAssertNil(memory.attempt(for: ChannelID(1)))
        XCTAssertEqual(memory.attempt(for: ChannelID(3)), a)
    }

    func testZapAccumulatorCoalescesRapidPresses() {
        var zap = ZapAccumulator(settleDelay: 0.35)
        zap.register(target: ChannelID(2), at: 0.0)
        zap.register(target: ChannelID(3), at: 0.2)
        XCTAssertNil(zap.commitIfSettled(at: 0.4))
        zap.register(target: ChannelID(4), at: 0.45)
        XCTAssertNil(zap.commitIfSettled(at: 0.7))
        XCTAssertEqual(zap.commitIfSettled(at: 0.81), ChannelID(4), "un seul chargement, pour la dernière chaîne")
        XCTAssertNil(zap.commitIfSettled(at: 2.0))
    }
}

final class HealthMonitorTests: XCTestCase {
    /// Simule `seconds` secondes d'échantillons à 2 Hz.
    func run(_ monitor: inout PlaybackHealthMonitor, from start: Double, seconds: Double,
             _ make: (Double) -> HealthSample) -> HealthVerdict {
        var verdict = HealthVerdict.starting
        var t = start
        while t <= start + seconds {
            verdict = monitor.evaluate(make(t))
            t += 0.5
        }
        return verdict
    }

    func testHealthyPlayback() {
        var monitor = PlaybackHealthMonitor()
        monitor.reset(at: 0)
        let verdict = run(&monitor, from: 0, seconds: 20) { t in
            HealthSample(at: t, clockPosition: t, firstFrameShown: t >= 1, lastVideoFrameTime: t)
        }
        XCTAssertEqual(verdict, .healthy)
        XCTAssertEqual(monitor.timeToFirstFrame, 1)
    }

    func testClockAdvancingButFrozenImageIsDetected() {
        var monitor = PlaybackHealthMonitor()
        monitor.reset(at: 0)
        _ = run(&monitor, from: 0, seconds: 5) { t in
            HealthSample(at: t, clockPosition: t, firstFrameShown: true, lastVideoFrameTime: t)
        }
        // L'horloge (et le son) continuent, la dernière image reste bloquée à 5 s.
        let verdict = run(&monitor, from: 5.5, seconds: 5) { t in
            HealthSample(at: t, clockPosition: t, firstFrameShown: true, lastVideoFrameTime: 5)
        }
        XCTAssertEqual(verdict, .frozenVideo)
    }

    func testFrozenDetectionWithFrameRateSignal() {
        var monitor = PlaybackHealthMonitor()
        monitor.reset(at: 0)
        _ = run(&monitor, from: 0, seconds: 3) { t in HealthSample(at: t, clockPosition: t, firstFrameShown: true, videoFrameRate: 25) }
        let verdict = run(&monitor, from: 3.5, seconds: 5) { t in HealthSample(at: t, clockPosition: t, firstFrameShown: true, videoFrameRate: 0) }
        XCTAssertEqual(verdict, .frozenVideo)
    }

    /// Voie de rendu qui ne fournit pas de cadence (toujours 0) : ce n'est pas une image figée.
    func testSilentVideoSignalIsNotFrozen() {
        var monitor = PlaybackHealthMonitor()
        monitor.reset(at: 0)
        let verdict = run(&monitor, from: 0, seconds: 30) { t in
            HealthSample(at: t, clockPosition: t, firstFrameShown: true, videoFrameRate: 0)
        }
        XCTAssertEqual(verdict, .healthy, "un signal vidéo jamais actif ne prouve aucun gel")
    }

    func testClockAloneNeverProvesAPicture() {
        var monitor = PlaybackHealthMonitor()
        monitor.reset(at: 0)
        // Horloge qui avance, son présent, mais aucune première image : jamais « sain ».
        let verdict = run(&monitor, from: 0, seconds: 20) { t in
            HealthSample(at: t, clockPosition: t, firstFrameShown: false, hasVideoTrack: nil, hasAudio: true)
        }
        XCTAssertEqual(verdict, .startupTimeout)
    }

    func testAudioWithoutVideo() {
        var monitor = PlaybackHealthMonitor()
        monitor.reset(at: 0)
        let verdict = run(&monitor, from: 0, seconds: 7) { t in
            HealthSample(at: t, clockPosition: t, firstFrameShown: false, hasVideoTrack: false, hasAudio: true)
        }
        XCTAssertEqual(verdict, .audioWithoutVideo)
    }

    func testStallAndBuffering() {
        var monitor = PlaybackHealthMonitor()
        monitor.reset(at: 0)
        _ = run(&monitor, from: 0, seconds: 3) { t in HealthSample(at: t, clockPosition: t, firstFrameShown: true, lastVideoFrameTime: t) }
        let buffering = run(&monitor, from: 3.5, seconds: 5) { t in
            HealthSample(at: t, clockPosition: 3, isBuffering: true, firstFrameShown: true, lastVideoFrameTime: 3)
        }
        XCTAssertEqual(buffering, .buffering(since: 3.5))
        let stalled = run(&monitor, from: 9, seconds: 10) { t in
            HealthSample(at: t, clockPosition: 3, isBuffering: true, firstFrameShown: true, lastVideoFrameTime: 3)
        }
        XCTAssertEqual(stalled, .stalled)

        var silent = PlaybackHealthMonitor()
        silent.reset(at: 0)
        _ = run(&silent, from: 0, seconds: 2) { t in HealthSample(at: t, clockPosition: t, firstFrameShown: true, lastVideoFrameTime: t) }
        let verdict = run(&silent, from: 2.5, seconds: 9) { t in
            HealthSample(at: t, clockPosition: 2, firstFrameShown: true, lastVideoFrameTime: 2)
        }
        XCTAssertEqual(verdict, .stalled, "ni horloge ni image, sans signal de mise en mémoire tampon")
    }

    func testPauseIsNeverReportedAsFrozen() {
        var monitor = PlaybackHealthMonitor()
        monitor.reset(at: 0)
        _ = run(&monitor, from: 0, seconds: 2) { t in HealthSample(at: t, clockPosition: t, firstFrameShown: true, lastVideoFrameTime: t) }
        XCTAssertEqual(run(&monitor, from: 2.5, seconds: 30) { t in
            HealthSample(at: t, wantsToPlay: false, clockPosition: 2, firstFrameShown: true, lastVideoFrameTime: 2)
        }, .paused)
        // Reprise : le temps passé en pause ne compte pas.
        XCTAssertEqual(monitor.evaluate(HealthSample(at: 33, clockPosition: 2.1, firstFrameShown: true, lastVideoFrameTime: 2.1)), .healthy)
    }

    func testRecoveryLadder() {
        let ladder = [PlaybackAttempt(engine: .aether, format: .mpegts), PlaybackAttempt(engine: .avPlayer, format: .hls)]
        var planner = RecoveryPlanner(ladder: ladder)
        XCTAssertEqual(planner.next(after: .network, hadFirstFrame: true, at: 0), .reload(after: 1))
        XCTAssertEqual(planner.next(after: .network, hadFirstFrame: true, at: 5), .reload(after: 3))
        XCTAssertEqual(planner.next(after: .network, hadFirstFrame: true, at: 10), .reload(after: 6))
        XCTAssertEqual(planner.next(after: .network, hadFirstFrame: true, at: 15), .fallBack(to: ladder[1]))
        XCTAssertEqual(planner.currentAttempt, ladder[1])
        XCTAssertEqual(planner.next(after: .health(.startupTimeout), hadFirstFrame: false, at: 20), .giveUp(.health(.startupTimeout)))

        var limited = RecoveryPlanner(ladder: ladder)
        XCTAssertEqual(limited.next(after: .connectionLimit, hadFirstFrame: false, at: 0), .giveUp(.connectionLimit),
                       "changer de moteur n'aide pas quand le compte est saturé")
        var startup = RecoveryPlanner(ladder: ladder)
        XCTAssertEqual(startup.next(after: .unsupportedFormat, hadFirstFrame: false, at: 0), .fallBack(to: ladder[1]))

        var windowed = RecoveryPlanner(ladder: ladder, reloadDelays: [1], budgetWindow: 60)
        XCTAssertEqual(windowed.next(after: .network, hadFirstFrame: true, at: 0), .reload(after: 1))
        XCTAssertEqual(windowed.next(after: .network, hadFirstFrame: true, at: 100), .reload(after: 1), "budget renouvelé après la fenêtre")
    }
}

final class LiveDelayAndDiagnosisTests: XCTestCase {
    func testLiveDelayAccumulatesPausesAndIsCapped() {
        var clock = LiveDelayClock(limit: 600)
        let t0 = utc("2026-11-04 20:00")
        XCTAssertEqual(clock.delay(at: t0), 0)
        XCTAssertNil(LiveDelayClock.label(0.4))

        clock.pause(at: t0)
        clock.pause(at: t0.addingTimeInterval(30))          // second appui ignoré
        XCTAssertEqual(clock.delay(at: t0.addingTimeInterval(90)), 90, "le retard grandit pendant la pause")
        clock.resume(at: t0.addingTimeInterval(90))
        XCTAssertEqual(clock.delay(at: t0.addingTimeInterval(500)), 90, "figé pendant la lecture")
        XCTAssertEqual(LiveDelayClock.label(90), "−1:30")

        clock.pause(at: t0.addingTimeInterval(600))
        XCTAssertEqual(clock.delay(at: t0.addingTimeInterval(2000)), 600, "plafonné au tampon local")
        clock.reset()
        XCTAssertEqual(clock.delay(at: t0.addingTimeInterval(3000)), 0)
    }

    func testConnectionConclusionNamesTheCulprit() {
        XCTAssertEqual(ConnectionReport(network: .failed, internet: .failed, provider: .failed).conclusion,
                       "L'Apple TV n'est pas connectée au réseau.")
        XCTAssertTrue(ConnectionReport(network: .ok, internet: .failed, provider: .failed).conclusion.contains("box"))
        XCTAssertTrue(ConnectionReport(network: .ok, internet: .ok, provider: .failed).conclusion.contains("fournisseur"))
        XCTAssertEqual(ConnectionReport(network: .ok, internet: .ok, provider: .ok, providerError: .tooManyConnections(max: 1)).conclusion,
                       XtreamError.tooManyConnections(max: 1).userMessage)
        XCTAssertTrue(ConnectionReport(network: .ok, internet: .ok, provider: .slow).conclusion.contains("lentement"))
        XCTAssertEqual(ConnectionReport.status(latency: nil), .failed)
        XCTAssertEqual(ConnectionReport.status(latency: 0.2), .ok)
        XCTAssertEqual(ConnectionReport.status(latency: 2.5), .slow)
    }
}

final class ChannelVariantsTests: XCTestCase {
    private func channel(_ id: Int, _ name: String, _ category: String = "1") -> Channel {
        Channel(id: ChannelID(id), name: name, categoryIDs: [CategoryID(category)])
    }

    func testVersionsShareAKeyWithoutQualityMentions() {
        XCTAssertEqual(ChannelVariants.key(for: "FR: TF1 FHD"), ChannelVariants.key(for: "FR: TF1 ᴴᴰ"))
        XCTAssertEqual(ChannelVariants.key(for: "France 2 4K HEVC"), ChannelVariants.key(for: "France 2"))
        XCTAssertNotEqual(ChannelVariants.key(for: "TF1"), ChannelVariants.key(for: "TF1 Séries Films"))
        XCTAssertNotEqual(ChannelVariants.key(for: "FR: TF1 HD"), ChannelVariants.key(for: "BE: TF1 HD"))
        XCTAssertNil(ChannelVariants.key(for: "HD"))
    }

    func testListsShowOneLinePerChannelPreferringFHD() {
        let library = ChannelLibrary(categories: [ChannelCategory(id: CategoryID("1"), name: "TNT", serverOrder: 0)],
                                     channels: [channel(1, "TF1 4K"), channel(2, "TF1 HD"), channel(3, "France 2"),
                                                channel(4, "TF1 FHD"), channel(5, "France 2 SD")])
        var prefs = LibraryPreferences()
        XCTAssertEqual(library.channels(in: .all, preferences: prefs).map(\.id.rawValue), [4, 3],
                       "une ligne par chaîne, à la place de la première version, la FHD")
        XCTAssertEqual(library.variants(of: ChannelID(1)).map(\.id.rawValue), [4, 2, 1], "FHD, HD puis 4K")
        XCTAssertEqual(library.variants(of: ChannelID(3)).map(\.id.rawValue), [3, 5])
        XCTAssertTrue(ChannelLibrary(categories: [], channels: [channel(9, "Arte")]).variants(of: ChannelID(9)).isEmpty)

        prefs.groupVariants = false
        XCTAssertEqual(library.channels(in: .category(CategoryID("1")), preferences: prefs).count, 5)
    }
}

final class PhoneSetupTests: XCTestCase {
    func testCodeExpiresAndLocksAfterWrongAttempts() {
        let now = utc("2026-11-04 20:00")
        var session = PhoneSetupSession(code: "482913", expiresAt: now.addingTimeInterval(600))
        XCTAssertEqual(session.displayCode, "482 913")
        XCTAssertTrue(session.check("482 913", at: now))
        XCTAssertFalse(session.check("482913", at: now.addingTimeInterval(601)), "expiré")
        for _ in 0..<PhoneSetupSession.maxFailedAttempts { _ = session.check("000000", at: now) }
        XCTAssertTrue(session.isLocked)
        XCTAssertFalse(session.check("482913", at: now), "bloqué même avec le bon code")
        XCTAssertEqual(PhoneSetupSession.make(now: now).code.count, 6)
    }

    func testParsesRequestsArrivingInPieces() {
        let body = "server=http%3A%2F%2Fexemple.tv%3A8080&username=alice&password=a%2Bb+c&code=482913"
        let raw = "POST /config HTTP/1.1\r\nHost: 192.168.1.42\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        let data = Data(raw.utf8)
        XCTAssertEqual(LocalHTTPRequest.parse(data.prefix(30)), .needMoreData)
        XCTAssertEqual(LocalHTTPRequest.parse(data.dropLast(4)), .needMoreData)
        guard case .complete(let request) = LocalHTTPRequest.parse(data) else { return XCTFail("requête complète attendue") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/config")
        let form = FormDecoding.decode(String(decoding: request.body, as: UTF8.self))
        XCTAssertEqual(form["server"], "http://exemple.tv:8080")
        XCTAssertEqual(form["password"], "a+b c")

        guard case .complete(let get) = LocalHTTPRequest.parse(Data("GET /?code=482913 HTTP/1.1\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(get.query["code"], "482913")
        XCTAssertEqual(LocalHTTPRequest.parse(Data("n'importe quoi\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(LocalHTTPRequest.parse(Data(repeating: 65, count: LocalHTTPRequest.maxSize + 1)), .invalid)
        XCTAssertTrue(PhoneSetupPage.html(code: "482913").contains("value=\"482913\""))
    }
}
