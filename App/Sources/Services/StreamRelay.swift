import Foundation
import Network
import Security
import MinuitCore

/// Relais local des flux, comme le lecteur web qui lit ce fournisseur sans souci.
///
/// Le moteur vidéo lit `http://127.0.0.1:<port>/s/<séance>/<n>.<ext>` et ne parle plus jamais
/// au fournisseur. Le relais va chercher le flux sur une connexion TCP brute (framework
/// Network), **sans URLSession** : le domaine `.dad` des serveurs de redirection est dans la
/// liste HSTS préchargée, et CFNetwork réécrirait chaque `http://….dad:8080` en `https://`
/// (échec TLS, ce port ne parle que HTTP). Comme le relais Python du lecteur web :
/// - agent choisi dans les réglages (VLC par défaut), réponse non compressée ;
/// - redirections suivies une à une ; un saut `https://hôte:port` (port autre que 443/8443)
///   depuis une adresse HTTP est ramené en HTTP ;
/// - 407/456/458 (compte déjà occupé) : un nouvel essai 4 s plus tard ;
/// - listes HLS réécrites : segments, sous-listes et clés repassent par le relais ;
/// - compte à une connexion : une nouvelle séance coupe les flux des précédentes, puis attend
///   0,5 s après la dernière coupure avant d'ouvrir le flux suivant.
/// Tout l'état vit sur `queue` (file série) ; les URL ne sont journalisées que par
/// `DiagnosticsLog` (identifiants masqués).
final class StreamRelay: @unchecked Sendable {
    static let shared = StreamRelay()

    private let queue = DispatchQueue(label: "minuit.relay")
    private let routes = StreamRelayRoutes()
    private let log = DiagnosticsLog.shared
    private var listener: NWListener?
    private var port: UInt16?
    private var portWaiters: [CheckedContinuation<UInt16?, Never>] = []
    private var userAgent = UserAgentPreset.vlc.value
    private var trustsInvalidCertificates = true
    private var streams: [Int: Relayed] = [:]
    private var nextID = 0
    /// Dernière fin de flux (coupure ou fin normale) et sa séance : la séance suivante attend 0,5 s.
    private var lastEnd = Date.distantPast
    private var lastEndSession = 0
    private var loggedSession = 0

    /// Un flux relayé : connexion du moteur et connexion amont en cours (état lu sur `queue` seulement).
    private final class Relayed: @unchecked Sendable {
        let connection: NWConnection
        let session: Int
        let url: URL
        let range: String?
        var upstream: NWConnection?
        var headSent = false
        init(connection: NWConnection, session: Int, url: URL, range: String?) {
            self.connection = connection
            self.session = session
            self.url = url
            self.range = range
        }
    }

    // MARK: API

    func configure(userAgent: String, trustsInvalidCertificates: Bool) {
        queue.async {
            self.userAgent = userAgent
            self.trustsInvalidCertificates = trustsInvalidCertificates
        }
    }

    /// Adresse locale de `url` dans une nouvelle séance (les flux des séances précédentes sont
    /// coupés). nil : relais indisponible, le moteur lira l'adresse directement.
    func localURL(for url: URL) async -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let port = await readyPort() else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                let session = self.routes.newSession()
                self.cut(before: session)
                let path = self.routes.path(for: url, session: session)
                continuation.resume(returning: URL(string: "http://127.0.0.1:\(port)\(path)"))
            }
        }
    }

    /// Coupe tous les flux (lecteur arrêté, échec, attente avant un nouvel essai).
    func stopAll() {
        queue.async { self.cut(before: Int.max) }
    }

    // MARK: Écoute

    private func readyPort() async -> UInt16? {
        await withCheckedContinuation { continuation in
            queue.async {
                if let port = self.port { return continuation.resume(returning: port) }
                self.portWaiters.append(continuation)
                if self.listener == nil { self.startListener() }
            }
        }
    }

    private func startListener() {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        do {
            let listener = try NWListener(using: parameters, on: .any)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            log.log(.warning, "relais", "Relais local indisponible : \(error)")
            resumeWaiters(nil)
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            log.log(.info, "relais", "Relais local prêt (port \(port.map { "\($0)" } ?? "?"))")
            resumeWaiters(port)
        case .failed(let error):
            log.log(.warning, "relais", "Relais local en échec : \(error)")
            listener?.cancel()
            listener = nil
            port = nil
            resumeWaiters(nil)
        case .cancelled:
            listener = nil
            port = nil
        default:
            break
        }
    }

    private func resumeWaiters(_ port: UInt16?) {
        let waiters = portWaiters
        portWaiters = []
        waiters.forEach { $0.resume(returning: port) }
    }

    // MARK: Requêtes du moteur

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch LocalHTTPRequest.parse(buffer) {
            case .complete(let request):
                self.handle(request, on: connection)
            case .needMoreData where error == nil && !isComplete:
                self.receiveHead(connection, buffer: buffer)
            default:
                self.reply(connection, status: 400)
            }
        }
    }

    private func handle(_ request: LocalHTTPRequest, on connection: NWConnection) {
        guard request.method == "GET" else { return reply(connection, status: 400) }
        switch routes.lookup(request.path) {
        case .unknown:
            reply(connection, status: 404)
        case .stale:
            reply(connection, status: 410)
        case .found(let url, let session):
            // Compte à une connexion : 0,5 s après la coupure d'une autre séance.
            let wait = lastEndSession == session ? 0 : lastEnd.addingTimeInterval(0.5).timeIntervalSinceNow
            queue.asyncAfter(deadline: .now() + max(0, wait)) {
                self.open(url, session: session, range: request.headers["range"], on: connection)
            }
        }
    }

    private func open(_ url: URL, session: Int, range: String?, on connection: NWConnection) {
        guard session == routes.currentSession else { return reply(connection, status: 410) }
        if loggedSession != session {
            loggedSession = session
            log.log(.info, "relais", "Séance \(session) : \(url.absoluteString)")
        }
        nextID += 1
        let id = nextID
        streams[id] = Relayed(connection: connection, session: session, url: url, range: range)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.end(id)
            default: break
            }
        }
        watchForClose(connection, id: id)
        fetch(url, id: id, hops: 0, retried: false)
    }

    /// Le moteur ferme la connexion (flux arrêté, changement de chaîne) : on ferme l'amont.
    private func watchForClose(_ connection: NWConnection, id: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                self?.end(id)
            } else {
                self?.watchForClose(connection, id: id)
            }
        }
    }

    /// Coupe les flux des séances antérieures à `session` ; la coupure compte comme fin de flux.
    private func cut(before session: Int) {
        for (id, stream) in streams where stream.session < session { end(id) }
    }

    /// Fin d'un flux : amont fermé, moteur servi (`status` si rien n'a encore été envoyé) puis fermé.
    private func end(_ id: Int, status: Int? = nil) {
        guard let stream = streams.removeValue(forKey: id) else { return }
        lastEnd = Date()
        lastEndSession = stream.session
        stream.upstream?.cancel()
        if let status, !stream.headSent {
            reply(stream.connection, status: status)
        } else {
            stream.connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                   completion: .contentProcessed { _ in stream.connection.cancel() })
        }
    }

    private func reply(_ connection: NWConnection, status: Int) {
        connection.send(content: RelayResponseHead.make(status: status, headers: ["Content-Length": "0"]),
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Amont (TCP brut, sans HSTS)

    private func fetch(_ url: URL, id: Int, hops: Int, retried: Bool) {
        guard let stream = streams[id] else { return }
        guard let host = url.host, !host.isEmpty else { return end(id, status: 502) }
        let tls = url.scheme?.lowercased() == "https"
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        var tlsOptions: NWProtocolTLS.Options?
        if tls {
            let options = NWProtocolTLS.Options()
            if trustsInvalidCertificates {
                sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
            }
            tlsOptions = options
        }
        let port = NWEndpoint.Port(rawValue: UInt16(clamping: url.port ?? (tls ? 443 : 80))) ?? (tls ? .https : .http)
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: port,
                                    using: NWParameters(tls: tlsOptions, tcp: tcp))
        stream.upstream?.cancel()
        stream.upstream = upstream
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self, let stream = self.streams[id], stream.upstream === upstream else { return }
            switch state {
            case .failed(let error), .waiting(let error):
                self.log.log(.warning, "relais", "Amont injoignable : \(error) pour \(url.absoluteString)")
                self.end(id, status: 502)
            default:
                break
            }
        }
        upstream.start(queue: queue)
        upstream.send(content: UpstreamRequest.make(url: url, userAgent: userAgent, range: stream.range),
                      completion: .contentProcessed { _ in })
        readHead(upstream, url: url, id: id, hops: hops, retried: retried, buffer: Data())
    }

    private func readHead(_ upstream: NWConnection, url: URL, id: Int, hops: Int, retried: Bool, buffer: Data) {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, let stream = self.streams[id], stream.upstream === upstream else { return upstream.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch UpstreamResponseHead.parse(buffer) {
            case .needMoreData where error == nil && !isComplete:
                self.readHead(upstream, url: url, id: id, hops: hops, retried: retried, buffer: buffer)
            case .needMoreData, .invalid:
                self.log.log(.warning, "relais", "Amont : réponse illisible\(error.map { " (\($0))" } ?? "") pour \(url.absoluteString)")
                self.end(id, status: 502)
            case .complete(let head):
                self.respond(head, body: Data(buffer.dropFirst(head.bodyOffset)), finished: isComplete || error != nil,
                             upstream: upstream, url: url, id: id, hops: hops, retried: retried)
            }
        }
    }

    private func respond(_ head: UpstreamResponseHead, body: Data, finished: Bool, upstream: NWConnection,
                         url: URL, id: Int, hops: Int, retried: Bool) {
        guard let stream = streams[id] else { return }
        if head.isRedirect, hops < 8, let location = head.headers["location"],
           let target = URL(string: location, relativeTo: url)?.absoluteURL {
            let fixed = RedirectRepair.repaired(target, from: url)
            if fixed != target {
                log.log(.info, "relais", "Redirection HTTPS sur le port \(target.port ?? 0) ramenée en HTTP")
            }
            return fetch(fixed, id: id, hops: hops + 1, retried: retried)
        }
        if head.isConnectionLimit, !retried {
            log.log(.warning, "relais", "Amont : HTTP \(head.status) (connexion du compte occupée), nouvel essai dans 4 s")
            upstream.cancel()
            stream.upstream = nil
            queue.asyncAfter(deadline: .now() + 4) {
                self.fetch(stream.url, id: id, hops: 0, retried: true)
            }
            return
        }
        if head.status >= 400 {
            log.log(.warning, "relais", "Amont : HTTP \(head.status) pour \(url.absoluteString)")
        }
        if head.status == 200, HLSPlaylistRewriter.isPlaylist(contentType: head.headers["content-type"], url: url) {
            return readPlaylist(upstream, head: head, base: url, id: id, buffer: body, finished: finished)
        }
        stream.headSent = true
        stream.connection.send(content: RelayResponseHead.make(status: head.status, headers: head.headers) + body,
                               completion: .contentProcessed { [weak self] error in
            if error != nil || finished { self?.end(id) } else { self?.pump(upstream, id: id) }
        })
    }

    /// Recopie l'amont vers le moteur ; la lecture suivante attend l'envoi (contre-pression).
    private func pump(_ upstream: NWConnection, id: Int) {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, let stream = self.streams[id], stream.upstream === upstream else { return }
            let finished = isComplete || error != nil
            guard let data, !data.isEmpty else { return finished ? self.end(id) : self.pump(upstream, id: id) }
            stream.connection.send(content: data, completion: .contentProcessed { [weak self] sendError in
                if sendError != nil || finished { self?.end(id) } else { self?.pump(upstream, id: id) }
            })
        }
    }

    private func readPlaylist(_ upstream: NWConnection, head: UpstreamResponseHead, base: URL, id: Int,
                              buffer: Data, finished: Bool) {
        guard let stream = streams[id] else { return }
        let length = head.headers["content-length"].flatMap { Int($0) }
        if finished || (length.map { buffer.count >= $0 } ?? false) {
            upstream.cancel()
            var raw = length.map { Data(buffer.prefix($0)) } ?? buffer
            if head.isChunked { raw = ChunkedDecoding.decode(raw) ?? raw }
            let text = HLSPlaylistRewriter.rewrite(String(decoding: raw, as: UTF8.self), base: base) { url in
                "http://127.0.0.1:\(self.port ?? 0)\(self.routes.path(for: url, session: stream.session))"
            }
            let body = Data(text.utf8)
            stream.headSent = true
            stream.connection.send(content: RelayResponseHead.make(status: 200, headers: [
                "Content-Type": "application/vnd.apple.mpegurl", "Content-Length": String(body.count)]) + body,
                                   completion: .idempotent)
            return end(id)
        }
        guard buffer.count <= 8 * 1024 * 1024 else { return end(id, status: 502) }
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, let current = self.streams[id], current.upstream === upstream else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            self.readPlaylist(upstream, head: head, base: base, id: id, buffer: buffer, finished: isComplete || error != nil)
        }
    }
}
