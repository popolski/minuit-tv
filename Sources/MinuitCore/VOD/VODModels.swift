import Foundation

// Films et séries du fournisseur (vidéo à la demande Xtream). Mêmes principes que le
// direct : le reste de l'application ne voit que ces modèles, jamais les réponses brutes.

/// Élément rangé dans des catégories (chaîne, film, série).
public protocol Categorized {
    var categoryIDs: [CategoryID] { get set }
}

extension Channel: Categorized {}

/// Ce que partagent films et séries pour les catalogues (rangement, recherche, filtres).
public protocol VODItem: Identifiable, Hashable, Sendable, Categorized where ID == Int {
    var name: String { get }
    var addedAt: Date? { get }
    var posterURL: URL? { get }
    var isAdult: Bool { get }
}

public struct Movie: VODItem, Codable {
    public let id: Int
    public var name: String
    public var posterURL: URL?
    /// Note sur 10.
    public var rating: Double?
    public var addedAt: Date?
    public var categoryIDs: [CategoryID]
    /// Extension du fichier (`mkv`, `mp4`…) : elle fait partie de l'URL de lecture.
    public var containerExtension: String
    public var year: Int?
    public var isAdult: Bool

    public init(id: Int, name: String, posterURL: URL? = nil, rating: Double? = nil, addedAt: Date? = nil,
                categoryIDs: [CategoryID] = [], containerExtension: String = "mp4", year: Int? = nil, isAdult: Bool = false) {
        self.id = id
        self.name = name
        self.posterURL = posterURL
        self.rating = rating
        self.addedAt = addedAt
        self.categoryIDs = categoryIDs
        self.containerExtension = containerExtension
        self.year = year
        self.isAdult = isAdult
    }
}

/// Fiche détaillée d'un film (`get_vod_info`), chargée à l'ouverture de la fiche.
public struct MovieDetails: Sendable, Hashable {
    public var plot: String?
    public var genre: String?
    public var cast: String?
    public var director: String?
    public var releaseDate: String?
    public var durationSeconds: Int?
    public var posterURL: URL?
    public var backdropURL: URL?
    public var rating: Double?
    public var tmdbID: Int?
    /// Extension confirmée par la fiche (prioritaire sur celle de la liste).
    public var containerExtension: String?

    public init(plot: String? = nil, genre: String? = nil, cast: String? = nil, director: String? = nil,
                releaseDate: String? = nil, durationSeconds: Int? = nil, posterURL: URL? = nil, backdropURL: URL? = nil,
                rating: Double? = nil, tmdbID: Int? = nil, containerExtension: String? = nil) {
        self.plot = plot
        self.genre = genre
        self.cast = cast
        self.director = director
        self.releaseDate = releaseDate
        self.durationSeconds = durationSeconds
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.rating = rating
        self.tmdbID = tmdbID
        self.containerExtension = containerExtension
    }

    public var year: Int? { VODText.year(in: releaseDate) }
}

public struct Series: VODItem, Codable {
    public let id: Int
    public var name: String
    public var posterURL: URL?
    public var backdropURL: URL?
    public var rating: Double?
    public var addedAt: Date?
    public var categoryIDs: [CategoryID]
    public var plot: String?
    public var genre: String?
    public var cast: String?
    public var year: Int?
    public var isAdult: Bool

    public init(id: Int, name: String, posterURL: URL? = nil, backdropURL: URL? = nil, rating: Double? = nil,
                addedAt: Date? = nil, categoryIDs: [CategoryID] = [], plot: String? = nil, genre: String? = nil,
                cast: String? = nil, year: Int? = nil, isAdult: Bool = false) {
        self.id = id
        self.name = name
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.rating = rating
        self.addedAt = addedAt
        self.categoryIDs = categoryIDs
        self.plot = plot
        self.genre = genre
        self.cast = cast
        self.year = year
        self.isAdult = isAdult
    }
}

public struct Episode: Identifiable, Hashable, Sendable, Codable {
    /// Identifiant de lecture (`id` de l'épisode, distinct de celui de la série).
    public let id: String
    public var season: Int
    public var number: Int
    public var title: String
    public var containerExtension: String
    public var plot: String?
    public var durationSeconds: Int?
    public var imageURL: URL?

    public init(id: String, season: Int, number: Int, title: String, containerExtension: String = "mp4",
                plot: String? = nil, durationSeconds: Int? = nil, imageURL: URL? = nil) {
        self.id = id
        self.season = season
        self.number = number
        self.title = title
        self.containerExtension = containerExtension
        self.plot = plot
        self.durationSeconds = durationSeconds
        self.imageURL = imageURL
    }

    /// « S1 E3 ».
    public var code: String { "S\(season) E\(number)" }
}

public struct Season: Hashable, Sendable, Codable, Identifiable {
    public var number: Int
    public var name: String
    public var coverURL: URL?
    public var id: Int { number }

    public init(number: Int, name: String, coverURL: URL? = nil) {
        self.number = number
        self.name = name
        self.coverURL = coverURL
    }
}

/// Fiche d'une série (`get_series_info`) : saisons et épisodes triés.
public struct SeriesDetails: Sendable, Hashable {
    public var plot: String?
    public var genre: String?
    public var cast: String?
    public var director: String?
    public var releaseDate: String?
    public var backdropURL: URL?
    public var rating: Double?
    public var seasons: [Season]
    public var episodes: [Episode]

    public init(plot: String? = nil, genre: String? = nil, cast: String? = nil, director: String? = nil,
                releaseDate: String? = nil, backdropURL: URL? = nil, rating: Double? = nil,
                seasons: [Season] = [], episodes: [Episode] = []) {
        self.plot = plot
        self.genre = genre
        self.cast = cast
        self.director = director
        self.releaseDate = releaseDate
        self.backdropURL = backdropURL
        self.rating = rating
        self.seasons = seasons
        self.episodes = episodes
    }

    public func episodes(inSeason season: Int) -> [Episode] {
        episodes.filter { $0.season == season }
    }

    /// Épisode suivant dans l'ordre de diffusion (saison suivante comprise).
    public func episode(after episode: Episode) -> Episode? {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }), index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }
}

/// Nettoyage des titres fournis par les panneaux.
public enum VODText {
    /// Titre affiché : préfixe pays et mentions de qualité retirés, année finale retirée.
    /// « FR - Le Phare (2019) 4K » → « Le Phare ».
    public static func title(_ raw: String) -> String {
        var text = ChannelNameCleaner.clean(raw)
        if let range = text.range(of: "\\s*[\\(\\[]\\s*(19|20)\\d{2}\\s*[\\)\\]]\\s*$", options: .regularExpression) {
            let rest = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { text = rest }
        }
        return text
    }

    /// Année trouvée dans un texte (« 2019-05-02 », « Le Phare (2019) »).
    public static func year(in text: String?) -> Int? {
        guard let text, let range = text.range(of: "(19|20)\\d{2}", options: .regularExpression) else { return nil }
        return Int(text[range])
    }

    /// Titre d'épisode lisible : « Série - S01E03 - Le retour » → « Le retour ».
    /// Sans titre propre : « Épisode 3 ».
    public static func episodeTitle(_ raw: String?, number: Int) -> String {
        let fallback = "Épisode \(number)"
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return fallback }
        if let range = text.range(of: "[Ss]\\d{1,3}\\s*[EeXx]\\d{1,4}", options: .regularExpression) {
            text = String(text[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " -–:|."))
        }
        return text.isEmpty ? fallback : text
    }

    /// Durée Xtream : secondes, ou texte « 01:45:00 » / « 105 min ».
    public static func durationSeconds(seconds: Int?, text: String?) -> Int? {
        if let seconds, seconds > 0 { return seconds }
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if let range = text.range(of: "\\d+", options: .regularExpression), let minutes = Int(text[range]), minutes > 0 {
            return minutes * 60
        }
        return nil
    }

    /// « 1 h 45 », « 52 min ».
    public static func durationLabel(_ seconds: Int?) -> String? {
        guard let seconds, seconds >= 60 else { return nil }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : String(format: "%d h %02d", minutes / 60, minutes % 60)
    }

    /// Catégorie réservée aux adultes, reconnue à son nom (les fiches VOD n'ont pas d'indicateur).
    public static func isAdultCategory(_ name: String) -> Bool {
        let key = SearchNormalizer.normalize(name)
        if ["adult", "xxx", "porn", "erotic"].contains(where: { key.contains($0) }) { return true }
        return key.split(separator: " ").contains { $0 == "18" }
    }
}
