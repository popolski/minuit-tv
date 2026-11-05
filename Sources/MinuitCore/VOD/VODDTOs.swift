import Foundation

// Réponses brutes des actions VOD de `player_api.php`. Variantes observées selon les
// panneaux : `info` vide renvoyé en `[]`, `backdrop_path` en chaîne ou en tableau,
// épisodes rangés par saison dans un objet (`{"1": [...]}`) ou en tableau de tableaux,
// notes en texte ou en nombre. Un champ mal typé ne fait jamais échouer la liste.

enum VODDecoding {
    static func imageURL(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.hasPrefix("http"),
              let url = URL(string: trimmed) else { return nil }
        return url
    }

    /// Note sur 10 : `rating`, sinon `rating_5based` × 2. Zéro = non noté.
    static func rating(_ rating: String?, fiveBased: String?) -> Double? {
        if let value = rating.flatMap({ Double($0.replacingOccurrences(of: ",", with: ".")) }), value > 0, value <= 10 { return value }
        if let value = fiveBased.flatMap({ Double($0.replacingOccurrences(of: ",", with: ".")) }), value > 0, value <= 5 { return value * 2 }
        return nil
    }

    static func date(_ timestamp: Int?) -> Date? {
        guard let timestamp, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    static func containerExtension(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased(), !raw.isEmpty,
              raw.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return raw
    }

    static func categories(primary: String?, list: [String]) -> [CategoryID] {
        var ids = list.map(CategoryID.init)
        if let primary, !ids.contains(CategoryID(primary)) { ids.insert(CategoryID(primary), at: 0) }
        return ids
    }
}

extension KeyedDecodingContainer {
    /// Liste d'identifiants tolérante (`["1","2"]`, `[1,2]`, absente).
    func lenientStrings(_ key: Key) -> [String] {
        ((try? decodeIfPresent([LenientString].self, forKey: key)) ?? nil)?.compactMap(\.nonEmpty) ?? []
    }

    /// Première image d'un champ chaîne ou tableau de chaînes.
    func firstImage(_ key: Key) -> URL? {
        if let single = lenientString(key) { return VODDecoding.imageURL(single) }
        return lenientStrings(key).lazy.compactMap(VODDecoding.imageURL).first
    }

    /// Objet décodé seulement s'il en est un (`[]`, `false` ou `null` : nil).
    func objectIfPresent<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

struct VODStreamDTO: Decodable {
    let movie: Movie

    enum CodingKeys: String, CodingKey {
        case name, title, rating, added, year
        case streamID = "stream_id"
        case streamType = "stream_type"
        case icon = "stream_icon"
        case cover
        case fiveBased = "rating_5based"
        case categoryID = "category_id"
        case categoryIDs = "category_ids"
        case container = "container_extension"
        case isAdult = "is_adult"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientInt(.streamID) else {
            throw DecodingError.dataCorruptedError(forKey: .streamID, in: c, debugDescription: "stream_id manquant")
        }
        if let type = c.lenientString(.streamType)?.lowercased(), type != "movie" {
            throw DecodingError.dataCorruptedError(forKey: .streamType, in: c, debugDescription: "pas un film")
        }
        let name = (c.lenientString(.name) ?? c.lenientString(.title))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Film \(id)"
        movie = Movie(id: id, name: name,
                      posterURL: VODDecoding.imageURL(c.lenientString(.icon)) ?? VODDecoding.imageURL(c.lenientString(.cover)),
                      rating: VODDecoding.rating(c.lenientString(.rating), fiveBased: c.lenientString(.fiveBased)),
                      addedAt: VODDecoding.date(c.lenientInt(.added)),
                      categoryIDs: VODDecoding.categories(primary: c.lenientString(.categoryID), list: c.lenientStrings(.categoryIDs)),
                      containerExtension: VODDecoding.containerExtension(c.lenientString(.container)) ?? "mp4",
                      year: c.lenientInt(.year).flatMap { (1900...2100).contains($0) ? $0 : nil } ?? VODText.year(in: name),
                      isAdult: c.lenientBool(.isAdult))
    }
}

struct SeriesDTO: Decodable {
    let series: Series

    enum CodingKeys: String, CodingKey {
        case name, title, cover, plot, cast, genre, rating, year
        case seriesID = "series_id"
        case backdrop = "backdrop_path"
        case fiveBased = "rating_5based"
        case releaseDate, release_date
        case lastModified = "last_modified"
        case categoryID = "category_id"
        case categoryIDs = "category_ids"
        case isAdult = "is_adult"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientInt(.seriesID) else {
            throw DecodingError.dataCorruptedError(forKey: .seriesID, in: c, debugDescription: "series_id manquant")
        }
        let name = (c.lenientString(.name) ?? c.lenientString(.title))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Série \(id)"
        let release = c.lenientString(.releaseDate) ?? c.lenientString(.release_date)
        series = Series(id: id, name: name,
                        posterURL: VODDecoding.imageURL(c.lenientString(.cover)),
                        backdropURL: c.firstImage(.backdrop),
                        rating: VODDecoding.rating(c.lenientString(.rating), fiveBased: c.lenientString(.fiveBased)),
                        addedAt: VODDecoding.date(c.lenientInt(.lastModified)),
                        categoryIDs: VODDecoding.categories(primary: c.lenientString(.categoryID), list: c.lenientStrings(.categoryIDs)),
                        plot: c.lenientString(.plot), genre: c.lenientString(.genre), cast: c.lenientString(.cast),
                        year: c.lenientInt(.year).flatMap { (1900...2100).contains($0) ? $0 : nil } ?? VODText.year(in: release) ?? VODText.year(in: name),
                        isAdult: c.lenientBool(.isAdult))
    }
}

/// Bloc `info` commun aux fiches film, série et épisode.
struct VODInfoDTO: Decodable {
    let plot: String?
    let genre: String?
    let cast: String?
    let director: String?
    let releaseDate: String?
    let durationSeconds: Int?
    let poster: URL?
    let backdrop: URL?
    let rating: Double?
    let tmdbID: Int?

    enum CodingKeys: String, CodingKey {
        case plot, description, genre, cast, actors, director, rating, duration, cover
        case movieImage = "movie_image"
        case coverBig = "cover_big"
        case backdrop = "backdrop_path"
        case releaseDate = "releasedate"
        case releaseDateAlt = "release_date"
        case releaseDateCamel = "releaseDate"
        case durationSecs = "duration_secs"
        case fiveBased = "rating_5based"
        case tmdbID = "tmdb_id"
        case tmdb
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plot = c.lenientString(.plot) ?? c.lenientString(.description)
        genre = c.lenientString(.genre)
        cast = c.lenientString(.cast) ?? c.lenientString(.actors)
        director = c.lenientString(.director)
        releaseDate = c.lenientString(.releaseDate) ?? c.lenientString(.releaseDateAlt) ?? c.lenientString(.releaseDateCamel)
        durationSeconds = VODText.durationSeconds(seconds: c.lenientInt(.durationSecs), text: c.lenientString(.duration))
        poster = VODDecoding.imageURL(c.lenientString(.movieImage)) ?? VODDecoding.imageURL(c.lenientString(.coverBig))
            ?? VODDecoding.imageURL(c.lenientString(.cover))
        backdrop = c.firstImage(.backdrop)
        rating = VODDecoding.rating(c.lenientString(.rating), fiveBased: c.lenientString(.fiveBased))
        tmdbID = c.lenientInt(.tmdbID) ?? c.lenientInt(.tmdb)
    }
}

/// Réponse de `get_vod_info`.
struct VODInfoResponseDTO: Decodable {
    let details: MovieDetails

    enum CodingKeys: String, CodingKey {
        case info
        case movieData = "movie_data"
    }

    struct MovieDataDTO: Decodable {
        let container: String?
        enum CodingKeys: String, CodingKey { case container = "container_extension" }
        init(from decoder: Decoder) throws {
            container = try decoder.container(keyedBy: CodingKeys.self).lenientString(.container)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let info = c.objectIfPresent(VODInfoDTO.self, .info)
        let data = c.objectIfPresent(MovieDataDTO.self, .movieData)
        details = MovieDetails(plot: info?.plot, genre: info?.genre, cast: info?.cast, director: info?.director,
                               releaseDate: info?.releaseDate, durationSeconds: info?.durationSeconds,
                               posterURL: info?.poster, backdropURL: info?.backdrop, rating: info?.rating, tmdbID: info?.tmdbID,
                               containerExtension: VODDecoding.containerExtension(data?.container))
    }
}

struct EpisodeDTO: Decodable {
    let id: String
    let season: Int?
    let number: Int?
    let title: String?
    let container: String?
    let info: VODInfoDTO?

    enum CodingKeys: String, CodingKey {
        case id, season, title, info
        case number = "episode_num"
        case container = "container_extension"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(.id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "id d'épisode manquant")
        }
        self.id = id
        season = c.lenientInt(.season)
        number = c.lenientInt(.number)
        title = c.lenientString(.title)
        container = c.lenientString(.container)
        info = c.objectIfPresent(VODInfoDTO.self, .info)
    }
}

/// Réponse de `get_series_info`.
struct SeriesInfoResponseDTO: Decodable {
    let details: SeriesDetails

    enum CodingKeys: String, CodingKey { case seasons, info, episodes }

    struct SeasonDTO: Decodable {
        let number: Int?
        let name: String?
        let cover: URL?
        enum CodingKeys: String, CodingKey {
            case name, cover
            case number = "season_number"
            case coverBig = "cover_big"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            number = c.lenientInt(.number)
            name = c.lenientString(.name)
            cover = VODDecoding.imageURL(c.lenientString(.coverBig)) ?? VODDecoding.imageURL(c.lenientString(.cover))
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let info = c.objectIfPresent(VODInfoDTO.self, .info)

        // Épisodes : `{"1": [...], "2": [...]}` (le plus courant) ou `[[...], [...]]`.
        var raw: [(season: Int, dto: EpisodeDTO)] = []
        if let bySeason = c.objectIfPresent([String: LossyArray<EpisodeDTO>].self, .episodes) {
            for (key, list) in bySeason {
                for dto in list.elements { raw.append((dto.season ?? Int(key) ?? 1, dto)) }
            }
        } else if let nested = c.objectIfPresent([LossyArray<EpisodeDTO>].self, .episodes),
                  nested.contains(where: { !$0.elements.isEmpty }) {
            for (index, list) in nested.enumerated() {
                for dto in list.elements { raw.append((dto.season ?? index + 1, dto)) }
            }
        } else if let flat = c.objectIfPresent(LossyArray<EpisodeDTO>.self, .episodes) {
            // Tableau simple d'épisodes (`LossyArray` imbriqué y voit des listes vides).
            for dto in flat.elements { raw.append((dto.season ?? 1, dto)) }
        }
        var seen = Set<String>()
        var episodes: [Episode] = []
        for (season, dto) in raw where seen.insert(dto.id).inserted {
            let number = dto.number ?? 0
            episodes.append(Episode(id: dto.id, season: season, number: number,
                                    title: VODText.episodeTitle(dto.title, number: number),
                                    containerExtension: VODDecoding.containerExtension(dto.container) ?? "mp4",
                                    plot: dto.info?.plot, durationSeconds: dto.info?.durationSeconds, imageURL: dto.info?.poster))
        }
        episodes.sort { ($0.season, $0.number, $0.id) < ($1.season, $1.number, $1.id) }

        // Saisons annoncées (noms, affiches), complétées par celles déduites des épisodes.
        let announced = (c.objectIfPresent(LossyArray<SeasonDTO>.self, .seasons)?.elements ?? []).compactMap { dto -> Season? in
            guard let number = dto.number else { return nil }
            return Season(number: number, name: dto.name ?? "Saison \(number)", coverURL: dto.cover)
        }
        var seasons: [Int: Season] = [:]
        for season in announced { seasons[season.number] = season }
        for number in Set(episodes.map(\.season)) where seasons[number] == nil {
            seasons[number] = Season(number: number, name: "Saison \(number)")
        }
        // Une saison sans épisode (annonce vide, « Spéciaux » non fournis) n'est pas montrée.
        let withEpisodes = Set(episodes.map(\.season))
        details = SeriesDetails(plot: info?.plot, genre: info?.genre, cast: info?.cast, director: info?.director,
                                releaseDate: info?.releaseDate, backdropURL: info?.backdrop, rating: info?.rating,
                                seasons: seasons.values.filter { withEpisodes.contains($0.number) }.sorted { $0.number < $1.number },
                                episodes: episodes)
    }
}
