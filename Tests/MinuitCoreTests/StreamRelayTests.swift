import XCTest
@testable import MinuitCore

final class StreamRelayTests: XCTestCase {
    func testRoutesAreOpaqueAndForgetOldSessions() throws {
        let routes = StreamRelayRoutes()
        let s1 = routes.newSession()
        let upstream = try XCTUnwrap(URL(string: "http://h.dad:8080/live/jean/motdepasse/12.ts"))
        let path = routes.path(for: upstream, session: s1)
        XCTAssertFalse(path.contains("jean") || path.contains("motdepasse"), "aucun identifiant dans le chemin local")
        XCTAssertTrue(path.hasSuffix(".ts"), "extension gardée")
        XCTAssertEqual(routes.lookup(path), .found(upstream, session: s1))

        let s2 = routes.newSession()
        XCTAssertEqual(routes.lookup(path), .stale, "séance remplacée : flux coupé")
        let late = routes.path(for: upstream, session: s1)
        XCTAssertEqual(routes.lookup(late), .stale, "une ancienne séance n'enregistre plus rien")
        let current = routes.path(for: upstream, session: s2)
        XCTAssertEqual(routes.lookup(current), .found(upstream, session: s2))
        XCTAssertEqual(routes.lookup("/s/x/1"), .unknown)
        XCTAssertEqual(routes.lookup("/favicon.ico"), .unknown)
    }

    func testHLSRewriteSendsEveryAddressThroughRelay() throws {
        let base = try XCTUnwrap(URL(string: "http://cdn.dad:8080/hls/tok/index.m3u8"))
        let text = "#EXTM3U\r\n#EXT-X-TARGETDURATION:4\r\n#EXT-X-KEY:METHOD=AES-128,URI=\"cle.bin\"\r\n#EXTINF:4,\r\nseg0.ts\r\n"
            + "#EXTINF:4,\r\nhttp://autre.dad/seg1.ts\r\n#EXT-X-ENDLIST\r\n"
        var seen: [String] = []
        let out = HLSPlaylistRewriter.rewrite(text, base: base) { url in
            seen.append(url.absoluteString)
            return "http://127.0.0.1:1/s/1/\(seen.count)"
        }
        XCTAssertEqual(seen, ["http://cdn.dad:8080/hls/tok/cle.bin", "http://cdn.dad:8080/hls/tok/seg0.ts", "http://autre.dad/seg1.ts"])
        XCTAssertEqual(out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), [
            "#EXTM3U", "#EXT-X-TARGETDURATION:4", "#EXT-X-KEY:METHOD=AES-128,URI=\"http://127.0.0.1:1/s/1/1\"",
            "#EXTINF:4,", "http://127.0.0.1:1/s/1/2", "#EXTINF:4,", "http://127.0.0.1:1/s/1/3", "#EXT-X-ENDLIST", ""])
        XCTAssertTrue(HLSPlaylistRewriter.isPlaylist(contentType: "application/vnd.apple.mpegURL", url: base))
        XCTAssertTrue(HLSPlaylistRewriter.isPlaylist(contentType: nil, url: base))
        XCTAssertFalse(HLSPlaylistRewriter.isPlaylist(contentType: "video/mp2t", url: try XCTUnwrap(URL(string: "http://h/1.ts"))))
    }

    func testResponseHeadForwardsUsefulHeadersOnly() {
        let head = String(decoding: RelayResponseHead.make(status: 206, headers: [
            "content-type": "video/mp4", "Content-Range": "bytes 0-9/100", "Content-Length": "10", "Set-Cookie": "x=1"]), as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        XCTAssertTrue(head.contains("Content-Type: video/mp4\r\n"))
        XCTAssertTrue(head.contains("Content-Range: bytes 0-9/100\r\n"))
        XCTAssertFalse(head.contains("Cookie"))
        XCTAssertTrue(head.hasSuffix("Connection: close\r\n\r\n"))
    }

    func testUpstreamRequestIsPlainHTTPWithEncodedTarget() throws {
        let url = try XCTUnwrap(URL(string: "http://x.lb1.exemple.dad:8080/live/a%20b/p/1.ts?token=abc&t=1"))
        let text = String(decoding: UpstreamRequest.make(url: url, userAgent: "VLC/3.0.21 LibVLC/3.0.21", range: "bytes=10-"),
                          as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /live/a%20b/p/1.ts?token=abc&t=1 HTTP/1.1\r\nHost: x.lb1.exemple.dad:8080\r\n"))
        XCTAssertTrue(text.contains("User-Agent: VLC/3.0.21 LibVLC/3.0.21\r\n"))
        XCTAssertTrue(text.contains("Range: bytes=10-\r\n"))
        XCTAssertTrue(text.hasSuffix("Connection: close\r\nRange: bytes=10-\r\n\r\n"))
        let bare = String(decoding: UpstreamRequest.make(url: try XCTUnwrap(URL(string: "http://h")), userAgent: "u", range: nil),
                          as: UTF8.self)
        XCTAssertTrue(bare.hasPrefix("GET / HTTP/1.1\r\nHost: h\r\n"))
    }

    func testUpstreamResponseHeadAndRedirect() {
        XCTAssertEqual(UpstreamResponseHead.parse(Data("HTTP/1.1 302 Found\r\nLoc".utf8)), .needMoreData)
        XCTAssertEqual(UpstreamResponseHead.parse(Data("garbage\r\n\r\n".utf8)), .invalid)
        let raw = Data("HTTP/1.1 302 Found\r\nLocation: https://x.dad:8080/live/1.ts?token=t\r\nContent-Length: 0\r\n\r\nTS".utf8)
        guard case .complete(let head) = UpstreamResponseHead.parse(raw) else { return XCTFail("en-tête complet") }
        XCTAssertEqual(head.status, 302)
        XCTAssertTrue(head.isRedirect)
        XCTAssertEqual(head.headers["location"], "https://x.dad:8080/live/1.ts?token=t")
        XCTAssertEqual(raw.count - head.bodyOffset, 2, "début du corps juste après l'en-tête")
        guard case .complete(let busy) = UpstreamResponseHead.parse(Data("HTTP/1.0 458 X\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        else { return XCTFail("en-tête complet") }
        XCTAssertTrue(busy.isConnectionLimit)
        XCTAssertTrue(busy.isChunked)
    }

    func testChunkedDecoding() {
        XCTAssertEqual(ChunkedDecoding.decode(Data("7\r\n#EXTM3U\r\n3;x=1\r\n\nab\r\n0\r\n\r\n".utf8)), Data("#EXTM3U\nab".utf8))
        XCTAssertNil(ChunkedDecoding.decode(Data("7\r\n#EX".utf8)), "corps tronqué")
    }
}
