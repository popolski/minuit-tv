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

    public static let maxRecents = 20

    public init() {}

    enum CodingKeys: String, CodingKey {
        case favorites, hiddenCategories, categoryOrder, recents, lastChannel, lastCategory, hideAdultContent
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

    public init(categories: [ChannelCategory], channels: [Channel]) {
        self.categories = categories.sorted { $0.serverOrder < $1.serverOrder }
        self.channels = channels
        var byID: [ChannelID: Channel] = [:]
        var byCategory: [CategoryID: [ChannelID]] = [:]
        var keys: [ChannelID: String] = [:]
        for channel in channels {
            byID[channel.id] = channel
            for category in channel.categoryIDs { byCategory[category, default: []].append(channel.id) }
            keys[channel.id] = SearchNormalizer.normalize(channel.name)
        }
        self.byID = byID
        self.byCategory = byCategory
        self.searchKeys = keys
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
            return result
        case .category(let id):
            return (byCategory[id] ?? []).compactMap { byID[$0] }.filter { !preferences.hideAdultContent || !$0.isAdult }
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
