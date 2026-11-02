import Foundation
import XCTest
@testable import MinuitCore

final class ServerAddressTests: XCTestCase {
    func testParsesCommonUserInputs() throws {
        XCTAssertEqual(try ServerAddress.parse("example.tv:8080"), ServerAddress(scheme: .http, host: "example.tv", port: 8080))
        XCTAssertEqual(try ServerAddress.parse("  HTTP://Example.TV:8080/  "), ServerAddress(scheme: .http, host: "example.tv", port: 8080))
        XCTAssertEqual(try ServerAddress.parse("http://example.tv:8080/player_api.php?username=a&password=b"),
                       ServerAddress(scheme: .http, host: "example.tv", port: 8080))
        XCTAssertEqual(try ServerAddress.parse("http://example.tv/get.php?username=a&password=b&type=m3u_plus"),
                       ServerAddress(scheme: .http, host: "example.tv"))
        XCTAssertEqual(try ServerAddress.parse("https://example.tv:443"), ServerAddress(scheme: .https, host: "example.tv"))
        XCTAssertEqual(try ServerAddress.parse("http://example.tv/xc/player_api.php"),
                       ServerAddress(scheme: .http, host: "example.tv", pathPrefix: "/xc"))
    }

    func testRejectsInvalidInput() {
        XCTAssertThrowsError(try ServerAddress.parse("")) { XCTAssertEqual($0 as? ServerAddress.ParseError, .empty) }
        XCTAssertThrowsError(try ServerAddress.parse("ftp://example.tv")) {
            XCTAssertEqual($0 as? ServerAddress.ParseError, .unsupportedScheme("ftp"))
        }
        XCTAssertThrowsError(try ServerAddress.parse("http://"))
    }

    func testCredentialsDescriptionNeverRevealsSecrets() {
        let text = "\(testCredentials) \(String(reflecting: testCredentials))"
        XCTAssertFalse(text.contains("s3cr3t"))
        XCTAssertFalse(text.contains("alice"))
    }
}

final class XtreamURLBuilderTests: XCTestCase {
    let builder = XtreamURLBuilder(credentials: testCredentials)

    func testLiveURLs() {
        XCTAssertEqual(builder.liveURL(channel: ChannelID(101), format: .mpegts).absoluteString,
                       "http://example.tv:8080/live/alice/s3cr3t+pw/101.ts")
        XCTAssertEqual(builder.liveURL(channel: ChannelID(101), format: .hls).absoluteString,
                       "http://example.tv:8080/live/alice/s3cr3t+pw/101.m3u8")
    }

    func testPathPrefixAndReservedCharactersAreEncoded() throws {
        let credentials = XtreamCredentials(server: try ServerAddress.parse("http://h.tv/xc"), username: "a b", password: "p/w?#")
        let url = XtreamURLBuilder(credentials: credentials).liveURL(channel: ChannelID(7), format: .mpegts)
        XCTAssertEqual(url.absoluteString, "http://h.tv/xc/live/a%20b/p%2Fw%3F%23/7.ts")
    }

    func testAPIURLEncodesPlusSign() {
        let url = builder.apiURL(action: "get_live_streams", parameters: ["category_id": "3"])
        XCTAssertEqual(url.absoluteString,
                       "http://example.tv:8080/player_api.php?username=alice&password=s3cr3t%2Bpw&action=get_live_streams&category_id=3")
    }

    func testTimeshiftUsesServerTimeZone() {
        // 19:05 UTC = 20:05 à Paris (heure d'hiver, 2 novembre 2026).
        let start = utc("2026-11-02 19:05")
        let url = builder.timeshiftURL(channel: ChannelID(101), start: start, durationMinutes: 95, serverTimeZone: paris, style: .path)
        XCTAssertEqual(url.absoluteString, "http://example.tv:8080/timeshift/alice/s3cr3t+pw/95/2026-11-02:20-05/101.ts")

        let query = builder.timeshiftURL(channel: ChannelID(101), start: start, durationMinutes: 95, serverTimeZone: paris, style: .query)
        XCTAssertEqual(query.absoluteString,
                       "http://example.tv:8080/streaming/timeshift.php?username=alice&password=s3cr3t%2Bpw&stream=101&start=2026-11-02:20-05&duration=95")
    }

    func testTimeshiftTimestampAcrossDSTChange() {
        // 25 octobre 2026 : 01:30 UTC = 02:30 heure d'hiver à Paris (après le recul de 03:00 → 02:00).
        XCTAssertEqual(XtreamURLBuilder.timeshiftTimestamp(utc("2026-10-25 01:30"), timeZone: paris), "2026-10-25:02-30")
        // 00:30 UTC = 02:30 heure d'été (avant le recul) : même heure murale, instant différent.
        XCTAssertEqual(XtreamURLBuilder.timeshiftTimestamp(utc("2026-10-25 00:30"), timeZone: paris), "2026-10-25:02-30")
    }
}

final class XtreamDecodingTests: XCTestCase {
    let now = utc("2026-11-02 15:30")

    func testActiveAccount() throws {
        let dto = try JSONDecoder().decode(AuthResponseDTO.self, from: Fixture.data("auth_active.json"))
        let session = try XtreamClient.session(from: dto, now: now)
        XCTAssertEqual(session.account.status, .active)
        XCTAssertEqual(session.account.maxConnections, 2)
        XCTAssertEqual(session.account.allowedFormats, [.hls, .mpegts])
        XCTAssertEqual(session.account.otherFormats, ["rtmp"])
        XCTAssertEqual(session.server.timeZone.identifier, "Europe/Paris")
        XCTAssertEqual(session.server.httpsPort, 8443)
        XCTAssertEqual(session.server.clockSkew, 0, accuracy: 1)
    }

    func testVariantTypesAndOffsetTimeZone() throws {
        let dto = try JSONDecoder().decode(AuthResponseDTO.self, from: Fixture.data("auth_variant_types.json"))
        let session = try XtreamClient.session(from: dto, now: now)
        XCTAssertNil(session.account.expiresAt)
        XCTAssertEqual(session.account.activeConnections, 1)
        // Liste de formats vide : TS et HLS supposés disponibles.
        XCTAssertEqual(session.account.allowedFormats, [.hls, .mpegts])
        // "GMT+1" n'est pas un identifiant IANA reconnu partout ; à défaut, décalage déduit de time_now.
        XCTAssertEqual(session.server.timeZone.secondsFromGMT(for: now), 3600)
    }

    func testExpiredAccountIsReported() throws {
        let dto = try JSONDecoder().decode(AuthResponseDTO.self, from: Fixture.data("auth_expired.json"))
        XCTAssertThrowsError(try XtreamClient.session(from: dto, now: now)) { error in
            guard case .accountExpired(let date)? = error as? XtreamError else { return XCTFail("\(error)") }
            XCTAssertEqual(date, Date(timeIntervalSince1970: 1_600_000_000))
        }
    }

    func testRejectedAuthentication() throws {
        let dto = try JSONDecoder().decode(AuthResponseDTO.self, from: Fixture.data("auth_rejected.json"))
        XCTAssertThrowsError(try XtreamClient.session(from: dto, now: now)) {
            XCTAssertEqual($0 as? XtreamError, .authenticationRejected)
        }
    }

    func testCategoriesToleratesBadEntries() throws {
        let list = try JSONDecoder().decode(LossyArray<LiveCategoryDTO>.self, from: Fixture.data("live_categories.json"))
        XCTAssertEqual(list.elements.map(\.id), ["1", "2", "9"])
        XCTAssertEqual(list.droppedCount, 1)
        XCTAssertEqual(list.elements[0].name, "FR | Généralistes")
    }

    func testStreamsDecoding() throws {
        let channels = try XtreamClient.decodeChannels(Fixture.data("live_streams.json"))
        XCTAssertEqual(channels.map(\.id.rawValue), [101, 102, 103, 104, 105], "VOD, doublons et entrées sans id exclus")
        let tf1 = channels[0]
        XCTAssertEqual(tf1.number, 1)
        XCTAssertEqual(tf1.logoURL?.absoluteString, "http://logos.example/tf1.png")
        XCTAssertEqual(tf1.archive?.days, 7)
        XCTAssertEqual(tf1.epgChannelID, "TF1.fr")
        XCTAssertNil(channels[1].logoURL, "icône vide ignorée")
        XCTAssertNil(channels[1].archive)
        XCTAssertNil(channels[2].archive, "tv_archive=1 avec durée 0 : pas de capacité exploitable")
        XCTAssertEqual(channels[3].categoryIDs, [CategoryID("2"), CategoryID("1")])
        XCTAssertEqual(channels[3].archive?.days, 3)
        XCTAssertTrue(channels[4].isAdult)
    }

    func testShortEPGBase64AndTimestamps() throws {
        let programmes = try XtreamClient.decodeProgrammes(Fixture.data("short_epg.json"), channel: ChannelID(101),
                                                           serverTimeZone: paris, source: .xtreamShort)
        XCTAssertEqual(programmes.count, 2)
        XCTAssertEqual(programmes[0].title, "Le Journal de 13h")
        XCTAssertEqual(programmes[0].summary, "Toute l'actualité — édition spéciale.")
        XCTAssertEqual(programmes[0].start, utc("2026-11-02 12:00"))
        XCTAssertEqual(programmes[0].end, utc("2026-11-02 12:45"))
        XCTAssertNil(programmes[1].summary)
    }

    func testShortEPGVariantWithWallClockAndPlainText() throws {
        let programmes = try XtreamClient.decodeProgrammes(Fixture.data("short_epg_variant.json"), channel: ChannelID(1),
                                                           serverTimeZone: paris, source: .xtreamShort)
        XCTAssertEqual(programmes.count, 2)
        XCTAssertEqual(programmes[0].title, "Plain Title Here!")
        XCTAssertEqual(programmes[0].summary, "Pas en base64.")
        // 16:00 heure de Paris = 15:00 UTC.
        XCTAssertEqual(programmes[0].start, utc("2026-11-02 15:00"))
        XCTAssertEqual(programmes[1].title, "Suite")
        XCTAssertEqual(programmes[1].archiveFlag, true)
    }

    func testFullEPGArchiveFlags() throws {
        let programmes = try XtreamClient.decodeProgrammes(Fixture.data("full_epg.json"), channel: ChannelID(101),
                                                           serverTimeZone: paris, source: .xtreamFull)
        XCTAssertEqual(programmes.map(\.archiveFlag), [true, false])
    }

    func testBase64HeuristicKeepsPlainWords() {
        XCTAssertEqual(XtreamEPGMapper.decodeBase64IfNeeded("Test"), "Test")
        XCTAssertEqual(XtreamEPGMapper.decodeBase64IfNeeded("News"), "News")
        XCTAssertEqual(XtreamEPGMapper.decodeBase64IfNeeded("SGVsbG8="), "Hello")
    }
}

final class XtreamClientTests: XCTestCase {
    func makeClient(_ http: MockHTTPClient, policy: TransportSecurityPolicy = .allowHTTP) -> XtreamClient {
        var client = XtreamClient(credentials: testCredentials, http: http, policy: policy, now: { utc("2026-11-02 15:30") })
        client.retry = RetryPolicy(maxAttempts: 3, baseDelay: 0.001, maxDelay: 0.002)
        return client
    }

    func testAuthenticateSuccess() async throws {
        let http = MockHTTPClient(sequence: [ok(try Fixture.data("auth_active.json"))])
        let session = try await makeClient(http).authenticate()
        XCTAssertEqual(session.account.status, .active)
        XCTAssertEqual(http.requests.first?.url.path, "/player_api.php")
    }

    func testRetriesTransientErrorsThenSucceeds() async throws {
        let http = MockHTTPClient(sequence: [.failure(.timedOut), status(503), ok(try Fixture.data("live_categories.json"))])
        let categories = try await makeClient(http).liveCategories()
        XCTAssertEqual(categories.count, 3)
        XCTAssertEqual(http.requestCount, 3)
    }

    func testDoesNotRetryAuthorizationErrors() async throws {
        let http = MockHTTPClient(sequence: [status(403), ok(Data("[]".utf8))])
        do {
            _ = try await makeClient(http).liveCategories()
            XCTFail("403 attendu")
        } catch {
            XCTAssertEqual(error, .http(status: 403))
        }
        XCTAssertEqual(http.requestCount, 1)
    }

    func testGivesUpAfterMaxAttempts() async {
        let http = MockHTTPClient(sequence: [.failure(.cannotConnect)])
        do {
            _ = try await makeClient(http).liveCategories()
            XCTFail()
        } catch {
            XCTAssertEqual(error, .transport(.cannotConnect))
        }
        XCTAssertEqual(http.requestCount, 3)
    }

    func testRequireHTTPSRefusesPlainHTTP() async {
        let http = MockHTTPClient(sequence: [ok(Data())])
        do {
            _ = try await makeClient(http, policy: .requireHTTPS).authenticate()
            XCTFail()
        } catch {
            XCTAssertEqual(error, .insecureConnectionRefused)
        }
        XCTAssertEqual(http.requestCount, 0, "aucune requête ne doit partir en clair")
    }

    func testNonJSONResponseIsExplicitError() async {
        let http = MockHTTPClient(sequence: [ok(Data("<html>Panel</html>".utf8))])
        do {
            _ = try await makeClient(http).authenticate()
            XCTFail()
        } catch {
            XCTAssertEqual(error, .unexpectedResponse(context: "authentification"))
        }
    }

    func testPlainHTTPServerIsAccepted() async throws {
        let http = MockHTTPClient(sequence: [ok(try Fixture.data("auth_active.json"))])
        XCTAssertEqual(testCredentials.server.scheme, .http)
        _ = try await makeClient(http, policy: .allowHTTP).authenticate()
        XCTAssertEqual(http.requests.first?.url.scheme, "http")
    }

    func testSystemTransportBlockIsReportedAsSuch() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorAppTransportSecurityRequiresSecureConnection)
        XCTAssertEqual(URLSessionHTTPClient.classify(error), .blockedBySystemPolicy)
        XCTAssertFalse(XtreamError.transport(.blockedBySystemPolicy).userMessage.contains("HTTPS a échoué"))
    }

    func testErrorMessagesNeverContainSecrets() {
        let errors: [XtreamError] = [.transport(.timedOut), .http(status: 403), .authenticationRejected,
                                     .accountExpired(Date()), .tooManyConnections(max: 2), .unexpectedResponse(context: "x")]
        for error in errors {
            XCTAssertFalse(error.userMessage.contains("alice"))
            XCTAssertFalse(error.userMessage.contains("s3cr3t"))
            XCTAssertFalse(error.userMessage.contains("http"))
        }
    }
}

final class RedactorTests: XCTestCase {
    func testRedactsPathAndQueryCredentials() {
        let redactor = Redactor(credentials: testCredentials)
        let builder = XtreamURLBuilder(credentials: testCredentials)
        let urls = [builder.liveURL(channel: ChannelID(1), format: .mpegts),
                    builder.apiURL(action: "get_live_streams"),
                    builder.timeshiftURL(channel: ChannelID(1), start: Date(), durationMinutes: 10, serverTimeZone: paris, style: .query),
                    builder.timeshiftURL(channel: ChannelID(1), start: Date(), durationMinutes: 10, serverTimeZone: paris, style: .path)]
        for url in urls {
            let text = redactor.redact("Échec lecture \(url.absoluteString) code=5")
            XCTAssertFalse(text.contains("alice"), text)
            XCTAssertFalse(text.contains("s3cr3t"), text)
            XCTAssertTrue(text.contains("example.tv"), "l'hôte reste utile au diagnostic")
        }
    }

    func testRedactsURLsWithoutKnownSecrets() {
        let text = Redactor().redact("GET http://h.tv/live/bob/hunter22/5.m3u8 et http://h.tv/player_api.php?username=bob&password=hunter22")
        XCTAssertFalse(text.contains("hunter22"), text)
        XCTAssertFalse(text.contains("bob"), text)
    }

    func testRedactsShortFormStreamURL() {
        let text = Redactor().redact("http://h.tv:80/bob/hunter22/5.ts")
        XCTAssertFalse(text.contains("hunter22"), text)
    }
}
