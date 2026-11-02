import Foundation
import XCTest
@testable import MinuitCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard let url = Bundle.module.url(forResource: parts[0], withExtension: parts.count > 1 ? parts[1] : nil, subdirectory: "Fixtures") else {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture introuvable : \(name)"])
        }
        return try Data(contentsOf: url)
    }
}

/// Construit une date UTC « 2026-11-02 15:30 ».
func utc(_ text: String) -> Date {
    ServerTimeZoneResolver.parseWallClock(text, in: TimeZone(identifier: "UTC")!)!
}

let paris = TimeZone(identifier: "Europe/Paris")!

let testCredentials = XtreamCredentials(
    server: try! ServerAddress.parse("http://example.tv:8080"),
    username: "alice",
    password: "s3cr3t+pw"
)

/// Client HTTP simulé : réponses scriptées par chemin/action, journal des requêtes.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    typealias Responder = @Sendable (HTTPRequest) -> Result<HTTPResponse, TransportError>
    private let lock = NSLock()
    private var responders: [Responder]
    private(set) var requests: [HTTPRequest] = []

    init(_ responders: [Responder]) {
        self.responders = responders
    }

    convenience init(sequence: [Result<HTTPResponse, TransportError>]) {
        self.init(sequence.map { result in { _ in result } })
    }

    func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse {
        let responder: Responder = lock.withLock {
            requests.append(request)
            return responders.count > 1 ? responders.removeFirst() : responders[0]
        }
        switch responder(request) {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }

    var requestCount: Int { lock.withLock { requests.count } }
}

func ok(_ data: Data) -> Result<HTTPResponse, TransportError> {
    .success(HTTPResponse(statusCode: 200, body: data))
}

func status(_ code: Int) -> Result<HTTPResponse, TransportError> {
    .success(HTTPResponse(statusCode: code, body: Data("error".utf8)))
}
