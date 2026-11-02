import Foundation
import XCTest
@testable import MinuitCore

final class XMLTVTests: XCTestCase {
    func testDateFormats() {
        XCTAssertEqual(XMLTVDate.parse("20261102130000 +0100"), utc("2026-11-02 12:00"))
        XCTAssertEqual(XMLTVDate.parse("20261102130000+0100"), utc("2026-11-02 12:00"))
        XCTAssertEqual(XMLTVDate.parse("20261102130000 -0530"), utc("2026-11-02 18:30"))
        XCTAssertEqual(XMLTVDate.parse("20261102130000"), utc("2026-11-02 13:00"), "sans fuseau : UTC (norme XMLTV)")
        XCTAssertEqual(XMLTVDate.parse("202611021300"), utc("2026-11-02 13:00"))
        XCTAssertEqual(XMLTVDate.parse("20261102130000.000 +0000"), utc("2026-11-02 13:00"))
        XCTAssertNil(XMLTVDate.parse("garbage"))
        XCTAssertNil(XMLTVDate.parse("20261302130000"))
    }

    func testParsesSampleDocument() throws {
        let doc = try XMLTVParser.parse(Fixture.data("sample.xmltv"))
        XCTAssertEqual(doc.channels.map(\.key), ["TF1.fr", "France2.fr", "arte.fr"])
        XCTAssertEqual(doc.channels[0].displayNames, ["TF1", "TF1 HD"])
        XCTAssertEqual(doc.channels[0].iconURL?.absoluteString, "http://logos.example/tf1.png")
        XCTAssertEqual(doc.skippedProgrammes, 1)

        let journal = try XCTUnwrap(doc.programmes.first)
        XCTAssertEqual(journal.title, "Le Journal de 13h", "titre dans la langue préférée")
        XCTAssertEqual(journal.subtitle, "Édition du lundi")
        XCTAssertEqual(journal.summary, "Toute l'actualité & la météo.")
        XCTAssertEqual(journal.category, "Information")
        XCTAssertEqual(journal.iconURL?.absoluteString, "http://img.example/jt.jpg")
        XCTAssertEqual(journal.start, utc("2026-11-02 12:00"))
        XCTAssertNil(doc.programmes.first { $0.title == "Sans fin indiquée" }?.end)
    }

    func testFiltersByChannelAndWindow() throws {
        let options = XMLTVParser.Options(channelKeys: ["tf1.fr"],
                                          window: DateInterval(start: utc("2026-11-02 00:00"), end: utc("2026-11-04 00:00")))
        let doc = try XMLTVParser.parse(Fixture.data("sample.xmltv"), options: options)
        XCTAssertEqual(doc.programmes.map(\.title), ["Le Journal de 13h", "Les Feux de l'amour"])
    }

    func testTruncatedDocumentKeepsParsedProgrammes() throws {
        var data = try Fixture.data("sample.xmltv")
        data = data.prefix(data.count / 2 + 200)
        let doc = try XMLTVParser.parse(data)
        XCTAssertFalse(doc.programmes.isEmpty)
    }

    func testImporterMapsByIDAndName() throws {
        let doc = try XMLTVParser.parse(Fixture.data("sample.xmltv"))
        let channels = [
            Channel(id: ChannelID(101), name: "FR: TF1 HD", epgChannelID: "tf1.FR"),
            Channel(id: ChannelID(102), name: "FR: France 2", epgChannelID: "France2.fr"),
            Channel(id: ChannelID(103), name: "FR: Arte"),
            Channel(id: ChannelID(104), name: "Inconnue"),
        ]
        let result = EPGImporter.map(doc, to: channels)
        XCTAssertEqual(result.programmes[ChannelID(101)]?.count, 3)
        XCTAssertEqual(result.programmes[ChannelID(103)]?.first?.title, "Documentaire", "liaison par nom normalisé")
        XCTAssertEqual(result.matchedByName, 1)
        XCTAssertNil(result.programmes[ChannelID(104)])
        // Programme sans fin : une heure par défaut, puis tronqué par le suivant au nettoyage.
        var index = EPGIndex()
        index.replace(result.programmes[ChannelID(102)]!, for: ChannelID(102), at: Date())
        XCTAssertEqual(index.programmes(for: ChannelID(102)).first?.end, utc("2026-11-02 15:00"))
    }
}

final class EPGIndexTests: XCTestCase {
    let channel = ChannelID(1)

    func p(_ start: String, _ end: String, _ title: String, source: Programme.Source = .xmltv, archive: Bool? = nil) -> Programme {
        Programme(channel: channel, start: utc(start), end: utc(end), title: title, archiveFlag: archive, source: source)
    }

    func testNowNextWithGap() {
        var index = EPGIndex()
        index.replace([p("2026-11-02 12:00", "2026-11-02 13:00", "A"),
                       p("2026-11-02 14:00", "2026-11-02 15:00", "B"),
                       p("2026-11-02 15:00", "2026-11-02 16:00", "C")], for: channel, at: Date())
        var result = index.nowNext(for: channel, at: utc("2026-11-02 12:30"))
        XCTAssertEqual(result.now?.title, "A")
        XCTAssertEqual(result.next?.title, "B")
        result = index.nowNext(for: channel, at: utc("2026-11-02 13:30"))
        XCTAssertNil(result.now, "trou dans le guide")
        XCTAssertEqual(result.next?.title, "B")
        result = index.nowNext(for: channel, at: utc("2026-11-02 15:00"))
        XCTAssertEqual(result.now?.title, "C", "borne de début incluse")
        result = index.nowNext(for: channel, at: utc("2026-11-02 11:00"))
        XCTAssertNil(result.now)
        XCTAssertEqual(result.next?.title, "A")
        XCTAssertNil(index.nowNext(for: ChannelID(99), at: Date()).now)
    }

    func testSlotsIncludeGaps() {
        var index = EPGIndex()
        index.replace([p("2026-11-02 12:00", "2026-11-02 13:00", "A"),
                       p("2026-11-02 14:00", "2026-11-02 15:00", "B")], for: channel, at: Date())
        let slots = index.slots(for: channel, in: DateInterval(start: utc("2026-11-02 12:30"), end: utc("2026-11-02 16:00")))
        XCTAssertEqual(slots.count, 4)
        guard case .programme(let first) = slots[0], case .gap(let gap) = slots[1], case .gap(let tail) = slots[3] else {
            return XCTFail("\(slots)")
        }
        XCTAssertEqual(first.title, "A")
        XCTAssertEqual(gap, DateInterval(start: utc("2026-11-02 13:00"), end: utc("2026-11-02 14:00")))
        XCTAssertEqual(tail.start, utc("2026-11-02 15:00"))
    }

    func testSanitizerFixesOverlapsDuplicatesAndAbsurdDurations() {
        let cleaned = EPGSanitizer.sanitize([
            p("2026-11-02 12:00", "2026-11-02 13:30", "A"),
            p("2026-11-02 13:00", "2026-11-02 14:00", "B"),
            p("2026-11-02 13:00", "2026-11-02 14:00", "B riche", source: .xtreamFull),
            p("2026-11-02 15:00", "2026-11-02 15:00", "Durée nulle"),
            p("2026-11-02 16:00", "2026-11-03 16:00", "Trop long"),
        ])
        XCTAssertEqual(cleaned.map(\.title), ["A", "B riche", "Trop long"])
        XCTAssertEqual(cleaned[0].end, utc("2026-11-02 13:00"))
        XCTAssertEqual(cleaned[2].duration, EPGSanitizer.maximumDuration)
    }

    func testMergeReplacesCoveredRangeAndRespectsRicherSource() {
        var index = EPGIndex()
        index.replace([p("2026-11-02 10:00", "2026-11-02 11:00", "X0"),
                       p("2026-11-02 11:00", "2026-11-02 12:00", "X1"),
                       p("2026-11-02 12:00", "2026-11-02 13:00", "X2")], for: channel, at: Date())
        // Données Xtream complètes (plus riches) sur 11:00–13:00 : remplacent le XMLTV.
        index.merge([p("2026-11-02 11:00", "2026-11-02 12:30", "F1", source: .xtreamFull, archive: true),
                     p("2026-11-02 12:30", "2026-11-02 13:00", "F2", source: .xtreamFull, archive: false)], for: channel, at: Date())
        XCTAssertEqual(index.programmes(for: channel).map(\.title), ["X0", "F1", "F2"])
        // Programme court (moins riche) sur la même plage : ignoré là où le complet existe.
        index.merge([p("2026-11-02 11:00", "2026-11-02 12:00", "S1", source: .xtreamShort)], for: channel, at: Date())
        XCTAssertEqual(index.programmes(for: channel).map(\.title), ["X0", "F1", "F2"])
        // Programme court au-delà de la couverture : ajouté.
        index.merge([p("2026-11-02 13:00", "2026-11-02 14:00", "S2", source: .xtreamShort)], for: channel, at: Date())
        XCTAssertEqual(index.programmes(for: channel).map(\.title), ["X0", "F1", "F2", "S2"])
    }

    func testPrune() {
        var index = EPGIndex()
        index.replace([p("2026-11-01 10:00", "2026-11-01 11:00", "Old"), p("2026-11-02 10:00", "2026-11-02 11:00", "New")], for: channel, at: Date())
        index.prune(before: utc("2026-11-02 00:00"))
        XCTAssertEqual(index.programmes(for: channel).map(\.title), ["New"])
    }

    func testIndexCodableRoundTrip() throws {
        var index = EPGIndex()
        index.replace([p("2026-11-02 10:00", "2026-11-02 11:00", "A")], for: channel, at: utc("2026-11-02 09:00"))
        let decoded = try JSONDecoder().decode(EPGIndex.self, from: JSONEncoder().encode(index))
        XCTAssertEqual(decoded, index)
    }

    func testRefreshPolicy() {
        let policy = EPGRefreshPolicy()
        let now = utc("2026-11-02 12:00")
        var index = EPGIndex()
        XCTAssertTrue(policy.needsChannelRefresh(index: index, channel: channel, now: now))
        index.replace([p("2026-11-02 11:00", "2026-11-02 18:00", "Long")], for: channel, at: now)
        XCTAssertFalse(policy.needsChannelRefresh(index: index, channel: channel, now: now.addingTimeInterval(3600)))
        // Couverture qui s'épuise et données anciennes : réactualisation.
        XCTAssertTrue(policy.needsChannelRefresh(index: index, channel: channel, now: utc("2026-11-02 16:30")))
        XCTAssertTrue(policy.needsFullRefresh(lastFull: nil, now: now))
        XCTAssertFalse(policy.needsFullRefresh(lastFull: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(policy.needsFullRefresh(lastFull: now.addingTimeInterval(3600), now: now), "horloge reculée")
    }
}

final class TimeTests: XCTestCase {
    func testServerTimeZoneResolution() {
        XCTAssertEqual(ServerTimeZoneResolver.resolve(identifier: "Europe/Paris", timestampNow: nil, timeNow: nil).identifier, "Europe/Paris")
        let derived = ServerTimeZoneResolver.resolve(identifier: "Not/AZone", timestampNow: Int(utc("2026-11-02 15:30").timeIntervalSince1970),
                                                     timeNow: "2026-11-02 21:00:00")
        XCTAssertEqual(derived.secondsFromGMT(), 5 * 3600 + 1800, "UTC+05:30 déduit")
        XCTAssertEqual(ServerTimeZoneResolver.resolve(identifier: nil, timestampNow: nil, timeNow: nil).secondsFromGMT(), 0)
    }

    func testTimelineGeometry() {
        let now = utc("2026-11-02 15:47")
        let timeline = GuideTimeline.around(now, pastHours: 1, futureHours: 3, pointsPerMinute: 10, timeZone: paris)
        // 14:47 UTC = 15:47 Paris → aligné sur 15:30 Paris = 14:30 UTC.
        XCTAssertEqual(timeline.origin, utc("2026-11-02 14:30"))
        XCTAssertEqual(timeline.x(for: utc("2026-11-02 15:00")), 300)
        XCTAssertEqual(timeline.date(forX: 300), utc("2026-11-02 15:00"))
        XCTAssertEqual(timeline.span(for: DateInterval(start: utc("2026-11-02 14:00"), end: utc("2026-11-02 15:00")))?.x, 0)
        XCTAssertEqual(timeline.span(for: DateInterval(start: utc("2026-11-02 14:00"), end: utc("2026-11-02 15:00")))?.width, 300)
        XCTAssertNil(timeline.span(for: DateInterval(start: utc("2026-11-02 10:00"), end: utc("2026-11-02 11:00"))))
        XCTAssertEqual(timeline.ticks().first?.label, "15:30")
        let visible = timeline.visibleInterval(offsetX: 300, viewportWidth: 600)
        XCTAssertEqual(visible, DateInterval(start: utc("2026-11-02 15:00"), end: utc("2026-11-02 16:00")))
    }

    func testTicksAcrossAutumnDSTChange() {
        // Nuit du 24 au 25 octobre 2026, Paris : 03:00 CEST → 02:00 CET.
        let timeline = GuideTimeline(origin: utc("2026-10-24 23:30"), end: utc("2026-10-25 02:00"),
                                     pointsPerMinute: 1, timeZone: paris)
        let labels = timeline.ticks(stepMinutes: 30).map(\.label)
        XCTAssertEqual(labels, ["01:30", "02:00", "02:30", "02:00", "02:30", "03:00"],
                       "l'heure murale se répète, la grille reste continue")
        let xs = timeline.ticks(stepMinutes: 30).map(\.x)
        XCTAssertEqual(xs, [0, 30, 60, 90, 120, 150])
    }

    func testTicksAcrossSpringDSTChange() {
        // 29 mars 2026, Paris : 02:00 CET → 03:00 CEST.
        let timeline = GuideTimeline(origin: utc("2026-03-29 00:30"), end: utc("2026-03-29 01:30"),
                                     pointsPerMinute: 1, timeZone: paris)
        XCTAssertEqual(timeline.ticks(stepMinutes: 30).map(\.label), ["01:30", "03:00", "03:30"])
    }

    func testAlignDownWithHalfHourOffset() {
        let india = TimeZone(identifier: "Asia/Kolkata")!
        // 10:20 UTC = 15:50 IST → 15:30 IST = 10:00 UTC.
        XCTAssertEqual(GuideTimeline.alignDown(utc("2026-11-02 10:20"), toMinutes: 30, timeZone: india), utc("2026-11-02 10:00"))
    }

    func testDayLabels() {
        let now = utc("2026-11-02 22:30") // 23:30 à Paris
        XCTAssertEqual(DayLabel.label(for: utc("2026-11-02 23:30"), relativeTo: now, timeZone: paris), "Demain")
        XCTAssertEqual(DayLabel.label(for: utc("2026-11-02 12:00"), relativeTo: now, timeZone: paris), "Aujourd'hui")
        XCTAssertEqual(DayLabel.label(for: utc("2026-11-01 12:00"), relativeTo: now, timeZone: paris), "Hier")
    }
}
