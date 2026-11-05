import Foundation

/// Catalogue de films ou de séries, indexé pour les écrans (catégories, récents, recherche).
public struct VODCatalog<Item: VODItem>: Sendable {
    public let categories: [ChannelCategory]
    public let items: [Item]
    private let indexByID: [Int: Int]
    private let indicesByCategory: [CategoryID: [Int]]
    private let normalizedNames: [String]
    private let adultCategories: Set<CategoryID>

    public init(categories: [ChannelCategory], items: [Item]) {
        self.categories = categories
        self.items = items
        var byID: [Int: Int] = [:]
        var byCategory: [CategoryID: [Int]] = [:]
        for (index, item) in items.enumerated() {
            byID[item.id] = index
            for category in item.categoryIDs { byCategory[category, default: []].append(index) }
        }
        indexByID = byID
        indicesByCategory = byCategory
        normalizedNames = items.map { SearchNormalizer.normalize(VODText.title($0.name)) }
        adultCategories = Set(categories.filter { VODText.isAdultCategory($0.name) }.map(\.id))
    }

    public static var empty: VODCatalog { VODCatalog(categories: [], items: []) }

    public var isEmpty: Bool { items.isEmpty }

    public func item(_ id: Int) -> Item? { indexByID[id].map { items[$0] } }

    /// Masqué par le filtre adulte : fiche marquée, ou rangée uniquement dans des catégories adultes.
    public func isHidden(_ item: Item, hideAdult: Bool) -> Bool {
        guard hideAdult else { return false }
        if item.isAdult { return true }
        return !item.categoryIDs.isEmpty && item.categoryIDs.allSatisfy { adultCategories.contains($0) }
    }

    /// Catégories non vides, dans l'ordre du serveur.
    public func visibleCategories(hideAdult: Bool) -> [ChannelCategory] {
        categories.filter { category in
            guard !(hideAdult && adultCategories.contains(category.id)) else { return false }
            return !(indicesByCategory[category.id]?.isEmpty ?? true)
        }
    }

    public func items(in category: CategoryID, hideAdult: Bool) -> [Item] {
        (indicesByCategory[category] ?? []).map { items[$0] }.filter { !isHidden($0, hideAdult: hideAdult) }
    }

    public func all(hideAdult: Bool) -> [Item] {
        items.filter { !isHidden($0, hideAdult: hideAdult) }
    }

    /// Derniers ajouts du fournisseur (date d'ajout ou de mise à jour).
    public func recentlyAdded(limit: Int = 60, hideAdult: Bool) -> [Item] {
        let dated = items.filter { $0.addedAt != nil && !isHidden($0, hideAdult: hideAdult) }
        return Array(dated.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }.prefix(limit))
    }

    /// Titres contenant tous les mots cherchés (accents et casse ignorés) ;
    /// ceux qui commencent par la recherche d'abord.
    public func search(_ query: String, limit: Int = 60, hideAdult: Bool) -> [Item] {
        let normalizedQuery = SearchNormalizer.normalize(query)
        let terms = normalizedQuery.split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        var scored: [(score: Int, length: Int, index: Int)] = []
        for (index, name) in normalizedNames.enumerated() where terms.allSatisfy({ name.contains($0) }) {
            guard !isHidden(items[index], hideAdult: hideAdult) else { continue }
            let score = name.hasPrefix(normalizedQuery) ? 0 : (name.split(separator: " ").contains { $0.hasPrefix(terms[0]) } ? 1 : 2)
            scored.append((score, name.count, index))
        }
        scored.sort { ($0.score, $0.length, $0.index) < ($1.score, $1.length, $1.index) }
        return scored.prefix(limit).map { items[$0.index] }
    }
}

/// Progression de lecture des films et épisodes : reprise, « Continuer à regarder », vus.
/// Conservée localement (préférences) : petite, précieuse, propre à l'appareil.
public struct WatchProgress: Sendable, Codable, Equatable {
    public enum Kind: String, Codable, Sendable { case movie, episode }

    public struct Entry: Sendable, Codable, Equatable, Identifiable {
        public var kind: Kind
        /// Film, ou série pour un épisode.
        public var itemID: Int
        public var episodeID: String?
        public var position: Double
        public var duration: Double
        public var updatedAt: Date
        public var finished: Bool
        /// Épisode suivant mis en attente à la fin du précédent (« À suivre »).
        public var queued: Bool
        // De quoi afficher et relancer sans recharger le catalogue :
        public var title: String
        public var subtitle: String?
        public var imageURL: URL?
        public var containerExtension: String

        public init(kind: Kind, itemID: Int, episodeID: String? = nil, position: Double, duration: Double,
                    updatedAt: Date, finished: Bool = false, queued: Bool = false, title: String,
                    subtitle: String? = nil, imageURL: URL? = nil, containerExtension: String) {
            self.kind = kind
            self.itemID = itemID
            self.episodeID = episodeID
            self.position = position
            self.duration = duration
            self.updatedAt = updatedAt
            self.finished = finished
            self.queued = queued
            self.title = title
            self.subtitle = subtitle
            self.imageURL = imageURL
            self.containerExtension = containerExtension
        }

        public var id: String { key }

        public var key: String {
            switch kind {
            case .movie: return WatchProgress.key(movie: itemID)
            case .episode: return WatchProgress.key(episode: episodeID ?? "")
            }
        }

        public var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    }

    public private(set) var entries: [String: Entry] = [:]

    /// En dessous : simple essai, pas de reprise proposée.
    public static let minimumResume: Double = 30
    public static let maxEntries = 150

    public init() {}

    public static func key(movie id: Int) -> String { "m\(id)" }
    public static func key(episode id: String) -> String { "e\(id)" }

    /// Vu : plus de 92 % lus, ou moins de 3 minutes restantes (générique) sur un long programme.
    public static func isFinished(position: Double, duration: Double) -> Bool {
        guard duration > 0 else { return false }
        return position / duration >= 0.92 || (duration >= 900 && duration - position <= 180)
    }

    public func entry(_ key: String) -> Entry? { entries[key] }

    public func isFinished(_ key: String) -> Bool { entries[key]?.finished ?? false }

    /// Position de reprise (quelques secondes avant l'arrêt), ou nil s'il faut partir du début.
    public func resumePosition(_ key: String) -> Double? {
        guard let entry = entries[key], !entry.finished, entry.position >= Self.minimumResume else { return nil }
        return max(0, entry.position - 5)
    }

    /// Enregistre une position ; « vu » est déduit de la position.
    public mutating func record(_ entry: Entry) {
        var entry = entry
        entry.finished = Self.isFinished(position: entry.position, duration: entry.duration)
        if entry.finished { entry.position = 0 }
        if entry.position >= Self.minimumResume || entry.finished {
            entry.queued = false
        } else if entries[entry.key]?.queued == true {
            // Quelques secondes d'un épisode « À suivre » : il reste à suivre.
            entry.queued = true
        }
        // Un simple essai de quelques secondes n'efface pas une reprise ni un « vu » existants.
        if !entry.finished, !entry.queued, entry.position < Self.minimumResume, let existing = entries[entry.key],
           existing.finished || existing.position >= Self.minimumResume {
            return
        }
        entries[entry.key] = entry
        prune()
    }

    /// Marque vu ou non vu (fiche), sans position.
    public mutating func setFinished(_ entry: Entry, _ finished: Bool) {
        var entry = entry
        entry.finished = finished
        entry.queued = false
        entry.position = 0
        entries[entry.key] = entry
        prune()
    }

    /// Met en attente l'épisode suivant, sauf s'il a déjà une progression.
    public mutating func queue(_ entry: Entry) {
        guard entries[entry.key] == nil || entries[entry.key]?.finished == true else { return }
        var entry = entry
        entry.queued = true
        entry.finished = false
        entry.position = 0
        // Toujours plus récent que l'épisode qui vient de finir : c'est lui que l'accueil propose.
        if entry.kind == .episode, let latest = latestEpisode(series: entry.itemID), latest.updatedAt >= entry.updatedAt {
            entry.updatedAt = latest.updatedAt.addingTimeInterval(1)
        }
        entries[entry.key] = entry
        prune()
    }

    public mutating func remove(_ key: String) { entries[key] = nil }

    /// Films entamés et séries en cours (une seule entrée par série : la plus récente), du plus récent au plus ancien.
    public func continueWatching(limit: Int = 20) -> [Entry] {
        var latestBySeries: [Int: Entry] = [:]
        var movies: [Entry] = []
        for entry in entries.values {
            switch entry.kind {
            case .movie:
                if !entry.finished, entry.position >= Self.minimumResume { movies.append(entry) }
            case .episode:
                if let current = latestBySeries[entry.itemID], current.updatedAt >= entry.updatedAt { continue }
                latestBySeries[entry.itemID] = entry
            }
        }
        let series = latestBySeries.values.filter { !$0.finished && ($0.position >= Self.minimumResume || $0.queued) }
        return Array((movies + series).sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    /// Dernier épisode touché d'une série (reprise depuis la fiche).
    public func latestEpisode(series id: Int) -> Entry? {
        entries.values.filter { $0.kind == .episode && $0.itemID == id }.max { $0.updatedAt < $1.updatedAt }
    }

    private mutating func prune() {
        guard entries.count > Self.maxEntries else { return }
        let keep = entries.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maxEntries)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0) })
    }
}

/// Piste audio ou de sous-titres, indépendante du moteur.
public struct MediaTrack: Sendable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var isSelected: Bool
    public var language: String?
    public var isDefault: Bool
    public var isForced: Bool

    public init(id: Int, title: String, isSelected: Bool, language: String? = nil, isDefault: Bool = false, isForced: Bool = false) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
        self.language = language
        self.isDefault = isDefault
        self.isForced = isForced
    }

    public var normalizedLanguage: String? { LanguageCode.normalize(language) }
}

/// Codes de langue des pistes (ISO 639-2 des fichiers, ISO 639-1, noms complets).
public enum LanguageCode {
    private static let iso639_2: [String: String] = [
        "fre": "fr", "fra": "fr", "eng": "en", "spa": "es", "ger": "de", "deu": "de", "ita": "it", "por": "pt",
        "jpn": "ja", "kor": "ko", "rus": "ru", "ara": "ar", "chi": "zh", "zho": "zh", "dut": "nl", "nld": "nl",
        "pol": "pl", "tur": "tr", "und": "und", "mul": "mul",
    ]

    /// Code ISO 639-1 en minuscules, ou nil si inconnu.
    public static func normalize(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "_", with: "-")
        let base = String(text.split(separator: "-").first ?? Substring(text))
        if let mapped = iso639_2[base] { return mapped == "und" || mapped == "mul" ? nil : mapped }
        if base.count == 2 { return base }
        switch SearchNormalizer.normalize(base) {
        case "french", "francais", "vf", "vff", "vfq": return "fr"
        case "english", "anglais": return "en"
        default: return nil
        }
    }
}

/// Choix initial des pistes : audio en français si possible ; sous-titres français
/// seulement quand l'audio retenu est dans une autre langue (forcés sinon, s'il y en a).
public enum TrackChoice {
    public static func audio(_ tracks: [MediaTrack], preferred: String = "fr") -> MediaTrack? {
        guard !tracks.isEmpty else { return nil }
        let matches = tracks.filter { $0.normalizedLanguage == preferred }
        return matches.first(where: \.isDefault) ?? matches.first ?? tracks.first(where: \.isDefault) ?? tracks.first
    }

    public static func subtitle(_ tracks: [MediaTrack], audio: MediaTrack?, preferred: String = "fr") -> MediaTrack? {
        let inLanguage = tracks.filter { $0.normalizedLanguage == preferred }
        let forced = inLanguage.first(where: \.isForced)
        guard let audioLanguage = audio?.normalizedLanguage, audioLanguage != preferred else { return forced }
        return inLanguage.first { !$0.isForced } ?? forced
    }
}
