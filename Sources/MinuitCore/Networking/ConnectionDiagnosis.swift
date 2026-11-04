import Foundation

/// Diagnostic « réseau local ou fournisseur ? » : trois vérifications indépendantes
/// (interface réseau, Internet, serveur du fournisseur) et une conclusion en français.
public struct ConnectionReport: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case ok, slow, failed
    }

    public var network: Status
    public var internet: Status
    public var provider: Status
    /// Erreur renvoyée par le fournisseur alors que son serveur répond (compte, connexions).
    public var providerError: XtreamError?

    public init(network: Status, internet: Status, provider: Status, providerError: XtreamError? = nil) {
        self.network = network
        self.internet = internet
        self.provider = provider
        self.providerError = providerError
    }

    /// Statut d'après la durée d'une requête réussie (nil : échec).
    public static func status(latency: TimeInterval?, slowAfter: TimeInterval = 1.5) -> Status {
        guard let latency else { return .failed }
        return latency > slowAfter ? .slow : .ok
    }

    public var conclusion: String {
        if network == .failed { return "L'Apple TV n'est pas connectée au réseau." }
        if internet == .failed && provider == .failed {
            return "Internet ne répond pas : vérifiez la box ou le câble."
        }
        if let providerError { return providerError.userMessage }
        if provider == .failed { return "Internet fonctionne : le problème vient du serveur du fournisseur." }
        if internet == .failed {
            // Le fournisseur répond : seule la référence Internet est injoignable (filtrage, DNS).
            return "Le serveur du fournisseur répond normalement."
        }
        if provider == .slow { return "Le serveur du fournisseur répond lentement." }
        if internet == .slow { return "La connexion Internet est lente." }
        return "Connexion et fournisseur répondent normalement."
    }
}
