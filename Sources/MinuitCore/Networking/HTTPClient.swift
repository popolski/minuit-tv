import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var timeout: TimeInterval
    /// Plage d'octets demandée (sondage d'un flux sans le télécharger).
    public var byteRange: ClosedRange<Int>?

    public init(url: URL, headers: [String: String] = [:], timeout: TimeInterval = 15, byteRange: ClosedRange<Int>? = nil) {
        self.url = url
        self.headers = headers
        self.timeout = timeout
        self.byteRange = byteRange
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    public var finalURL: URL?

    public init(statusCode: Int, headers: [String: String] = [:], body: Data, finalURL: URL? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Erreurs de transport, classées pour décider d'une stratégie (réessayer ou non)
/// et pour produire un message utilisateur sans fuite d'URL.
public enum TransportError: Error, Sendable, Equatable {
    case offline
    case timedOut
    case cannotFindHost
    case cannotConnect
    case secureConnectionFailed
    case cancelled
    case tooLarge
    /// Requête HTTP refusée par la politique de sécurité du système (ATS).
    case blockedBySystemPolicy
    case other(code: Int)

    public var isTransient: Bool {
        switch self {
        case .timedOut, .cannotConnect, .other: return true
        case .offline, .cannotFindHost, .secureConnectionFailed, .cancelled, .tooLarge, .blockedBySystemPolicy: return false
        }
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse
    /// Lit au plus `maxBytes` octets puis coupe la connexion. Indispensable pour sonder
    /// un flux continu (direct, archive) qui ignorerait l'en-tête Range.
    func fetchPrefix(_ request: HTTPRequest, maxBytes: Int) async throws(TransportError) -> HTTPResponse
}

extension HTTPClient {
    public func fetchPrefix(_ request: HTTPRequest, maxBytes: Int) async throws(TransportError) -> HTTPResponse {
        var response = try await send(request)
        response.body = response.body.prefix(maxBytes)
        return response
    }
}

/// Client fondé sur URLSession. Aucune URL n'est jamais incluse dans les erreurs produites.
public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let userAgent: String
    private let maxBodyBytes: Int

    /// - Parameter trustsInvalidCertificates: accepte un certificat HTTPS refusé par le
    ///   système (fournisseurs qui redirigent leurs flux vers un HTTPS auto-signé).
    ///   Réglage explicite de l'utilisateur ; sans effet hors plateformes Apple.
    public init(userAgent: String, maxBodyBytes: Int = 256 * 1024 * 1024, trustsInvalidCertificates: Bool = false) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 180
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        #if canImport(Darwin)
        if trustsInvalidCertificates {
            // Serveurs de redirection anciens (TLS 1.0/1.1) : refusés par défaut par tvOS.
            configuration.tlsMinimumSupportedProtocolVersion = .TLSv10
        }
        self.session = URLSession(configuration: configuration,
                                  delegate: SessionDelegate(trustsInvalidCertificates: trustsInvalidCertificates),
                                  delegateQueue: nil)
        #else
        self.session = URLSession(configuration: configuration)
        #endif
        self.userAgent = userAgent
        self.maxBodyBytes = maxBodyBytes
    }

    public func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        if let range = request.byteRange {
            urlRequest.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard data.count <= maxBodyBytes else { throw TransportError.tooLarge }
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                headers[String(describing: key)] = String(describing: value)
            }
            return HTTPResponse(statusCode: http?.statusCode ?? 200, headers: headers, body: data, finalURL: response.url)
        } catch let error as TransportError {
            throw error
        } catch {
            throw Self.classify(error)
        }
    }

    #if canImport(Darwin)
    public func fetchPrefix(_ request: HTTPRequest, maxBytes: Int) async throws(TransportError) -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        if let range = request.byteRange {
            urlRequest.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            var data = Data()
            data.reserveCapacity(maxBytes)
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxBytes { break }
            }
            bytes.task.cancel()
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] { headers[String(describing: key)] = String(describing: value) }
            return HTTPResponse(statusCode: http?.statusCode ?? 200, headers: headers, body: data, finalURL: response.url)
        } catch {
            throw Self.classify(error)
        }
    }
    #endif

    static func classify(_ error: Error) -> TransportError {
        let nsError = error as NSError
        if error is CancellationError { return .cancelled }
        guard nsError.domain == NSURLErrorDomain else { return .other(code: nsError.code) }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
            return .offline
        case NSURLErrorTimedOut: return .timedOut
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .cannotFindHost
        case NSURLErrorCannotConnectToHost: return .cannotConnect
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected:
            return .secureConnectionFailed
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return .blockedBySystemPolicy
        case NSURLErrorCancelled: return .cancelled
        default: return .other(code: nsError.code)
        }
    }
}

#if canImport(Darwin)
/// Délégué de session : journalise les redirections et les échecs de connexion sécurisée
/// (adresse cible masquée par le journal, code TLS précis), et accepte le certificat
/// présenté si le réglage « Accepter les certificats non vérifiés » est actif.
final class SessionDelegate: NSObject, URLSessionTaskDelegate {
    let trustsInvalidCertificates: Bool

    init(trustsInvalidCertificates: Bool) {
        self.trustsInvalidCertificates = trustsInvalidCertificates
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard trustsInvalidCertificates,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let target = request.url {
            DiagnosticsLog.shared.log(.info, "réseau",
                "Redirection \(response.statusCode) vers \(target.scheme ?? "?")://\(target.host ?? "?"):\(target.port.map(String.init) ?? "défaut") — \(target.absoluteString)")
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError?, error.domain == NSURLErrorDomain,
              (-1206 ... -1200).contains(error.code) else { return }
        let stream = error.userInfo["_kCFStreamErrorCodeKey"].map { "\($0)" } ?? "?"
        let failing = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? "?"
        DiagnosticsLog.shared.log(.warning, "réseau",
            "Connexion sécurisée refusée : code \(error.code), TLS \(stream), adresse \(failing)")
    }
}
#endif
