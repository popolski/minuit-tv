import Foundation

/// Normalisation pour la recherche : casse, accents, ponctuation, préfixes fournisseur.
public enum SearchNormalizer {
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR"))
        var output = ""
        output.reserveCapacity(folded.count)
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                output.append(" ")
                lastWasSpace = true
            }
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    /// Retire les préfixes fréquents des listes IPTV : `FR: `, `FR | `, `|FR| `, `[FR] `.
    public static func stripProviderPrefix(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let patterns = ["^\\|?[A-Za-z]{2,4}\\|\\s*", "^[A-Za-z]{2,4}\\s*[:|\\-]\\s+", "^\\[[A-Za-z]{2,4}\\]\\s*"]
        for pattern in patterns {
            if let range = trimmed.range(of: pattern, options: .regularExpression) {
                let rest = trimmed[range.upperBound...]
                if !rest.isEmpty { return String(rest) }
            }
        }
        return trimmed
    }
}

/// Versions d'une même chaîne (« TF1 HD », « TF1 FHD », « TF1 4K ») : même nom une fois la
/// qualité retirée. Les listes n'en montrent qu'une ; les autres restent proposées dans
/// le lecteur et servent de repli quand une version ne fonctionne pas.
public enum ChannelVariants {
    static let qualityTokens: Set<String> = [
        "4k", "uhd", "fhd", "hd", "sd", "hq", "lq", "2160p", "2160", "1080p", "1080i", "1080", "720p", "720",
        "576p", "480p", "hevc", "h265", "h264", "x265", "50fps", "60fps", "25fps", "raw", "backup"
    ]

    /// Clé de regroupement ; nil quand le nom ne contient que des mentions de qualité.
    public static func key(for name: String) -> String? {
        let words = SearchNormalizer.normalize(QualityBadge.expandingSuperscripts(name))
            .split(separator: " ").filter { !qualityTokens.contains(String($0)) }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Version proposée par défaut : FHD, puis HD, sans mention, 4K (débit, compatibilité), SD.
    public static func rank(_ channel: Channel) -> Int {
        switch QualityBadge.parse(channel.name) {
        case .fhd: return 0
        case .hd: return 1
        case nil: return 2
        case .uhd: return 3
        case .sd: return 4
        }
    }
}

/// Préférences utilisateur relatives au catalogue. Volontairement compactes :
/// sur tvOS, le stockage persistant local est limité (voir `PreferencesStore`).
public struct LibraryPreferences: Sendable, Codable, Equatable {
    public var favorites: [ChannelID] = []
    public var hiddenCategories: Set<CategoryID> = []
    /// Ordre personnalisé des catégories ; les catégories absentes suivent dans l'ordre serveur.
    public var categoryOrder: [CategoryID] = []
    public var recents: [ChannelID] = []
    public var lastChannel: ChannelID?
    public var lastCategory: CategoryID?
    public var hideAdultContent: Bool = true
    /// Une seule ligne par chaîne quand le fournisseur en propose plusieurs versions.
    public var groupVariants: Bool = true

    public static let maxRecents = 20

    public init() {}

    enum CodingKeys: String, CodingKey {
        case favorites, hiddenCategories, categoryOrder, recents, lastChannel, lastCategory, hideAdultContent, groupVariants
    }

    /// Décodage tolérant : un champ ajouté par une version ultérieure, ou illisible, ne doit
    /// jamais faire perdre les favoris.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favorites = c.tolerant(.favorites) ?? []
        hiddenCategories = c.tolerant(.hiddenCategories) ?? []
        categoryOrder = c.tolerant(.categoryOrder) ?? []
        recents = c.tolerant(.recents) ?? []
        lastChannel = c.tolerant(.lastChannel)
        lastCategory = c.tolerant(.lastCategory)
        hideAdultContent = c.tolerant(.hideAdultContent) ?? true
        groupVariants = c.tolerant(.groupVariants) ?? true
    }

    public func isFavorite(_ id: ChannelID) -> Bool { favorites.contains(id) }

    public mutating func toggleFavorite(_ id: ChannelID) {
        if let index = favorites.firstIndex(of: id) { favorites.remove(at: index) } else { favorites.append(id) }
    }

    public mutating func moveFavorite(_ id: ChannelID, by delta: Int) {
        guard let index = favorites.firstIndex(of: id) else { return }
        let target = min(max(0, index + delta), favorites.count - 1)
        guard target != index else { return }
        favorites.remove(at: index)
        favorites.insert(id, at: target)
    }

    public mutating func recordWatched(_ id: ChannelID) {
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        lastChannel = id
    }

    public mutating func setHidden(_ hidden: Bool, category: CategoryID) {
        if hidden { hiddenCategories.insert(category) } else { hiddenCategories.remove(category) }
    }

    /// Déplace une catégorie dans l'ordre visible (complète l'ordre si nécessaire).
    public mutating func moveCategory(_ id: CategoryID, by delta: Int, allCategories: [ChannelCategory]) {
        var order = categoryOrder.filter { id in allCategories.contains { $0.id == id } }
        for category in allCategories.sorted(by: { $0.serverOrder < $1.serverOrder }) where !order.contains(category.id) {
            order.append(category.id)
        }
        guard let index = order.firstIndex(of: id) else { return }
        let target = min(max(0, index + delta), order.count - 1)
        order.remove(at: index)
        order.insert(id, at: target)
        categoryOrder = order
    }

    /// Supprime les références à des chaînes ou catégories disparues du serveur.
    public mutating func prune(validChannels: Set<ChannelID>, validCategories: Set<CategoryID>) {
        favorites.removeAll { !validChannels.contains($0) }
        recents.removeAll { !validChannels.contains($0) }
        hiddenCategories = hiddenCategories.filter { validCategories.contains($0) }
        categoryOrder.removeAll { !validCategories.contains($0) }
        if let last = lastChannel, !validChannels.contains(last) { lastChannel = nil }
        if let cat = lastCategory, !validCategories.contains(cat) { lastCategory = nil }
    }
}

/// Liste de chaînes dans laquelle on zappe.
public enum ChannelListContext: Hashable, Sendable, Codable {
    case all
    case category(CategoryID)
    case favorites
    case recents
}

/// Catalogue immuable construit à partir des données serveur et des préférences.
public struct ChannelLibrary: Sendable {
    public let categories: [ChannelCategory]
    public let channels: [Channel]
    private let byID: [ChannelID: Channel]
    private let byCategory: [CategoryID: [ChannelID]]
    private let searchKeys: [ChannelID: String]
    private let variantKeys: [ChannelID: String]
    /// Versions par clé, dans l'ordre de préférence (`ChannelVariants.rank`).
    private let byVariant: [String: [ChannelID]]

    public init(categories: [ChannelCategory], channels: [Channel]) {
        self.categories = categories.sorted { $0.serverOrder < $1.serverOrder }
        self.channels = channels
        var byID: [ChannelID: Channel] = [:]
        var byCategory: [CategoryID: [ChannelID]] = [:]
        var keys: [ChannelID: String] = [:]
        var variantKeys: [ChannelID: String] = [:]
        var byVariant: [String: [Channel]] = [:]
        for channel in channels {
            byID[channel.id] = channel
            for category in channel.categoryIDs { byCategory[category, default: []].append(channel.id) }
            keys[channel.id] = SearchNormalizer.normalize(channel.name)
            if let key = ChannelVariants.key(for: channel.name) {
                variantKeys[channel.id] = key
                byVariant[key, default: []].append(channel)
            }
        }
        self.byID = byID
        self.byCategory = byCategory
        self.searchKeys = keys
        self.variantKeys = variantKeys
        // Tri stable : à rang égal, l'ordre du serveur est conservé.
        self.byVariant = byVariant.mapValues { list in
            list.enumerated()
                .sorted { (ChannelVariants.rank($0.element), $0.offset) < (ChannelVariants.rank($1.element), $1.offset) }
                .map(\.element.id)
        }
    }

    /// Toutes les versions d'une chaîne (elle comprise), dans l'ordre de préférence ;
    /// vide quand elle n'en a qu'une.
    public func variants(of id: ChannelID) -> [Channel] {
        guard let key = variantKeys[id], let ids = byVariant[key], ids.count > 1 else { return [] }
        return ids.compactMap { byID[$0] }
    }

    /// Une ligne par chaîne : à la place de la première version rencontrée, la mieux classée
    /// de celles présentes dans la liste.
    func collapsingVariants(_ list: [Channel]) -> [Channel] {
        var slot: [String: Int] = [:]
        var result: [Channel] = []
        for channel in list {
            guard let key = variantKeys[channel.id] else { result.append(channel); continue }
            if let index = slot[key] {
                if ChannelVariants.rank(channel) < ChannelVariants.rank(result[index]) { result[index] = channel }
            } else {
                slot[key] = result.count
                result.append(channel)
            }
        }
        return result
    }

    public static let empty = ChannelLibrary(categories: [], channels: [])

    public func channel(_ id: ChannelID) -> Channel? { byID[id] }

    /// Catégories visibles, dans l'ordre choisi, sans catégories vides.
    public func visibleCategories(preferences: LibraryPreferences) -> [ChannelCategory] {
        let rank = Dictionary(uniqueKeysWithValues: preferences.categoryOrder.enumerated().map { ($1, $0) })
        return categories
            .filter { !preferences.hiddenCategories.contains($0.id) && !(byCategory[$0.id]?.isEmpty ?? true) }
            .filter { category in
                !preferences.hideAdultContent || !(byCategory[category.id]?.allSatisfy { byID[$0]?.isAdult == true } ?? false)
            }
            .sorted { lhs, rhs in
                switch (rank[lhs.id], rank[rhs.id]) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.serverOrder < rhs.serverOrder
                }
            }
    }

    /// Chaînes d'un contexte, dans l'ordre de zapping.
    public func channels(in context: ChannelListContext, preferences: LibraryPreferences) -> [Channel] {
        let visible: (Channel) -> Bool = { channel in
            if preferences.hideAdultContent && channel.isAdult { return false }
            if channel.categoryIDs.isEmpty { return true }
            return !channel.categoryIDs.allSatisfy { preferences.hiddenCategories.contains($0) }
        }
        switch context {
        case .all:
            let order = visibleCategories(preferences: preferences)
            var seen = Set<ChannelID>()
            var result: [Channel] = []
            for category in order {
                for id in byCategory[category.id] ?? [] where seen.insert(id).inserted {
                    if let channel = byID[id], visible(channel) { result.append(channel) }
                }
            }
            for channel in channels where channel.categoryIDs.isEmpty && seen.insert(channel.id).inserted && visible(channel) {
                result.append(channel)
            }
            return preferences.groupVariants ? collapsingVariants(result) : result
        case .category(let id):
            let list = (byCategory[id] ?? []).compactMap { byID[$0] }.filter { !preferences.hideAdultContent || !$0.isAdult }
            return preferences.groupVariants ? collapsingVariants(list) : list
        case .favorites:
            return preferences.favorites.compactMap { byID[$0] }
        case .recents:
            return preferences.recents.compactMap { byID[$0] }.filter(visible)
        }
    }

    /// Recherche : tous les mots doivent apparaître ; les correspondances en début de nom d'abord.
    public func search(_ query: String, preferences: LibraryPreferences, limit: Int = 200) -> [Channel] {
        let terms = SearchNormalizer.normalize(query).split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        let numberQuery = Int(query.trimmingCharacters(in: .whitespaces))
        var scored: [(score: Int, channel: Channel)] = []
        for channel in channels(in: .all, preferences: preferences) {
            guard let key = searchKeys[channel.id] else { continue }
            var score = 0
            if let numberQuery, channel.number == numberQuery { score += 1000 }
            var matchesAll = true
            for term in terms {
                if key.hasPrefix(term) { score += 100 }
                else if key.contains(" " + term) { score += 50 }
                else if key.contains(term) { score += 10 }
                else { matchesAll = false; break }
            }
            if matchesAll || score >= 1000 { scored.append((score, channel)) }
        }
        return scored
            .sorted { $0.score == $1.score ? $0.channel.name.count < $1.channel.name.count : $0.score > $1.score }
            .prefix(limit)
            .map(\.channel)
    }
}
