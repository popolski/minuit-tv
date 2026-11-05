import Foundation
import XCTest
@testable import MinuitCore

final class VODDecodingTests: XCTestCase {
    private func client(_ http: MockHTTPClient) -> XtreamClient {
        var client = XtreamClient(credentials: testCredentials, http: http, now: { utc("2026-11-02 15:30") })
        client.retry = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0)
        return client
    }

    func testMoviesToleratesVariantTypesAndSkipsInvalidEntries() throws {
        let json = #"""
        [{"num":1,"name":"FR - Le Phare (2019) 4K","stream_type":"movie","stream_id":"501","stream_icon":"http://img/p.jpg",
          "rating":"7.4","added":"1700000000","category_id":"10","container_extension":"mkv"},
         {"name":"Sans identifiant"},
         {"stream_id":502,"name":"Marées","rating":"","rating_5based":3.5,"category_id":11,"container_extension":"","year":"2021"},
         {"stream_id":503,"name":"Chaîne égarée","stream_type":"live"},
         {"stream_id":501,"name":"Doublon"}]
        """#
        let movies = try XtreamClient.decodeMovies(Data(json.utf8))
        XCTAssertEqual(movies.map(\.id), [501, 502])
        XCTAssertEqual(movies[0].containerExtension, "mkv")
        XCTAssertEqual(movies[0].rating, 7.4)
        XCTAssertEqual(movies[0].year, 2019)
        XCTAssertEqual(movies[0].posterURL?.absoluteString, "http://img/p.jpg")
        XCTAssertEqual(movies[0].addedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(movies[1].containerExtension, "mp4", "extension absente : repli mp4")
        XCTAssertEqual(movies[1].rating, 7.0, "note sur 5 ramenée sur 10")
        XCTAssertEqual(movies[1].categoryIDs, [CategoryID("11")])
        XCTAssertEqual(movies[1].year, 2021)
    }

    func testMovieInfoAcceptsEmptyInfoArrayAndBackdropList() throws {
        let empty = try JSONDecoder().decode(VODInfoResponseDTO.self, from: Data(#"{"info":[],"movie_data":{"stream_id":1,"container_extension":"mp4"}}"#.utf8))
        XCTAssertNil(empty.details.plot)
        XCTAssertEqual(empty.details.containerExtension, "mp4")

        let full = #"""
        {"info":{"plot":"Un gardien.","genre":"Drame","cast":"A, B","director":"C","releasedate":"2019-05-02",
          "duration":"01:49:30","backdrop_path":["http://img/b1.jpg","http://img/b2.jpg"],"rating":"8","tmdb_id":"42"},
         "movie_data":{"container_extension":"MKV"}}
        """#
        let details = try JSONDecoder().decode(VODInfoResponseDTO.self, from: Data(full.utf8)).details
        XCTAssertEqual(details.plot, "Un gardien.")
        XCTAssertEqual(details.durationSeconds, 6570)
        XCTAssertEqual(details.backdropURL?.absoluteString, "http://img/b1.jpg")
        XCTAssertEqual(details.year, 2019)
        XCTAssertEqual(details.tmdbID, 42)
        XCTAssertEqual(details.containerExtension, "mkv")
    }

    func testSeriesInfoWithEpisodesBySeason() throws {
        let json = #"""
        {"seasons":[{"season_number":1,"name":"Saison 1"},{"season_number":0,"name":"Spéciaux"}],
         "info":{"plot":"Une île.","backdrop_path":"http://img/s.jpg"},
         "episodes":{"2":[{"id":"9002","episode_num":"1","title":"Île - S02E01 - Retour","container_extension":"mp4","info":[]}],
                     "1":[{"id":9001,"episode_num":2,"title":"","container_extension":"mkv","info":{"duration_secs":"2700"}},
                          {"id":"9000","episode_num":1,"title":"Île S01E01 Départ","season":"1"}]}}
        """#
        let details = try JSONDecoder().decode(SeriesInfoResponseDTO.self, from: Data(json.utf8)).details
        XCTAssertEqual(details.episodes.map(\.id), ["9000", "9001", "9002"])
        XCTAssertEqual(details.episodes.map(\.title), ["Départ", "Épisode 2", "Retour"])
        XCTAssertEqual(details.episodes[1].durationSeconds, 2700)
        XCTAssertEqual(details.episodes[1].containerExtension, "mkv")
        XCTAssertEqual(details.seasons.map(\.number), [1, 2], "saison annoncée sans épisode masquée, saison déduite ajoutée")
        XCTAssertEqual(details.backdropURL?.absoluteString, "http://img/s.jpg")
        XCTAssertEqual(details.episode(after: details.episodes[1])?.id, "9002", "suivant : saison suivante comprise")
        XCTAssertNil(details.episode(after: details.episodes[2]))
    }

    func testSeriesInfoWithEpisodeArrays() throws {
        let nested = #"{"episodes":[[{"id":"1","episode_num":1}],[{"id":"2","episode_num":1}]],"info":[],"seasons":[]}"#
        let a = try JSONDecoder().decode(SeriesInfoResponseDTO.self, from: Data(nested.utf8)).details
        XCTAssertEqual(a.episodes.map(\.code), ["S1 E1", "S2 E1"])

        let flat = #"{"episodes":[{"id":"7","episode_num":3,"season":2}],"info":{}}"#
        let b = try JSONDecoder().decode(SeriesInfoResponseDTO.self, from: Data(flat.utf8)).details
        XCTAssertEqual(b.episodes.map(\.code), ["S2 E3"])
    }

    func testSeriesList() throws {
        let json = #"""
        [{"series_id":"77","name":"Île (2020)","cover":"http://img/c.jpg","backdrop_path":[],"rating_5based":"4",
          "releaseDate":"2020-01-01","last_modified":"1700000500","category_id":"3"},
         {"name":"invalide"}]
        """#
        let series = try XtreamClient.decodeSeries(Data(json.utf8))
        XCTAssertEqual(series.map(\.id), [77])
        XCTAssertEqual(series[0].rating, 8)
        XCTAssertEqual(series[0].year, 2020)
        XCTAssertNil(series[0].backdropURL)
    }

    func testURLsAndRequests() async throws {
        let urls = XtreamURLBuilder(credentials: testCredentials)
        XCTAssertEqual(urls.movieURL(id: 501, containerExtension: "mkv").absoluteString, "http://example.tv:8080/movie/alice/s3cr3t+pw/501.mkv")
        XCTAssertEqual(urls.episodeURL(id: "9001", containerExtension: "mp4").absoluteString, "http://example.tv:8080/series/alice/s3cr3t+pw/9001.mp4")

        let http = MockHTTPClient(sequence: [ok(Data(#"{"info":[],"movie_data":{}}"#.utf8))])
        _ = try await client(http).movieDetails(501)
        let query = URLComponents(url: http.requests[0].url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "action" }?.value, "get_vod_info")
        XCTAssertEqual(query.first { $0.name == "vod_id" }?.value, "501")
    }

    func testMoviesByCategoryMerges() async throws {
        let http = MockHTTPClient([{ request in
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch query.first(where: { $0.name == "category_id" })?.value {
            case "1": return ok(Data(#"[{"stream_id":1,"name":"A"},{"stream_id":2,"name":"B"}]"#.utf8))
            case "2": return ok(Data(#"[{"stream_id":2,"name":"B"}]"#.utf8))
            default: return status(500)
            }
        }])
        let categories = ["1", "2"].enumerated().map { ChannelCategory(id: CategoryID($0.element), name: $0.element, serverOrder: $0.offset) }
        let movies = try await client(http).movies(byCategory: categories)
        XCTAssertEqual(movies.map(\.id), [1, 2])
        XCTAssertEqual(movies[1].categoryIDs, [CategoryID("1"), CategoryID("2")])
    }

    func testProviderPageIsRejected() async {
        let http = MockHTTPClient(sequence: [ok(Data("<html>Maintenance</html>".utf8))])
        do {
            _ = try await client(http).series()
            XCTFail("échec attendu")
        } catch {
            XCTAssertEqual(error, .unexpectedResponse(context: "séries"))
        }
    }
}

final class VODCatalogAndProgressTests: XCTestCase {
    func testTitleCleaning() {
        XCTAssertEqual(VODText.title("FR - Le Phare (2019) 4K"), "Le Phare")
        XCTAssertEqual(VODText.title("1917"), "1917", "un titre qui est une année reste intact")
        XCTAssertEqual(VODText.episodeTitle("Île - S01E03 - ", number: 3), "Épisode 3")
        XCTAssertEqual(VODText.durationLabel(6570), "1 h 49")
        XCTAssertEqual(VODText.durationLabel(3120), "52 min")
        XCTAssertTrue(VODText.isAdultCategory("XXX | Adultes"))
        XCTAssertTrue(VODText.isAdultCategory("FR - 18+"))
        XCTAssertFalse(VODText.isAdultCategory("Films 2018"))
    }

    func testCatalogFiltersSearchesAndSortsRecents() {
        let categories = [ChannelCategory(id: CategoryID("1"), name: "Action", serverOrder: 0),
                          ChannelCategory(id: CategoryID("2"), name: "Adultes XXX", serverOrder: 1),
                          ChannelCategory(id: CategoryID("3"), name: "Vide", serverOrder: 2)]
        let movies = [
            Movie(id: 1, name: "FR - Le Phare", addedAt: Date(timeIntervalSince1970: 10), categoryIDs: [CategoryID("1")]),
            Movie(id: 2, name: "Phare ouest", addedAt: Date(timeIntervalSince1970: 30), categoryIDs: [CategoryID("1")]),
            Movie(id: 3, name: "Nuit chaude", addedAt: Date(timeIntervalSince1970: 50), categoryIDs: [CategoryID("2")]),
            Movie(id: 4, name: "Les éléphants", categoryIDs: [CategoryID("1")]),
        ]
        let catalog = VODCatalog(categories: categories, items: movies)
        XCTAssertEqual(catalog.visibleCategories(hideAdult: true).map(\.name), ["Action"])
        XCTAssertEqual(catalog.visibleCategories(hideAdult: false).map(\.name), ["Action", "Adultes XXX"])
        XCTAssertEqual(catalog.recentlyAdded(hideAdult: true).map(\.id), [2, 1])
        XCTAssertEqual(catalog.recentlyAdded(hideAdult: false).map(\.id), [3, 2, 1])
        XCTAssertEqual(catalog.search("phare", hideAdult: true).map(\.id), [2, 1], "« Phare ouest » commence par la recherche")
        XCTAssertEqual(catalog.search("ELEPHANT", hideAdult: true).map(\.id), [4], "accents et casse ignorés")
        XCTAssertEqual(catalog.search("nuit", hideAdult: true).map(\.id), [])
        XCTAssertEqual(catalog.items(in: CategoryID("1"), hideAdult: true).count, 3)
    }

    private func movieEntry(_ id: Int, position: Double, duration: Double = 6000, at time: TimeInterval) -> WatchProgress.Entry {
        WatchProgress.Entry(kind: .movie, itemID: id, position: position, duration: duration,
                            updatedAt: Date(timeIntervalSince1970: time), title: "Film \(id)", containerExtension: "mkv")
    }

    private func episodeEntry(_ id: String, series: Int, position: Double, at time: TimeInterval) -> WatchProgress.Entry {
        WatchProgress.Entry(kind: .episode, itemID: series, episodeID: id, position: position, duration: 2700,
                            updatedAt: Date(timeIntervalSince1970: time), title: "Série \(series)", containerExtension: "mp4")
    }

    func testResumeAndFinished() {
        var progress = WatchProgress()
        progress.record(movieEntry(1, position: 1200, at: 1))
        XCTAssertEqual(progress.resumePosition("m1"), 1195, "reprise quelques secondes avant l'arrêt")
        progress.record(movieEntry(1, position: 8, at: 2))
        XCTAssertEqual(progress.resumePosition("m1"), 1195, "un essai de quelques secondes n'efface pas la reprise")
        progress.record(movieEntry(1, position: 5880, at: 3))
        XCTAssertTrue(progress.isFinished("m1"), "générique : film vu")
        XCTAssertNil(progress.resumePosition("m1"))
        progress.record(movieEntry(2, position: 10, at: 4))
        XCTAssertNil(progress.resumePosition("m2"), "moins de 30 s : pas de reprise")
        XCTAssertTrue(WatchProgress.isFinished(position: 92, duration: 100))
        XCTAssertFalse(WatchProgress.isFinished(position: 500, duration: 0))
    }

    func testContinueWatchingKeepsOneEntryPerSeriesAndQueuedNext() {
        var progress = WatchProgress()
        progress.record(movieEntry(1, position: 600, at: 10))
        progress.record(episodeEntry("a", series: 7, position: 900, at: 20))
        progress.record(episodeEntry("b", series: 7, position: 2650, at: 30))   // fini
        XCTAssertEqual(progress.continueWatching().map(\.key), ["m1"], "série au dernier épisode fini : rien à reprendre")
        progress.queue(episodeEntry("c", series: 7, position: 0, at: 30))
        XCTAssertEqual(progress.continueWatching().map(\.key), ["ec", "m1"], "épisode suivant « À suivre », plus récent que le précédent")
        progress.record(episodeEntry("c", series: 7, position: 12, at: 40))
        XCTAssertEqual(progress.entry("ec")?.queued, true, "quelques secondes ne retirent pas « À suivre »")
        progress.setFinished(movieEntry(1, position: 0, at: 50), true)
        XCTAssertEqual(progress.continueWatching().map(\.key), ["ec"])
    }

    func testProgressIsPrunedAndCodable() throws {
        var progress = WatchProgress()
        for i in 0..<(WatchProgress.maxEntries + 10) { progress.record(movieEntry(i, position: 100, at: TimeInterval(i))) }
        XCTAssertEqual(progress.entries.count, WatchProgress.maxEntries)
        XCTAssertNil(progress.entry("m0"), "les plus anciennes sont retirées")
        let decoded = try JSONDecoder().decode(WatchProgress.self, from: JSONEncoder().encode(progress))
        XCTAssertEqual(decoded, progress)
        XCTAssertLessThan(try JSONEncoder().encode(progress).count, 64 * 1024)
    }

    func testTrackChoice() {
        let audio = [MediaTrack(id: 0, title: "Anglais", isSelected: true, language: "eng", isDefault: true),
                     MediaTrack(id: 1, title: "Français", isSelected: false, language: "fre")]
        let subs = [MediaTrack(id: 5, title: "Français forcés", isSelected: false, language: "fr", isForced: true),
                    MediaTrack(id: 6, title: "Français", isSelected: false, language: "fra"),
                    MediaTrack(id: 7, title: "Anglais", isSelected: false, language: "en")]
        XCTAssertEqual(TrackChoice.audio(audio)?.id, 1, "français préféré à la piste par défaut")
        XCTAssertEqual(TrackChoice.subtitle(subs, audio: audio[1])?.id, 5, "audio français : forcés seulement")
        XCTAssertEqual(TrackChoice.subtitle(subs, audio: audio[0])?.id, 6, "VO : sous-titres français complets")
        XCTAssertNil(TrackChoice.subtitle([subs[2]], audio: audio[1]))
        XCTAssertEqual(LanguageCode.normalize("Français"), "fr")
        XCTAssertNil(LanguageCode.normalize("und"))
    }
}
