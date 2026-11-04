import Foundation
import Network
import Observation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import MinuitCore

/// Serveur web local de l'écran de connexion : le téléphone scanne le QR code, ouvre la
/// page et envoie le serveur, l'identifiant et le mot de passe. Démarré à l'affichage de
/// l'écran de connexion, arrêté à sa fermeture ou après une connexion réussie.
@MainActor
@Observable
final class PhoneSetupServer {
    enum Status: Equatable {
        case starting
        case waiting
        case phoneConnected
        case signingIn
        case unavailable(String)
    }

    private(set) var status: Status = .starting
    private(set) var session = PhoneSetupSession.make()
    /// Adresse à saisir sans QR code (http://192.168.1.42:8080).
    private(set) var address: String?
    private(set) var qrImage: UIImage?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let queue = DispatchQueue(label: "minuit.phone-setup")
    @ObservationIgnored private let log = DiagnosticsLog.shared
    /// Identifiants reçus et validés par le code : l'écran de connexion lance la vérification.
    @ObservationIgnored var onCredentials: (@MainActor (String, String, String) async -> String?)?

    static let port: NWEndpoint.Port = 8080

    /// Démarre (ou garde) le serveur. Le code reste le même tant qu'il est valable : après un
    /// échec de connexion, le téléphone peut corriger sans rescanner.
    func start() {
        guard listener == nil else { return }
        if session.isLocked || session.expiresAt.timeIntervalSinceNow < 60 { session = PhoneSetupSession.make() }
        guard let ip = Self.localIPv4Address() else {
            status = .unavailable("Apple TV sans adresse sur le réseau local.")
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: Self.port)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.start(queue: queue)
            self.listener = listener
            let base = "http://\(ip):\(Self.port.rawValue)"
            address = base
            qrImage = Self.qrCode(for: "\(base)/?code=\(session.code)")
        } catch {
            status = .unavailable("Configuration par téléphone indisponible (port occupé).")
            log.log(.warning, "configuration", "Serveur local : \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        status = .starting
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if status == .starting { status = .waiting }
            log.log(.info, "configuration", "Serveur local prêt sur le port \(Self.port.rawValue)")
        case .failed(let error):
            status = .unavailable("Configuration par téléphone indisponible.")
            log.log(.warning, "configuration", "Serveur local en échec : \(error)")
            listener?.cancel()
            listener = nil
        default:
            break
        }
    }

    // MARK: Requêtes

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private nonisolated func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch LocalHTTPRequest.parse(buffer) {
            case .complete(let request):
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    let response = await self.handle(request)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            case .needMoreData where error == nil && !isComplete:
                self?.receive(connection, buffer: buffer)
            default:
                connection.send(content: LocalHTTPRequest.response(status: 400, contentType: "text/plain; charset=utf-8",
                                                                   body: Data("Requête invalide.".utf8)),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func handle(_ request: LocalHTTPRequest) async -> Data {
        let text = "text/plain; charset=utf-8"
        switch (request.method, request.path) {
        case ("GET", "/"):
            guard session.check(request.query["code"], at: Date()) else {
                return LocalHTTPRequest.response(status: 403, contentType: text,
                                                 body: Data("Code expiré ou incorrect : scannez le QR code affiché sur l’Apple TV.".utf8))
            }
            if status == .waiting { status = .phoneConnected }
            return LocalHTTPRequest.response(status: 200, contentType: "text/html; charset=utf-8",
                                             body: Data(PhoneSetupPage.html(code: session.code).utf8))
        case ("POST", "/config"):
            let form = FormDecoding.decode(String(decoding: request.body, as: UTF8.self))
            guard session.check(form["code"], at: Date()) else {
                return LocalHTTPRequest.response(status: 403, contentType: text, body: Data("Code expiré ou incorrect.".utf8))
            }
            let server = (form["server"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let username = (form["username"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let password = form["password"] ?? ""
            guard !server.isEmpty, !username.isEmpty, !password.isEmpty, let onCredentials else {
                return LocalHTTPRequest.response(status: 400, contentType: text, body: Data("Les trois champs sont obligatoires.".utf8))
            }
            log.log(.info, "configuration", "Identifiants reçus du téléphone")
            status = .signingIn
            let failure = await onCredentials(server, username, password)
            if failure != nil { status = .phoneConnected }
            return LocalHTTPRequest.response(status: failure == nil ? 200 : 400, contentType: text,
                                             body: Data((failure ?? "C’est fait : l’Apple TV est connectée.").utf8))
        default:
            return LocalHTTPRequest.response(status: 404, contentType: text, body: Data("Page introuvable.".utf8))
        }
    }

    // MARK: Outils

    /// Première adresse IPv4 privée d'une interface active (Ethernet ou Wi-Fi).
    static func localIPv4Address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [(name: String, ip: String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates.append((String(cString: entry.pointee.ifa_name), String(cString: host)))
        }
        // en0 (Ethernet ou Wi-Fi selon le modèle) d'abord, puis toute autre interface « en ».
        return candidates.first { $0.name == "en0" }?.ip ?? candidates.first { $0.name.hasPrefix("en") }?.ip
    }

    static func qrCode(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
