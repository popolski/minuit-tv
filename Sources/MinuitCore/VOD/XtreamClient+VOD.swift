import Foundation

extension XtreamClient {
    // MARK: Films

    public func movieCategories() async throws(XtreamError) -> [ChannelCategory] {
        try await categories(action: "get_vod_categories")
    }

    /// Tous les films en une requête (la liste peut compter des dizaines de milliers d'entrées).
    public func movies(category: CategoryID? = nil) async throws(XtreamError) -> [Movie] {
        var parameters: [String: String] = [:]
        if let category { parameters["category_id"] = category.rawValue }
        let data = try await get(urls.apiURL(action: "get_vod_streams", parameters: parameters), timeout: 90)
        return try Self.decodeMovies(data)
    }

    /// Repli quand la liste complète est refusée ou trop lourde : catégorie par catégorie.
    public func movies(byCategory categories: [ChannelCategory]) async throws(XtreamError) -> [Movie] {
        try await Self.mergeByCategory(categories, context: "films", key: { (movie: Movie) in movie.id }) { id in
            await self.capture { () throws(XtreamError) in try await self.movies(category: id) }
        }.get()
    }

    public func movieDetails(_ id: Int) async throws(XtreamError) -> MovieDetails {
        let data = try await get(urls.apiURL(action: "get_vod_info", parameters: ["vod_id": String(id)]), timeout: 30)
        guard let dto = try? JSONDecoder().decode(VODInfoResponseDTO.self, from: data) else {
            throw .unexpectedResponse(context: "fiche du film")
        }
        return dto.details
    }

    static func decodeMovies(_ data: Data) throws(XtreamError) -> [Movie] {
        guard let list = try? JSONDecoder().decode(LossyArray<VODStreamDTO>.self, from: data) else {
            throw .unexpectedResponse(context: "films")
        }
        var seen = Set<Int>()
        return list.elements.map(\.movie).filter { seen.insert($0.id).inserted }
    }

    // MARK: Séries

    public func seriesCategories() async throws(XtreamError) -> [ChannelCategory] {
        try await categories(action: "get_series_categories")
    }

    public func series(category: CategoryID? = nil) async throws(XtreamError) -> [Series] {
        var parameters: [String: String] = [:]
        if let category { parameters["category_id"] = category.rawValue }
        let data = try await get(urls.apiURL(action: "get_series", parameters: parameters), timeout: 90)
        return try Self.decodeSeries(data)
    }

    public func series(byCategory categories: [ChannelCategory]) async throws(XtreamError) -> [Series] {
        try await Self.mergeByCategory(categories, context: "séries", key: { (series: Series) in series.id }) { id in
            await self.capture { () throws(XtreamError) in try await self.series(category: id) }
        }.get()
    }

    public func seriesDetails(_ id: Int) async throws(XtreamError) -> SeriesDetails {
        let data = try await get(urls.apiURL(action: "get_series_info", parameters: ["series_id": String(id)]), timeout: 30)
        guard let dto = try? JSONDecoder().decode(SeriesInfoResponseDTO.self, from: data) else {
            throw .unexpectedResponse(context: "fiche de la série")
        }
        return dto.details
    }

    static func decodeSeries(_ data: Data) throws(XtreamError) -> [Series] {
        guard let list = try? JSONDecoder().decode(LossyArray<SeriesDTO>.self, from: data) else {
            throw .unexpectedResponse(context: "séries")
        }
        var seen = Set<Int>()
        return list.elements.map(\.series).filter { seen.insert($0.id).inserted }
    }
}
