import Foundation

/// Erreurs métier Xtream. Les messages sont rédigés pour l'utilisateur, en français,
/// et ne contiennent jamais d'URL, d'identifiant ni de mot de passe.
public enum XtreamError: Error, Sendable, Equatable {
    case invalidServerAddress
    case missingCredentials
    case transport(TransportError)
    case http(status: Int)
    case authenticationRejected
    case accountExpired(Date?)
    case accountBanned
    case accountDisabled
    case tooManyConnections(max: Int?)
    case unexpectedResponse(context: String)
    case insecureConnectionRefused

    public var isRetryable: Bool {
        switch self {
        case .transport(let transport): return transport.isTransient
        case .http(let status): return status >= 500 || status == 429 || status == 408
        default: return false
        }
    }

    /// Nécessite une nouvelle saisie des identifiants (pas de reconnexion automatique utile).
    public var requiresUserAction: Bool {
        switch self {
        case .authenticationRejected, .accountExpired, .accountBanned, .accountDisabled,
             .missingCredentials, .invalidServerAddress, .insecureConnectionRefused:
            return true
        default:
            return false
        }
    }

    public var userMessage: String {
        switch self {
        case .invalidServerAddress:
            return "L'adresse du serveur n'est pas valide."
        case .missingCredentials:
            return "Identifiant ou mot de passe manquant."
        case .transport(let t):
            switch t {
            case .offline: return "L'Apple TV n'est pas connectée à Internet."
            case .timedOut: return "Le serveur ne répond pas (délai dépassé)."
            case .cannotFindHost: return "Serveur introuvable. Vérifiez l'adresse."
            case .cannotConnect: return "Connexion au serveur impossible."
            case .secureConnectionFailed: return "La connexion sécurisée (HTTPS) a échoué."
            case .cancelled: return "Opération annulée."
            case .tooLarge: return "Réponse du serveur trop volumineuse."
            case .other(let code): return "Erreur réseau (\(code))."
            }
        case .http(let status):
            switch status {
            case 401, 403: return "Accès refusé par le serveur (\(status))."
            case 404: return "Service introuvable sur ce serveur (404)."
            case 429: return "Trop de requêtes : le serveur limite l'accès."
            case 500...599: return "Le serveur rencontre une erreur (\(status))."
            default: return "Réponse inattendue du serveur (\(status))."
            }
        case .authenticationRejected:
            return "Identifiant ou mot de passe refusé."
        case .accountExpired(let date):
            if let date {
                let f = DateFormatter()
                f.locale = Locale(identifier: "fr_FR")
                f.dateStyle = .long
                return "Abonnement expiré depuis le \(f.string(from: date))."
            }
            return "Abonnement expiré."
        case .accountBanned:
            return "Ce compte a été suspendu par le fournisseur."
        case .accountDisabled:
            return "Ce compte est désactivé."
        case .tooManyConnections(let max):
            if let max { return "Nombre maximal de connexions simultanées atteint (\(max))." }
            return "Nombre maximal de connexions simultanées atteint."
        case .unexpectedResponse:
            return "Le serveur a renvoyé une réponse incompréhensible."
        case .insecureConnectionRefused:
            return "Connexion non chiffrée refusée (réglage « Exiger HTTPS »)."
        }
    }
}

extension XtreamError: LocalizedError {
    public var errorDescription: String? { userMessage }
}
